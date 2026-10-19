#!/usr/bin/env bash
# In-cluster auto-restore after a break-glass power-off (HA plan ha-17).
#
# Runs every 5 minutes from the cluster-restore CronJob, which is suspended until
# cluster-shutdown.sh arms it right before powering the nodes off. Arming records
# the nodes' boot IDs on the CronJob. After the nodes are switched back on, this
# script waits for a stable cluster, then runs cluster-startup.sh --yes and tells
# Home Assistant (webhook) so both phones get a "cluster restored" notice.
#
# Stable means, all at once:
#   - every node has rebooted since the power-off (boot ID changed)
#   - every node has been Ready for STABLE_MINUTES (default 10)
#   - every Deployment/DaemonSet/StatefulSet in kube-system, flux-system and
#     longhorn-system is fully ready
#   - no Longhorn volume is faulted
# Any gate not met: log why and exit 0; the next run tries again.
#
# Env: STABLE_MINUTES, MAX_ATTEMPTS (default 3), HA_WEBHOOK_URL (optional).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="cluster-shutdown"
CRONJOB="cluster-restore"
A="home-ops.break-glass"
STABLE_MINUTES="${STABLE_MINUTES:-10}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
CORE_NAMESPACES="kube-system flux-system longhorn-system"

log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }
wait_gate() { log gate "$1; checking again next run"; exit 0; }

notify_ha() {
    local status="$1" message="$2"
    [[ -n "${HA_WEBHOOK_URL:-}" ]] || { log notify "HA_WEBHOOK_URL not set; skipping"; return; }
    local body
    body="$(jq -nc --arg s "${status}" --arg m "${message}" '{status: $s, message: $m}')"
    # Home Assistant is one of the workloads just restored; give it time to start.
    for _ in $(seq 1 60); do
        if curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -d "${body}" "${HA_WEBHOOK_URL}" >/dev/null 2>&1; then
            log notify "Home Assistant notified (${status})"
            return
        fi
        sleep 20
    done
    log WARN "Home Assistant did not answer within 20 minutes; no notification sent"
}

disarm() {
    kubectl -n "${NS}" annotate cronjob "${CRONJOB}" "${A}/boot-ids-" "${A}/powered-off-at-" "${A}/attempts-" >/dev/null
    kubectl -n "${NS}" patch cronjob "${CRONJOB}" --type merge -p '{"spec":{"suspend":true}}' >/dev/null
}

cj="$(kubectl -n "${NS}" get cronjob "${CRONJOB}" -o json)" || { log ERROR "cannot read ${NS}/${CRONJOB}"; exit 1; }
old_boot_ids="$(jq -r --arg k "${A}/boot-ids" '.metadata.annotations[$k] // ""' <<<"${cj}")"
powered_off_at="$(jq -r --arg k "${A}/powered-off-at" '.metadata.annotations[$k] // ""' <<<"${cj}")"
attempts="$(jq -r --arg k "${A}/attempts" '.metadata.annotations[$k] // "0"' <<<"${cj}")"
if [[ -z "${old_boot_ids}" ]]; then
    log idle "not armed (no ${A}/boot-ids); nothing to restore"
    exit 0
fi
log armed "powered off at ${powered_off_at}; attempt $((attempts + 1))/${MAX_ATTEMPTS} once stable"

# Gate 1+2: nodes rebooted and Ready long enough --------------------------------
nodes="$(kubectl get nodes -o json)" || wait_gate "API not answering"
now="$(date -u +%s)"
not_ready="$(jq -r --argjson now "${now}" --argjson min "${STABLE_MINUTES}" --arg old " ${old_boot_ids} " '
    .items[] | . as $n
    | ($n.status.conditions[] | select(.type == "Ready")) as $r
    | if ($old | contains(" " + $n.status.nodeInfo.bootID + " ")) then "\($n.metadata.name) has not rebooted"
      elif $r.status != "True" then "\($n.metadata.name) not Ready"
      elif ($now - ($r.lastTransitionTime | fromdateiso8601)) < ($min * 60) then "\($n.metadata.name) Ready < \($min)m"
      else empty end' <<<"${nodes}")"
[[ -z "${not_ready}" ]] || wait_gate "$(paste -sd ';' - <<<"${not_ready}")"
expected_nodes="$(wc -w <<<"${old_boot_ids}" | tr -d ' ')"
have_nodes="$(jq '.items | length' <<<"${nodes}")"
(( have_nodes >= expected_nodes )) || wait_gate "${have_nodes}/${expected_nodes} nodes registered"

# Gate 3: core platform ready ---------------------------------------------------
for ns in ${CORE_NAMESPACES}; do
    lagging="$(kubectl -n "${ns}" get deployments,daemonsets,statefulsets -o json | jq -r '
        .items[] | {k: .kind, n: .metadata.name,
                    want: (.status.desiredNumberScheduled // .spec.replicas // 0),
                    ready: (.status.numberReady // .status.readyReplicas // 0)}
        | select(.ready < .want) | "\(.k)/\(.n) \(.ready)/\(.want)"')" || wait_gate "cannot list ${ns}"
    [[ -z "${lagging}" ]] || wait_gate "${ns} not ready: $(paste -sd ',' - <<<"${lagging}")"
done

# Gate 4: Longhorn volumes not faulted ------------------------------------------
faulted="$(kubectl -n longhorn-system get volumes.longhorn.io -o json \
    | jq -r '.items[] | select(.status.robustness == "faulted") | .metadata.name')" || wait_gate "cannot list Longhorn volumes"
[[ -z "${faulted}" ]] || wait_gate "faulted Longhorn volumes: $(paste -sd ',' - <<<"${faulted}")"

# Restore -----------------------------------------------------------------------
log restore "cluster stable; running cluster-startup.sh"
kubectl -n "${NS}" annotate cronjob "${CRONJOB}" "${A}/attempts=$((attempts + 1))" --overwrite >/dev/null
if bash "${SCRIPT_DIR}/cluster-startup.sh" --yes; then
    disarm
    notify_ha restored "Cluster restored after the power-off at ${powered_off_at}. Workloads, Postgres, CronJobs and Flux are back; apps may take a few minutes to settle."
    exit 0
fi

if (( attempts + 1 >= MAX_ATTEMPTS )); then
    disarm
    notify_ha failed "Automatic cluster restore failed ${MAX_ATTEMPTS} times. Run scripts/cluster-startup.sh from the Mac and check the cluster-restore job logs."
    exit 1
fi
log WARN "cluster-startup.sh failed; retrying next run"
exit 1
