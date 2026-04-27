#!/usr/bin/env bash
# Resume Flux, wait for Postgres 18 to initdb, restore dump, then scale app up.
# Drops the application database before restoring so we get a clean slate
# even if the app briefly started and ran schema migrations first.
#
# Usage: pg-restore.sh <REL> <NS> <PG_USER> [DB_NAME]
#   DB_NAME defaults to REL if omitted.
# Env:   BACKUP_DIR  DUMP_FILE (optional — auto-selects newest dump if unset)
set -euo pipefail

REL=$1; NS=$2; PG_USER=$3; DB_NAME=${4:-$REL}

: "${BACKUP_DIR:?BACKUP_DIR env var required}"
EXPLICIT_DUMP="${DUMP_FILE:-}"

if [[ -n "${EXPLICIT_DUMP}" ]]; then
  DUMP_FILE="${EXPLICIT_DUMP}"
else
  DUMP_FILE=$(ls -t "${BACKUP_DIR}/${REL}-pg17-"*.sql 2>/dev/null | head -1)
  if [[ -z "${DUMP_FILE}" ]]; then
    echo "ERROR: No dump file found for '${REL}' in ${BACKUP_DIR}"
    echo "       Run 'task db-migrations:pg-dump' first, or pass DUMP_FILE=<path>"
    exit 1
  fi
  echo "==> [${REL}] Auto-selected dump: ${DUMP_FILE}"
fi

echo "==> [${REL}] Resuming Flux HelmRelease"
flux resume helmrelease "${REL}" -n "${NS}"

# Immediately hold all non-postgres deployments at 0 before reconcile finishes.
echo "==> [${REL}] Holding app deployments at 0 while postgres initialises"
for deploy in $(kubectl -n "${NS}" get deploy \
    -l "app.kubernetes.io/instance=${REL}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  if [[ "${deploy}" != "${REL}-postgres" ]]; then
    kubectl -n "${NS}" scale "deploy/${deploy}" --replicas=0 2>/dev/null || true
  fi
done

echo "==> [${REL}] Forcing reconcile"
flux reconcile helmrelease "${REL}" -n "${NS}" --with-source

# Re-clamp app deployments — flux reconcile may have set them to 1.
echo "==> [${REL}] Re-clamping app deployments to 0 after reconcile"
for deploy in $(kubectl -n "${NS}" get deploy \
    -l "app.kubernetes.io/instance=${REL}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  if [[ "${deploy}" != "${REL}-postgres" ]]; then
    kubectl -n "${NS}" scale "deploy/${deploy}" --replicas=0 2>/dev/null || true
  fi
done

echo "==> [${REL}] Waiting for postgres deploy to roll out (up to 3 min)"
kubectl -n "${NS}" rollout status "deploy/${REL}-postgres" --timeout=180s

echo "==> [${REL}] Waiting for postgres to accept connections"
for i in $(seq 1 30); do
  if kubectl -n "${NS}" exec "deploy/${REL}-postgres" -c postgres -- \
       pg_isready -U "${PG_USER}" -q 2>/dev/null; then
    echo "    Postgres is ready"
    break
  fi
  echo "    (${i}/30) waiting..."
  sleep 5
done

# Drop the app database so restore gets a clean slate, even if the app briefly
# ran migrations before we could scale it down.
echo "==> [${REL}] Dropping database '${DB_NAME}' for clean restore"
kubectl -n "${NS}" exec "deploy/${REL}-postgres" -c postgres -- \
  psql -U "${PG_USER}" -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();" \
  -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";" 2>&1

echo "==> [${REL}] Restoring dump from ${DUMP_FILE}"
kubectl -n "${NS}" exec -i "deploy/${REL}-postgres" -c postgres -- \
  psql -U "${PG_USER}" -d postgres < "${DUMP_FILE}"

echo "==> [${REL}] Scaling all deployments back up"
kubectl -n "${NS}" scale deployments \
  -l "app.kubernetes.io/instance=${REL}" \
  --replicas=1

echo "==> [${REL}] Waiting for app rollout"
kubectl -n "${NS}" rollout status "deploy/${REL}-main" --timeout=180s

echo ""
echo "============================================================"
echo "  DONE: ${REL} is running on Postgres 18"
echo ""
echo "  VERIFY:"
echo "  kubectl -n ${NS} exec deploy/${REL}-postgres -c postgres -- \\"
echo "    psql -U ${PG_USER} -c 'SELECT version();'"
echo "============================================================"
