#!/usr/bin/env bash
# Resume Flux, wait for Mongo 8, restore dump, advance featureCompatibilityVersion.
#
# Usage: mongo-restore.sh <REL> <NS>
# Env:   BACKUP_DIR  DUMP_FILE (optional — auto-selects newest archive if unset)
set -euo pipefail

REL=$1; NS=$2

: "${BACKUP_DIR:?BACKUP_DIR env var required}"
EXPLICIT_DUMP="${DUMP_FILE:-}"

if [[ -n "${EXPLICIT_DUMP}" ]]; then
  ARCHIVE_FILE="${EXPLICIT_DUMP}"
else
  ARCHIVE_FILE=$(ls -t "${BACKUP_DIR}/${REL}-mongo7-"*.archive 2>/dev/null | head -1)
  if [[ -z "${ARCHIVE_FILE}" ]]; then
    echo "ERROR: No archive found for '${REL}' in ${BACKUP_DIR}"
    echo "       Run 'task db-migrations:mongo-dump' first, or pass DUMP_FILE=<path>"
    exit 1
  fi
  echo "==> [${REL}] Auto-selected archive: ${ARCHIVE_FILE}"
fi

echo "==> [${REL}] Resuming Flux HelmRelease"
flux resume helmrelease "${REL}" -n "${NS}"
flux reconcile helmrelease "${REL}" -n "${NS}" --with-source

echo "==> [${REL}] Waiting for mongodb deploy to roll out (up to 3 min)"
kubectl -n "${NS}" rollout status "deploy/${REL}-mongodb" --timeout=180s

echo "==> [${REL}] Waiting for Mongo to accept connections"
for i in $(seq 1 30); do
  MONGO_USER=$(kubectl -n "${NS}" exec "deploy/${REL}-mongodb" -c mongodb -- \
    printenv MONGO_INITDB_ROOT_USERNAME 2>/dev/null || true)
  MONGO_PASS=$(kubectl -n "${NS}" exec "deploy/${REL}-mongodb" -c mongodb -- \
    printenv MONGO_INITDB_ROOT_PASSWORD 2>/dev/null || true)
  if [[ -n "${MONGO_PASS}" ]] && kubectl -n "${NS}" exec "deploy/${REL}-mongodb" -c mongodb -- \
       mongosh --quiet \
         "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin" \
         --eval 'db.adminCommand({ping:1})' &>/dev/null; then
    echo "    Mongo is ready"
    break
  fi
  echo "    (${i}/30) waiting..."
  sleep 5
done

echo "==> [${REL}] Restoring dump from ${ARCHIVE_FILE}"
kubectl -n "${NS}" exec -i "deploy/${REL}-mongodb" -c mongodb -- \
  mongorestore \
    --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin" \
    --archive \
  < "${ARCHIVE_FILE}"

echo "==> [${REL}] Advancing featureCompatibilityVersion to 8.0"
kubectl -n "${NS}" exec "deploy/${REL}-mongodb" -c mongodb -- \
  mongosh --quiet \
    "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin" \
    --eval 'db.adminCommand({setFeatureCompatibilityVersion:"8.0", confirm:true})'

echo "==> [${REL}] Scaling all deployments back up"
kubectl -n "${NS}" scale deployments \
  -l "app.kubernetes.io/instance=${REL}" \
  --replicas=1

echo "==> [${REL}] Waiting for app rollout"
kubectl -n "${NS}" rollout status "deploy/${REL}-main" --timeout=180s

echo ""
echo "============================================================"
echo "  DONE: ${REL} is running on Mongo 8"
echo ""
echo "  VERIFY:"
echo "  kubectl -n ${NS} exec deploy/${REL}-mongodb -c mongodb -- \\"
echo "    mongosh --eval 'db.version()'"
echo "============================================================"
