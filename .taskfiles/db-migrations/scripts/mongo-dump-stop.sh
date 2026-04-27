#!/usr/bin/env bash
# Dump Mongo 7 to NAS, scale librechat down, wipe /data/db so Mongo 8 gets a clean start.
#
# Usage: mongo-dump-stop.sh <REL> <NS>
# Env:   BACKUP_DIR  NAS_HOST  NAS_BACKUP_PATH
set -euo pipefail

REL=$1; NS=$2

: "${BACKUP_DIR:?BACKUP_DIR env var required}"
: "${NAS_HOST:?NAS_HOST env var required}"
: "${NAS_BACKUP_PATH:?NAS_BACKUP_PATH env var required}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_FILE="${BACKUP_DIR}/${REL}-mongo7-${TIMESTAMP}.archive"

echo "==> [${REL}] Suspending Flux HelmRelease"
flux suspend helmrelease "${REL}" -n "${NS}"

echo "==> [${REL}] Reading Mongo root credentials from pod env"
MONGO_USER=$(kubectl -n "${NS}" exec "deploy/${REL}-mongodb" -c mongodb -- \
  printenv MONGO_INITDB_ROOT_USERNAME)
MONGO_PASS=$(kubectl -n "${NS}" exec "deploy/${REL}-mongodb" -c mongodb -- \
  printenv MONGO_INITDB_ROOT_PASSWORD)

echo "==> [${REL}] Dumping Mongo 7 -> ${ARCHIVE_FILE}"
mkdir -p "${BACKUP_DIR}"
kubectl -n "${NS}" exec "deploy/${REL}-mongodb" -c mongodb -- \
  mongodump \
    --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin" \
    --archive \
  > "${ARCHIVE_FILE}"

DUMP_SIZE=$(du -sh "${ARCHIVE_FILE}" | cut -f1)
echo "    Dump complete: ${DUMP_SIZE}"

echo "==> [${REL}] Copying dump to NAS ${NAS_HOST}:${NAS_BACKUP_PATH}/"
ssh "${NAS_HOST}" "mkdir -p ${NAS_BACKUP_PATH}"
ssh "${NAS_HOST}" "cat > ${NAS_BACKUP_PATH}/$(basename "${ARCHIVE_FILE}")" < "${ARCHIVE_FILE}"
echo "    NAS copy done"

echo "==> [${REL}] Scaling all deployments to 0"
kubectl -n "${NS}" scale deployments \
  -l "app.kubernetes.io/instance=${REL}" \
  --replicas=0

echo "==> [${REL}] Waiting for pods to terminate"
kubectl -n "${NS}" wait pods \
  -l "app.kubernetes.io/instance=${REL}" \
  --for=delete \
  --timeout=90s 2>/dev/null || true

echo "==> [${REL}] Wiping /data/db inside mongodb PVC (${REL}-data)"
MONGO_PVC="${REL}-data"
WIPE_SPEC=$(cat <<JSONEOF
{
  "spec": {
    "securityContext": {"runAsUser": 999, "runAsGroup": 999, "fsGroup": 999},
    "volumes": [{"name": "d", "persistentVolumeClaim": {"claimName": "${MONGO_PVC}"}}],
    "containers": [{
      "name": "wipe",
      "image": "alpine",
      "command": ["sh", "-c", "rm -rf /d/* && echo 'wiped OK'"],
      "volumeMounts": [{"name": "d", "mountPath": "/d"}]
    }]
  }
}
JSONEOF
)
kubectl -n "${NS}" run "mongowipe-${REL}" \
  --rm --restart=Never --image=alpine --attach \
  --overrides="${WIPE_SPEC}"

echo ""
echo "============================================================"
echo "  DONE: Mongo dump saved and /data/db wiped for ${REL}"
echo "  Archive: ${ARCHIVE_FILE}"
echo ""
echo "  NEXT: bump tag \"7\" -> \"8\" in"
echo "  kubernetes/apps/${NS}/${REL}/app/helmrelease.yaml"
echo "  then commit+push and run: task db-migrations:mongo-restore"
echo "  NS=${NS} REL=${REL}"
echo "============================================================"
