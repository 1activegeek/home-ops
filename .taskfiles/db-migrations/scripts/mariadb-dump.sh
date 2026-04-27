#!/usr/bin/env bash
# Dump MariaDB 11 to NAS as a safety backup before the 11->12 in-place upgrade.
# MariaDB runs mysql_upgrade automatically on first start with the new version,
# so no wipe is needed — but this dump is the rollback artifact.
#
# Usage: mariadb-dump.sh <REL> <NS> <ROOT_PW>
# Env:   BACKUP_DIR  NAS_HOST  NAS_BACKUP_PATH
set -euo pipefail

REL=$1; NS=$2; ROOT_PW=$3

: "${BACKUP_DIR:?BACKUP_DIR env var required}"
: "${NAS_HOST:?NAS_HOST env var required}"
: "${NAS_BACKUP_PATH:?NAS_BACKUP_PATH env var required}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DUMP_FILE="${BACKUP_DIR}/${REL}-mariadb11-${TIMESTAMP}.sql"

echo "==> [${REL}] Suspending Flux HelmRelease"
flux suspend helmrelease "${REL}" -n "${NS}"

echo "==> [${REL}] Dumping MariaDB 11 -> ${DUMP_FILE}"
mkdir -p "${BACKUP_DIR}"
kubectl -n "${NS}" exec "deploy/${REL}-mariadb" -c mariadb -- \
  mariadb-dump -uroot -p"${ROOT_PW}" --all-databases --single-transaction \
  > "${DUMP_FILE}"

DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
echo "    Dump complete: ${DUMP_SIZE}"

echo "==> [${REL}] Copying dump to NAS ${NAS_HOST}:${NAS_BACKUP_PATH}/"
ssh "${NAS_HOST}" "mkdir -p ${NAS_BACKUP_PATH}"
ssh "${NAS_HOST}" "cat > ${NAS_BACKUP_PATH}/$(basename "${DUMP_FILE}")" < "${DUMP_FILE}"
echo "    NAS copy done"

echo "==> [${REL}] Scaling all deployments down"
kubectl -n "${NS}" scale deployments \
  -l "app.kubernetes.io/instance=${REL}" \
  --replicas=0

echo "==> [${REL}] Waiting for pods to terminate"
kubectl -n "${NS}" wait pods \
  -l "app.kubernetes.io/instance=${REL}" \
  --for=delete \
  --timeout=90s 2>/dev/null || true

echo ""
echo "============================================================"
echo "  DONE: MariaDB dump saved for ${REL}"
echo "  Dump: ${DUMP_FILE}"
echo ""
echo "  NEXT:"
echo "  1. Verify tag exists: crane ls docker.io/library/mariadb | grep '^12'"
echo "  2. Edit kubernetes/apps/${NS}/${REL}/app/helmrelease.yaml"
echo "     Change:  tag: \"11\""
echo "     To:      tag: \"12\""
echo "  3. Commit + push to main, then:"
echo "     flux resume helmrelease ${REL} -n ${NS}"
echo "     flux reconcile helmrelease ${REL} -n ${NS} --with-source"
echo "  4. Watch logs: kubectl -n ${NS} logs -f deploy/${REL}-mariadb"
echo "  5. task db-migrations:mariadb-verify NS=${NS} REL=${REL}"
echo ""
echo "  ROLLBACK:"
echo "  flux suspend helmrelease ${REL} -n ${NS}"
echo "  Revert tag to '11', scale mariadb to 0, wipe /var/lib/mysql,"
echo "  resume flux (fresh initdb), restore:"
echo "  kubectl -n ${NS} exec -i deploy/${REL}-mariadb -c mariadb -- \\"
echo "    mariadb -uroot -p'<pw>' < ${DUMP_FILE}"
echo "============================================================"
