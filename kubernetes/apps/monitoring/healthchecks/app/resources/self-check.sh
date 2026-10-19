#!/bin/sh
# Healthchecks self-check, run every 5 minutes by the `self-check` CronJob.
#
# Goes through the real hostname (cluster DNS -> k8s-gateway -> envoy-internal
# -> TLS -> pod), so a pass proves the whole path scripts use, not just the pod.
#
#   1. GET /api/v3/status/ (the same endpoint the pod probes use; runs SELECT 1)
#   2. Upsert the checks this deployment owns (checks-as-code, idempotent)
#   3. Ping the local `healthchecks-self` check
#   4. Ping the healthchecks.io cloud check: the out-of-cluster dead-man's switch.
#      If the cluster, the gateway, or Healthchecks itself dies, the cloud check
#      stops hearing from us and alerts from outside. Failures in steps 1-3 send
#      an explicit /fail to the cloud check so the alert carries the reason.
set -u

base="${HC_BASE_URL}"
ping="${base}/ping/${HC_PING_KEY}"

cloud() {
  # $1 = suffix ("" or "/fail"), $2 = body
  case "${HC_CLOUD_PING_URL:-}" in
    "" | REPLACE_ME)
      echo "self-check: cloud_ping_url not set in 1Password; skipping cloud ping"
      return 0
      ;;
  esac
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$2" "${HC_CLOUD_PING_URL}$1"
}

fail() {
  echo "self-check: FAIL: $1" >&2
  cloud /fail "self-check: $1" || echo "self-check: cloud /fail ping also failed" >&2
  exit 1
}

upsert() {
  # $1 = slug, $2 = JSON body
  curl -fsS -m 10 --retry 3 -o /dev/null -X POST \
    -H "X-Api-Key: ${HC_API_KEY}" -H "Content-Type: application/json" \
    --data-raw "$2" "${base}/api/v3/checks/" || fail "API upsert of check '$1' failed"
}

status=$(curl -fsS -m 10 --retry 3 --retry-connrefused "${base}/api/v3/status/") \
  || fail "status endpoint unreachable at ${base}"
[ "${status}" = "OK" ] || fail "status endpoint returned '${status}'"

upsert healthchecks-self '{
  "name": "healthchecks-self", "slug": "healthchecks-self", "tags": "infra",
  "desc": "Pinged every 5m by the monitoring/healthchecks self-check CronJob via the real hostname.",
  "timeout": 300, "grace": 300, "channels": "*", "unique": ["slug"]
}'
upsert alertmanager-watchdog '{
  "name": "alertmanager-watchdog", "slug": "alertmanager-watchdog", "tags": "infra",
  "desc": "Dead-man switch: Alertmanager routes the always-firing Watchdog alert here every minute. Silence = Prometheus or Alertmanager is down.",
  "timeout": 300, "grace": 300, "channels": "*", "unique": ["slug"]
}'

curl -fsS -m 10 --retry 3 -o /dev/null "${ping}/healthchecks-self" \
  || fail "local ping to healthchecks-self failed"

cloud "" "self-check ok" || { echo "self-check: cloud ping failed" >&2; exit 1; }
echo "self-check: ok"
