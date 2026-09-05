# Postgres Consolidation onto CloudNativePG

Runbook for migrating the cluster's nine standalone `postgres:18-alpine` sidecar
containers onto the shared CloudNativePG cluster in the `database` namespace.

Mattermost was a tenth. It was decommissioned in favour of the Matrix stack
rather than migrated, so its sidecar is gone without ever moving.

This **supersedes** the "Database Strategy: Individual DBs Per App" decision in
`deployment-plan.md`.

## Why

The per-app sidecar pattern gave isolation, but at a cost that grew with app
count: one single-instance database with no HA per app, one `pg_dump` CronJob
per app, one manual major-version upgrade per app (see
`.taskfiles/db-migrations/`), and no metrics or alerting on any of them. A
single CNPG cluster gives declarative roles and databases, automatic failover,
PodMonitor metrics, and one backup job.

The trade is real and worth stating plainly: **this creates a single failure
domain.** CNPG down means Forgejo, Authentik (and therefore SSO), Synapse and
Nextcloud are all down. That is mitigated by running 2 instances with automatic
failover and alerting, not eliminated.

## Target state

| App | NS | Role | Database |
|-----|----|------|----------|
| forgejo | tools | `forgejo` | `forgejo` |
| shlink | tools | `shlink` | `shlink` |
| atuin | tools | `atuin` | `atuin` |
| zipline | tools | `zipline` | `zipline` |
| mas | tools | `mas` | `mas` |
| nextcloud | tools | `nextcloud` | `nextcloud` |
| synapse | tools | `synapse` | `synapse` (C collation) |
| n8n | ai | `n8n` | `n8n` |
| teslamate | home | `teslamate` | `teslamate` |
| authentik | security | `authentik` | `authentik` |

All connect to `postgres-rw.database.svc.cluster.local:5432`. No NetworkPolicy
is enforced in this cluster, so cross-namespace access needs no extra wiring.

Manifests: `kubernetes/apps/database/postgres/app/`.

## Status

- [x] CNPG operator + shared cluster deployed
- [x] **forgejo** — migrated from SQLite
- [ ] everything else, in the order below

## The pattern (identical for every app)

1. **Add credentials.** Add a `<app>_password` field to the 1Password
   `cnpg-postgres` item, then an `ExternalSecret` block in
   `postgres/app/externalsecret.yaml` producing `cnpg-role-<app>-secret`
   (type `kubernetes.io/basic-auth`).
2. **Declare the role and database.** Add a `managed.roles[]` entry in
   `cluster.yaml` and a `Database` CR in `databases.yaml`
   (`databaseReclaimPolicy: retain`). Push and wait:
   ```sh
   kubectl -n database get database <app> -o jsonpath='{.status}'
   ```
3. **Stop the app.**
   ```sh
   flux -n flux-system suspend ks <app>
   kubectl -n <ns> scale deploy/<app> --replicas=0
   kubectl -n <ns> wait --for=delete pod -l app.kubernetes.io/name=<app> --timeout=5m
   ```
   Take the dump with the app stopped — a hot dump of a running app is not
   guaranteed consistent (Synapse especially).
4. **Dump** from the old sidecar:
   ```sh
   kubectl -n <ns> exec <app>-postgres-0 -- \
     pg_dump -U <app> -d <app> --no-owner --no-privileges -Fc > /tmp/<app>.dump
   ```
5. **Restore** into CNPG:
   ```sh
   kubectl -n database exec -i postgres-1 -c postgres -- \
     pg_restore --no-owner --no-privileges -d <app> -U postgres < /tmp/<app>.dump
   ```
6. **Repoint the app.** Edit its HelmRelease: change the DSN/host/user/password
   to CNPG, and delete the `postgres` controller, its Service, and its
   `*-postgres-data` persistence entry. **Leave the old PVC in place** — remove
   the persistence block only in a second commit, 30 days later.
7. **Resume and verify**, then delete that app's `cronjob-<app>.yaml` from its
   namespace `db-backup/` — `database/db-backup` now covers it.

## Order — easiest first

| # | App | Why here | Gotchas |
|---|-----|----------|---------|
| 1 | **shlink** | Small, low blast radius. Rehearse the pattern here. | none |
| 2 | **atuin** | Small, single-user | none |
| 3 | **zipline** | Small | Already uses a `postgres-init` init container — remove it. File uploads are a separate PVC; don't touch. |
| 4 | **mas** | Small, but **Synapse depends on it for auth** — migrate well before Synapse | DSN lives inside `config.yaml` in `mas-secret`. MAS runs its own schema migrations at boot. |
| 5 | **n8n** | Medium | `N8N_ENCRYPTION_KEY` must be unchanged or **every stored credential becomes unreadable**. Confirm it comes from the ExternalSecret, not a file generated on the PVC. |
| 6 | **teslamate** | Large time-series; longest dump/restore | Check for `cube`/`earthdistance` extensions (add to `Database.spec.extensions`). The teslamate-grafana datasource secret needs updating too. |
| 7 | **nextcloud** | Big and chatty; ~30 connections — this is the app that will make you care about `max_connections` | `occ maintenance:mode --on` first. After cutover: `occ maintenance:repair` and `occ db:add-missing-indices`. |
| 8 | **synapse** | Schema-sensitive | **Hard requirement: `LC_COLLATE=C`, `LC_CTYPE=C`.** Use the `Database` CR with `localeCollate: C`, `localeCType: C` and **`template: template0`** (locale cannot be overridden from `template1`). Synapse refuses to start otherwise. Verify before restoring: `SELECT datcollate, datctype FROM pg_database WHERE datname='synapse'` |
| 9 | **authentik** | **PG 17 → 18** and it is the IdP: breaking it costs SSO to Forgejo, Headlamp and Grafana | Dump using the **PG 18** `pg_dump` client against the 17 server (forward, never backward). Set `postgresql.enabled: false` on the bitnami subchart and drop the two `valuesFrom` targetPaths. Keep the PG17 PVC. **Verify the static kubeconfig works before starting** — apiserver OIDC goes with it. Do this last, on a day you can afford downtime. |

