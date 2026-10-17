#!/bin/sh
# Heartbeat runner: turns Kubernetes' own health checks into Healthchecks pings.
# Runs as the long-lived `heartbeat` controller (one replica, loop every 60s).
#
# Opt in by annotating a Deployment, StatefulSet or DaemonSet:
#   healthchecks.io/slug: sonarr                       (required)
#   healthchecks.io/url: http://sonarr.media.svc...    (optional deep check)
#
# Each round, per annotated workload:
#   healthy   = at least one pod Ready (every pod for a DaemonSet) and, if set,
#               GET url answers 2xx straight at the Service (no Envoy/DNS/TLS;
#               that path is Uptime Kuma's job)
#   healthy   -> ping /<slug>               (resets the check's timer)
#   unhealthy -> ping /<slug>/log           (recorded, no alert) for the first
#                HEARTBEAT_FAIL_AFTER-1 rounds, so rollouts and Recreate
#                restarts don't page; then /<slug>/fail with the reason
#
# Dead-man's switch: a check only stays up while pings keep arriving. A deleted
# workload, a dead runner, or a dead cluster all mean silence, and Healthchecks
# alerts. Removing the annotation does NOT delete the check; delete it in the
# UI when retiring an app, or it will (correctly) go down.
#
# The runner's own check (heartbeat-runner) has a shorter grace than the
# service checks, so if the runner dies its alert arrives first and explains
# why every service check is about to go down with it.
set -u

api="${HC_API_URL}"
ping="${api}/ping/${HC_PING_KEY}"
interval="${HEARTBEAT_INTERVAL:-60}"
fail_after="${HEARTBEAT_FAIL_AFTER:-5}"
state=/tmp/heartbeat
self=heartbeat-runner

mkdir -p "${state}/seen" "${state}/fails"
touch "${state}/last-round"

log() { echo "heartbeat: $*"; }

# kubectl with a hard deadline. Not --request-timeout: with that flag set,
# kubectl 1.37 skips its in-cluster config and dials localhost:8080 instead.
k() { timeout 30 kubectl "$@"; }

# $1 = slug, $2 = tags, $3 = desc, $4 = timeout, $5 = grace
upsert() {
  body=$(jq -nc --arg s "$1" --arg t "$2" --arg d "$3" --argjson to "$4" --argjson gr "$5" \
    '{name: $s, slug: $s, tags: $t, desc: $d, timeout: $to, grace: $gr, channels: "*", unique: ["slug"]}')
  curl -fsS -m 10 -o /dev/null -X POST \
    -H "X-Api-Key: ${HC_API_KEY}" -H "Content-Type: application/json" \
    --data-raw "${body}" "${api}/api/v3/checks/"
}

# $1 = slug[/fail|/log], $2 = body (shown in the event log and the alert)
hc() {
  curl -fsS -m 10 --retry 2 -o /dev/null --data-raw "$2" "${ping}/$1"
}

