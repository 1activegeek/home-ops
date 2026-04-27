#!/usr/bin/env bash
# Dump Postgres 17, copy to NAS, scale all release deployments down, wipe PGDATA.
#
# Usage: pg-dump-stop.sh <REL> <NS> <PG_USER> [PVC]
#   PVC is optional — auto-detected from the postgres Deployment spec if omitted.
# Env:   BACKUP_DIR  NAS_HOST  NAS_BACKUP_PATH
set -euo pipefail

REL=$1; NS=$2; PG_USER=$3; EXPLICIT_PVC=${4:-}

: "${BACKUP_DIR:?BACKUP_DIR env var required}"
: "${NAS_HOST:?NAS_HOST env var required}"
: "${NAS_BACKUP_PATH:?NAS_BACKUP_PATH env var required}"

# Auto-detect PVC from postgres Deployment volume spec
if [[ -n "${EXPLICIT_PVC}" ]]; then
  PVC="${EXPLICIT_PVC}"
else
  PVC=$(kubectl -n "${NS}" get deploy "${REL}-postgres" \
    -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null | tr ' ' '\n' | head -1)
  if [[ -z "${PVC}" ]]; then
    echo "ERROR: Could not auto-detect PVC for ${REL}-postgres. Pass PVC=<name> explicitly."
    exit 1
  fi
  echo "==> [${REL}] Auto-detected postgres PVC: ${PVC}"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DUMP_FILE="${BACKUP_DIR}/${REL}-pg17-${TIMESTAMP}.sql"
PGDATA_SUBDIR=pgdata

echo "==> [${REL}] Suspending Flux HelmRelease"
flux suspend helmrelease "${REL}" -n "${NS}"

echo "==> [${REL}] Dumping Postgres 17 -> ${DUMP_FILE}"
mkdir -p "${BACKUP_DIR}"
kubectl -n "${NS}" exec "deploy/${REL}-postgres" -c postgres -- \
  pg_dumpall -U "${PG_USER}" > "${DUMP_FILE}"

DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
echo "    Dump complete: ${DUMP_SIZE}"

echo "==> [${REL}] Copying dump to NAS ${NAS_HOST}:${NAS_BACKUP_PATH}/"
ssh "${NAS_HOST}" "mkdir -p ${NAS_BACKUP_PATH}"
ssh "${NAS_HOST}" "cat > ${NAS_BACKUP_PATH}/$(basename "${DUMP_FILE}")" < "${DUMP_FILE}"
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

echo "==> [${REL}] Wiping PGDATA on PVC ${PVC}"
WIPE_SPEC=$(cat <<JSONEOF
{
  "spec": {
    "securityContext": {"runAsUser": 999, "runAsGroup": 999, "fsGroup": 999},
    "volumes": [{"name": "d", "persistentVolumeClaim": {"claimName": "${PVC}"}}],
    "containers": [{
      "name": "wipe",
      "image": "alpine",
      "command": ["sh", "-c", "rm -rf /d/${PGDATA_SUBDIR} && echo 'pgdata wiped OK' && ls /d/"],
      "volumeMounts": [{"name": "d", "mountPath": "/d"}]
    }]
  }
}
JSONEOF
)
kubectl -n "${NS}" run "pgwipe-${REL}" --restart=Never --image=alpine \
  --overrides="${WIPE_SPEC}" 2>&1
sleep 15
kubectl -n "${NS}" logs "pgwipe-${REL}" 2>&1 || true
kubectl -n "${NS}" delete pod "pgwipe-${REL}" --ignore-not-found 2>&1

echo ""
echo "============================================================"
echo "  DONE: dump saved and PGDATA wiped for ${REL}"
echo "  Dump: ${DUMP_FILE}"
echo "  PVC:  ${PVC}"
echo ""
echo "  NEXT: bump tag 17-alpine -> 18-alpine in"
echo "  kubernetes/apps/*/${REL}/app/helmrelease.yaml"
echo "  then commit+push and run: task db-migrations:pg-restore"
echo "  REL=${REL} NS=${NS} PG_USER=${PG_USER}"
echo "============================================================"