For Synapse:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: synapse
spec:
  cluster:
    name: postgres
  name: synapse
  owner: synapse
  encoding: UTF8
  localeCollate: C
  localeCType: C
  template: template0
  databaseReclaimPolicy: retain
```

## Rollback

At every step the old sidecar PVC still exists: revert the HelmRelease commit
and `flux reconcile`. The point of no return is deleting that PVC — do it in a
dedicated commit, at least 30 days after cutover.

## Backups

`kubernetes/apps/database/db-backup/` dumps globals plus every database on the
cluster nightly at 01:20 to a 20Gi `db-backups` PVC, 14-day retention. That PVC
is on `longhorn` and therefore in Longhorn's `default` recurring-job group, so
it ships off-box to the Synology at 03:00.

**Why not CNPG's native barman backups:** barman-cloud requires an S3-compatible
object store. This cluster has none — Longhorn's only off-box target is NFS,
which barman cannot use. Standing up MinIO purely to back up Postgres would make
the backup target another stateful workload on the same three nodes.

Consequence: **RPO is 24h and there is no PITR.**

### Phase 4 — PITR (not scheduled)

To get point-in-time recovery: deploy Garage or MinIO (ideally backed by
Synology storage, so the object store is in a different failure domain from the
database), then add the CNPG `barman-cloud` plugin and a `ScheduledBackup`.
An object store living on the same three nodes as the database it backs up is
worth very little.

## Sizing notes

- `instances: 2` — primary plus hot standby; survives one node loss and allows a
  Talos node drain with automatic failover.
- Replication is **asynchronous** and must stay that way. Synchronous quorum
  with only 2 instances means a standby outage stalls writes for every app.
- Storage is 50Gi data + 10Gi WAL on `longhorn-cnpg`, a StorageClass with
  `numberOfReplicas: "1"` — CNPG already replicates at the Postgres layer, so
  the default `longhorn` class would give 4 physical copies of every byte.
- Consolidation is **not** a resource saving: the ten sidecars request ~550m CPU
  and ~1.5Gi memory in total, versus 500m/2Gi per CNPG instance. The win is
  operational — one thing to back up, patch, monitor and fail over.
- Revisit `instances`, `storage`, `max_connections` and `shared_buffers` against
  real usage once all ten apps have moved.

## Lessons from the Forgejo migration (2026-08-01, the first tenant)

Things that were wrong or unstated in the original plan and cost real time.
Read these before migrating app #2.

**Find the database file first; do not trust the documented default.** The plan
assumed Forgejo's SQLite lived at `/data/gitea/gitea.db`. It was actually at
`/data/forgejo.db`. A `find /data -name '*.db*'` before writing the pgloader
command takes ten seconds. Applies to any app whose DSN or data path you are
about to hardcode.

**Checkpoint the SQLite WAL before copying.** There was a 4MB `forgejo.db-wal`
alongside a 6.5MB database. Copying only the `.db` file would have silently
dropped everything in that WAL. After scaling the app to 0:

    sqlite3 /data/forgejo.db "PRAGMA wal_checkpoint(TRUNCATE);"
    sqlite3 /data/forgejo.db "PRAGMA integrity_check;"

The `-wal` file should be gone and the main file slightly larger. This only
applies to SQLite sources, so it is Forgejo-specific — but the general rule
(quiesce, then verify the on-disk file is complete) is not.

**Record a per-table row count from the source before you start.** It is the
only way to prove afterwards that nothing was silently dropped. All 24
non-empty Forgejo tables matched exactly post-migration. Do this for every app;
`pg_restore` failures can be partial and quiet.

**`reset sequences` worked, and is genuinely load-bearing.** pgloader reported
"Reset Sequences 115". Verified after the fact with
`SELECT last_value FROM <table>_id_seq` against `max(id)` per table, then by
creating a new repo (got id 14, max was 13) and a new issue. Do not skip the
write test — reading proves nothing about sequences.

**`pg_dumpall --dbname` takes a connection string, `pg_dump --dbname` does not.**
`pg_dumpall --dbname=postgres` fails with `missing "=" after "postgres" in
connection info string`. Use `--dbname="dbname=postgres"`. This broke the
nightly backup job on its first run.

**Run the backup job on demand the day you create it.** The bug above would
otherwise have surfaced at 01:20 the following morning, as a silent absence of
globals rather than an obvious failure.

**Verify the role authenticates through the service, not just that the secret
exists.** A one-off `psql` pod using the CNPG-provisioned role against
`postgres-rw` proves the whole chain — 1Password field, ExternalSecret,
`managed.roles[]`, and the value the app will actually use — before the app
depends on it.
