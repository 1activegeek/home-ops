# Longhorn Backup & Restore Runbook

Off-cluster backups for all PVCs use **Longhorn native backups → Synology NFS**.
Incremental, block-level, with zero always-on cluster footprint between scheduled runs.
Cluster *manifests* are not backed up here on purpose — they're reproducible from this
GitOps repo (Flux). Only PVC **data** needs backing up.

## Topology

- **Backup target:** `nfs://10.0.3.2:/volume2/longhorn-backup` (Synology, NFSv4, no creds)
- **Config:** `kubernetes/apps/longhorn-system/longhorn/app/helmrelease.yaml` (`defaultBackupStore.backupTarget` — Longhorn v1.11 moved this off `defaultSettings` onto the `default` BackupTarget CR)
- **Schedules:** `kubernetes/apps/longhorn-system/longhorn/app/recurringjobs.yaml`
  - `snapshot-hourly` — local snapshot every 6h, retain 8 (fast rollback)
  - `backup-daily` — backup to NFS daily 03:00, retain 7
  - `backup-weekly` — backup to NFS weekly Sun 04:00, retain 4
- All jobs are in the Longhorn `default` group, so they auto-apply to every volume
  (current and future) that has no volume-specific recurring jobs.

## Synology prerequisite (one-time)

1. Create shared folder `/volume2/longhorn-backup`.
2. NFS export: NFSv4.1 enabled, `rw` + `no_root_squash` (or map-to-admin),
   granted to node IPs `10.0.3.21/22/23` (or `10.0.3.0/24`).
3. Optional: ~300 GB quota.

## Verify backups are working

```sh
# Backup target healthy?
kubectl -n longhorn-system get backuptarget default -o yaml

# Recurring jobs present
kubectl -n longhorn-system get recurringjobs.longhorn.io

# Backups accumulating (after first scheduled run, or trigger one from the UI)
kubectl -n longhorn-system get backups.longhorn.io
```

Or use the Longhorn UI (HTTPRoute) → Backup tab.

## Restore a single volume

1. Longhorn UI → **Backup** → select the volume's backup → **Restore Latest Backup**
   (or a specific point in time). Restore into a new Longhorn volume.
2. Create a PV/PVC bound to the restored volume (use `longhorn-static` StorageClass,
   or the UI "Create PV/PVC" action on the restored volume).
3. Point the workload's PVC at it, or rename to match the original PVC.

CLI alternative: create a `Volume` CR with `spec.fromBackup` set to the backup URL,
then create the matching PV/PVC.

## Full cluster-rebuild disaster recovery

1. Stand up a fresh Talos cluster and bootstrap Flux against this repo.
2. Flux reinstalls Longhorn from `helmrelease.yaml`, which sets the **same backup target**.
3. Longhorn reads the self-describing backupstore on the NFS share — all existing
   backups reappear under **Backup** automatically.
4. For each app, restore its volume from backup (see above) and create the PV/PVC the
   app's manifests expect. Git rebuilds the apps; NFS rebuilds the data.

## Notes / limitations

- NFS backups are **crash-consistent** (fine for SQLite/config; Postgres recovers via
  WAL replay). `freezeFilesystemForSnapshot: true` tightens this.
- **Phase 2** adds logically consistent DB dumps (`pg_dump`/`mariadb-dump`/`mongodump`/
  Qdrant-snapshot CronJobs) for stateful DB apps as defense-in-depth — see
  `database-dumps-restore.md`.
- Consider a periodic restore drill and off-site replication of the NFS folder (3-2-1).