# Why a workload's pods aren't Ready, e.g. " (sonarr-abc: CrashLoopBackOff)".
pod_states() {
  [ -n "$2" ] || return 0
  s=$(k get pods -n "$1" -l "$2" -o json 2>/dev/null | jq -r '
    [.items[] | .metadata.name as $p
     | if (.status.containerStatuses // []) == [] then "\($p): \(.status.phase)"
       else (.status.containerStatuses[] | select(.ready | not)
             | "\($p): \(.state.waiting.reason // .state.terminated.reason // "not ready")")
       end] | unique | join("; ")')
  [ -n "${s}" ] && printf ' (%s)' "${s}"
}

check_one() {
  slug=$1 kind=$2 ns=$3 name=$4 url=$5 ready=$6 want=$7 selector=$8

  case "${slug}" in
    "" | *[!a-z0-9_-]*)
      log "skipping ${kind} ${ns}/${name}: slug '${slug}' must be lowercase [a-z0-9_-]"
      return
      ;;
  esac

  desc="Heartbeat from the monitoring/healthchecks runner: ${kind} ${ns}/${name} has a Ready pod"
  [ -n "${url}" ] && desc="${desc} and ${url} answers 2xx"
  desc="${desc}. Silence means the workload, the runner or the cluster is gone."
  if [ "$(cat "${state}/seen/${slug}" 2>/dev/null)" != "${desc}" ]; then
    if upsert "${slug}" "k8s ${ns}" "${desc}" 120 300; then
      printf '%s' "${desc}" >"${state}/seen/${slug}"
      log "registered check ${slug} (${kind} ${ns}/${name})"
    else
      log "API upsert of ${slug} failed; retrying next round"
      return
    fi
  fi

  reason=""
  if [ "${want}" -eq 0 ]; then
    reason="${kind} ${ns}/${name} is scaled to 0"
  elif { [ "${kind}" = DaemonSet ] && [ "${ready}" -lt "${want}" ]; } || [ "${ready}" -lt 1 ]; then
    reason="${kind} ${ns}/${name}: ${ready}/${want} pods Ready$(pod_states "${ns}" "${selector}")"
  elif [ -n "${url}" ]; then
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${url}")
    case "${code}" in
      2??) ;;
      000) reason="${kind} ${ns}/${name}: ${url} unreachable" ;;
      *) reason="${kind} ${ns}/${name}: ${url} returned HTTP ${code}" ;;
    esac
  fi

  if [ -z "${reason}" ]; then
    [ -f "${state}/fails/${slug}" ] && log "${slug} recovered"
    rm -f "${state}/fails/${slug}"
    target="${slug}"
    body="ok: ${ready}/${want} Ready${url:+, ${url} 2xx}"
  else
    n=$(($(cat "${state}/fails/${slug}" 2>/dev/null || echo 0) + 1))
    echo "${n}" >"${state}/fails/${slug}"
    log "${slug} unhealthy (${n}/${fail_after}): ${reason}"
    if [ "${n}" -ge "${fail_after}" ]; then
      target="${slug}/fail"
      body="${reason}"
    else
      target="${slug}/log"
      body="unhealthy ${n}/${fail_after}: ${reason}"
    fi
  fi

  # A 404 means the check was deleted in the UI; forget it so the next round
  # re-creates it instead of pinging into the void.
  hc "${target}" "${body}" || {
    log "ping ${slug} failed"
    rm -f "${state}/seen/${slug}"
  }
}

round() {
  # One API call per round. If it fails, ping nothing (not even the runner's
  # own check): silence is the honest answer when we can't see the cluster.
  # kubectl runs on its own line: in `kubectl | jq` the status is jq's, which
  # happily turns empty input into zero rows and a "healthy" self-ping.
  # Rows are "|"-separated, not tabs: tab is IFS whitespace, so an empty url
  # field would collapse and shift every column after it.
  workloads=$(k get deployments,statefulsets,daemonsets -A -o json) || {
    log "listing workloads failed; skipping round"
    return
  }
  rows=$(printf '%s' "${workloads}" | jq -r '
    .items[] | select(.metadata.annotations["healthchecks.io/slug"] != null)
    | [ .metadata.annotations["healthchecks.io/slug"], .kind,
        .metadata.namespace, .metadata.name,
        (.metadata.annotations["healthchecks.io/url"] // ""),
        (if .kind == "DaemonSet" then .status.numberReady // 0 else .status.readyReplicas // 0 end),
        (if .kind == "DaemonSet" then .status.desiredNumberScheduled // 0 else .spec.replicas // 1 end),
        ([.spec.selector.matchLabels // {} | to_entries[] | "\(.key)=\(.value)"] | join(",")) ]
    | map(tostring | gsub("[|\n]"; "_")) | join("|")') || {
    log "parsing workloads failed; skipping round"
    return
  }

  dupes=$(printf '%s\n' "${rows}" | cut -d'|' -f1 | sort | uniq -d)
  [ -n "${dupes}" ] && log "WARNING: slug used by more than one workload: ${dupes}"

  count=0
  while IFS='|' read -r slug kind ns name url ready want selector; do
    [ -n "${slug}" ] || continue
    check_one "${slug}" "${kind}" "${ns}" "${name}" "${url}" "${ready}" "${want}" "${selector}"
    count=$((count + 1))
  done <<EOF
${rows}
EOF

  hc "${self}" "ok: ${count} annotated workloads" || log "ping ${self} failed"
}

until upsert "${self}" infra \
  "Pinged every round by the monitoring/healthchecks heartbeat runner. Shorter grace than the service checks it feeds, so this alerts first if the runner dies." \
  120 60; do
  log "Healthchecks API not reachable yet; retrying in 10s"
  touch "${state}/last-round"
  sleep 10
done
log "started: every ${interval}s, /fail after ${fail_after} failing rounds"

while :; do
  round
  touch "${state}/last-round"
  sleep "${interval}"
done
