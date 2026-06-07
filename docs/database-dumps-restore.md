# Database Logical Dumps & Restore Runbook

**Phase 2** of the cluster backup strategy. Adds application-level, logically consistent
dumps for every stateful database, layered on top of Phase 1's crash-consistent Longhorn
block backups (see `longhorn-backup-restore.md`). Logical dumps are portable, version-aware,
and immune to the "block snapshot caught the DB mid-write" failure mode.

## How it works

- One `CronJob` per database, in the **same namespace as the app**, reusing the app's
  existing ExternalSecret for credentials (no credential duplication).
- Each namespace with DBs has a dedicated **`db-backups` Longhorn PVC** that the dumps
  write to. Phase 1's `default`-group RecurringJob automatically backs that PVC off-box to
  Synology NFS — so logical dumps inherit off-site DR for free, no extra wiring.
- Dumps run nightly, **staggered 01:00–02:30**, ahead of Phase 1's 03:00 `backup-daily` so
  fresh dumps are captured the same night.
- **Retention:** 14 days per DB, self-pruned in-job (`find -mtime +14 -delete`).
- Manifests: `kubernetes/apps/<ns>/db-backup/` (PVC + CronJobs + Flux Kustomization).

## Coverage

| App | NS | Engine | Dump file | Method |
|-----|----|--------|-----------|--------|
| authentik | security | Postgres 17 | `authentik-*.dump` | `pg_dump -Fc` |
| atuin | tools | Postgres 18 | `atuin-*.dump` | `pg_dump -Fc` |
| nextcloud | tools | Postgres 18 | `nextcloud-*.dump` | `pg_dump -Fc` |
| shlink | tools | Postgres 18 | `shlink-*.dump` | `pg_dump -Fc` |
| zipline | tools | Postgres 18 | `zipline-*.dump` | `pg_dump -Fc` |
| teslamate | home | Postgres 18 | `teslamate-*.dump` | `pg_dump -Fc` |
| grimmory | media | MariaDB 12 | `grimmory-*.sql.gz` | `mariadb-dump \| gzip` |
| n8n | ai | Postgres 18 | `n8n-*.dump` | `pg_dump -Fc` |
| librechat | ai | MongoDB 8.3 | `librechat-*.archive.gz` | `mongodump --gzip --archive` |
| qdrant | ai | Qdrant 1.18 | `qdrant-*-<snapshot>` | snapshot API → download |

**Not covered here:** `forgejo` (HelmRelease declares postgres but no DB workload exists in
cluster — its data lives on its own block-backed PVC); `litellm` (removed 2026-05).

## Verify dumps are working

```sh
# CronJobs present
kubectl get cronjobs -A | grep db-backup

# Manually trigger a one-off run (no need to wait for schedule)
kubectl -n <ns> create job --from=cronjob/db-backup-<app> manual-<app>-test

# Watch it
kubectl -n <ns> logs -f job/manual-<app>-test

# Inspect dump files on the PVC (spin a throwaway pod that mounts it)
kubectl -n <ns> run pvc-peek --rm -it --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"pvc-peek","image":"busybox","command":["ls","-lh","/backups"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"db-backups"}}]}}'
```

## Restore a single database

First, copy the desired dump off the PVC (mount it in a throwaway pod, or restore the PVC
from Longhorn backup if the cluster is gone — see `longhorn-backup-restore.md`).

**Postgres** (custom format `-Fc`):
```sh
# into the live DB (drops/recreates objects)
pg_restore --clean --if-exists --no-owner --no-privileges \
  -d "postgres://<user>:<pw>@<svc>:5432/<db>" /path/<app>-<ts>.dump
```

**MariaDB**:
```sh
gunzip -c /path/grimmory-<ts>.sql.gz | \
  mariadb -h grimmory-mariadb.media.svc.cluster.local -u grimmory -p<pw> grimmory
```

**MongoDB**:
```sh
mongorestore --uri="<mongo_uri>" --gzip --archive=/path/librechat-<ts>.archive.gz --drop
```

**Qdrant** (snapshot file):
```sh
# upload + recover a collection from a downloaded snapshot
curl -X POST -H "api-key: <api_key>" \
  -F "snapshot=@/path/qdrant-<ts>-<name>" \
  "http://qdrant.ai.svc.cluster.local:6333/collections/<collection>/snapshots/upload?priority=snapshot"
```

## Full disaster recovery order of operations

1. Rebuild cluster + Flux (Git restores all manifests, incl. these CronJobs).
2. Restore each app's **data PVC** from Longhorn NFS backup (block-level) — gets apps running.
3. For databases, optionally **replay the latest logical dump** over the restored DB if the
   block restore was mid-write / inconsistent. Logical dump is the authoritative,
   point-in-consistency copy.
4. The `db-backups` PVCs themselves are restorable from Longhorn NFS too — that's where the
   dump history lives off-box.

## Notes

- pg_dump client is 18 (dumps Postgres 17 and 18 servers; forward-compatible).
- All jobs run restricted-PSA compliant (non-root uid 1000, dropped caps, seccomp default).
- Consider a quarterly restore drill to prove dumps are good.
