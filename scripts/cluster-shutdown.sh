#!/usr/bin/env bash
# BREAK-GLASS: gracefully power off the whole cluster (e.g. power outage on UPS).
#
# Not for routine maintenance. It deliberately bypasses GitOps: it suspends Flux
# and scales workloads by hand so Longhorn volumes and Postgres stop cleanly
# before the nodes power off. Undo it with scripts/cluster-startup.sh once power
# is back and the nodes have booted.
#
# Every change is recorded as an annotation on the object it touched, so the
# startup script needs no local state and only restores what this script changed:
#   home-ops.break-glass/replicas   original replica count (Deployment/StatefulSet)
#   home-ops.break-glass/suspended  "true" on Flux objects / CronJobs this script suspended
#   home-ops.break-glass/hibernated "true" on CNPG clusters this script hibernated
#
# Order:
#   1. suspend Flux Kustomizations + HelmReleases (so nothing gets scaled back up)
#   2. suspend CronJobs
#   3. hibernate CNPG Postgres clusters (clean checkpoint, PVCs kept)
#   4. scale Deployments, then StatefulSets, to 0 (two passes, for operators)
#   5. force-remove pods stuck Terminating (dead NFS mounts never unmount)
#   6. wait for Longhorn volumes to detach
#   7. talosctl shutdown all nodes at once (no drain; workloads are already gone)
#
# Usage:
#   scripts/cluster-shutdown.sh            # asks for confirmation
#   scripts/cluster-shutdown.sh --yes      # no prompt
#   scripts/cluster-shutdown.sh --no-poweroff   # quiesce only, leave nodes on
#
# Env overrides: KUBECONFIG, TALOSCONFIG, NODES (space separated IPs; default: every node's InternalIP),
#   DETACH_TIMEOUT (seconds, default 300), KEEP_NAMESPACES.
#
# Also runs in-cluster as the first step of the cluster-shutdown Job
# (kubernetes/apps/cluster-shutdown), with --yes --no-poweroff: kubectl uses the
# pod's service account, and a second container powers the nodes off.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN_CLUSTER=false
[[ -n "${KUBERNETES_SERVICE_HOST:-}" && -z "${KUBECONFIG:-}" ]] && IN_CLUSTER=true
${IN_CLUSTER} || export KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-${ROOT_DIR}/talos/clusterconfig/talosconfig}"
DETACH_TIMEOUT="${DETACH_TIMEOUT:-300}"
# Namespaces whose workloads must keep running until the nodes power off.
KEEP_NAMESPACES="${KEEP_NAMESPACES:-kube-system kube-public kube-node-lease flux-system longhorn-system}"
A="home-ops.break-glass"

ASSUME_YES=false
POWEROFF=true
for arg in "$@"; do
    case "${arg}" in
        -y|--yes) ASSUME_YES=true ;;
        --no-poweroff) POWEROFF=false ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done

log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }
die() { log ERROR "$1"; exit 1; }
kept() { [[ " ${KEEP_NAMESPACES} " == *" $1 "* ]]; }

for bin in kubectl jq; do
    command -v "${bin}" >/dev/null || die "missing required tool: ${bin}"
done
${IN_CLUSTER} || [[ -f "${KUBECONFIG}" ]] || die "KUBECONFIG not found: ${KUBECONFIG}"
if ${POWEROFF}; then
    command -v talosctl >/dev/null || die "missing required tool: talosctl"
    [[ -f "${TALOSCONFIG}" ]] || die "TALOSCONFIG not found: ${TALOSCONFIG}"
fi
kubectl get nodes >/dev/null 2>&1 || die "cannot reach the Kubernetes API"

# Talk to the nodes by their InternalIP; the talosconfig's own endpoints can be stale.
NODES="${NODES:-$(kubectl get nodes -o json | jq -r '[.items[].status.addresses[] | select(.type == "InternalIP") | .address] | join(" ")')}"
NODES="$(xargs <<<"${NODES}")"
[[ -n "${NODES}" ]] || die "could not determine node IPs; set NODES"
NODES_CSV="${NODES// /,}"
FIRST_NODE="${NODES%% *}"
talos() { talosctl -e "${FIRST_NODE}" -n "${NODES_CSV}" "$@"; }

if ! ${ASSUME_YES}; then
    echo "This will stop every workload and POWER OFF nodes: ${NODES}"
    ${POWEROFF} || echo "(--no-poweroff: nodes stay on)"
    read -r -p "Type SHUTDOWN to continue: " answer
    [[ "${answer}" == "SHUTDOWN" ]] || die "aborted"
fi

# 1. Flux --------------------------------------------------------------------
suspend_flux_kind() {
    local kind="$1"
    kubectl get "${kind}" -A -o json 2>/dev/null \
        | jq -r '.items[] | select(.spec.suspend != true) | "\(.metadata.namespace) \(.metadata.name)"' \
        | while read -r ns name; do
            kubectl -n "${ns}" annotate "${kind}" "${name}" "${A}/suspended=true" --overwrite >/dev/null
            kubectl -n "${ns}" patch "${kind}" "${name}" --type merge -p '{"spec":{"suspend":true}}' >/dev/null \
                && log flux "suspended ${kind} ${ns}/${name}"
        done
}
log step "1/7 suspending Flux"
suspend_flux_kind kustomizations.kustomize.toolkit.fluxcd.io
suspend_flux_kind helmreleases.helm.toolkit.fluxcd.io

# 2. CronJobs ----------------------------------------------------------------
log step "2/7 suspending CronJobs"
kubectl get cronjobs -A -o json \
    | jq -r '.items[] | select(.spec.suspend != true) | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        kept "${ns}" && continue
        kubectl -n "${ns}" annotate cronjob "${name}" "${A}/suspended=true" --overwrite >/dev/null
        kubectl -n "${ns}" patch cronjob "${name}" --type merge -p '{"spec":{"suspend":true}}' >/dev/null \
            && log cron "suspended ${ns}/${name}"
    done

# 3. CNPG ----------------------------------------------------------------------
log step "3/7 hibernating Postgres (CNPG)"
if kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
    kubectl get clusters.postgresql.cnpg.io -A -o json \
        | jq -r '.items[] | select(.metadata.annotations["cnpg.io/hibernation"] != "on") | "\(.metadata.namespace) \(.metadata.name)"' \
        | while read -r ns name; do
            kubectl -n "${ns}" annotate clusters.postgresql.cnpg.io "${name}" \
                "${A}/hibernated=true" cnpg.io/hibernation=on --overwrite >/dev/null \
                && log cnpg "hibernating ${ns}/${name}"
        done
    for _ in $(seq 1 36); do
        left=$(kubectl get pods -A -l cnpg.io/cluster --no-headers 2>/dev/null | grep -vc 'Completed' || true)
        [[ "${left}" -eq 0 ]] && break
        log cnpg "waiting for ${left} Postgres pod(s) to stop"
        sleep 5
    done
fi

# 4. Scale to zero -------------------------------------------------------------
scale_kind() {
    local kind="$1"
    kubectl get "${kind}" -A -o json \
        | jq -r --arg k "${A}/replicas" '.items[] | select((.spec.replicas // 0) > 0) | "\(.metadata.namespace) \(.metadata.name) \(.spec.replicas) \(.metadata.annotations[$k] // "")"' \
        | while read -r ns name replicas recorded; do
            kept "${ns}" && continue
            # Keep the first recorded count; a second pass must not overwrite it.
            [[ -z "${recorded}" ]] && kubectl -n "${ns}" annotate "${kind}" "${name}" "${A}/replicas=${replicas}" --overwrite >/dev/null
            kubectl -n "${ns}" scale "${kind}" "${name}" --replicas=0 >/dev/null \
                && log scale "${kind} ${ns}/${name} ${replicas} -> 0"
        done
}
log step "4/7 scaling workloads to zero"
# Deployments first so operators stop before the StatefulSets they own; the second
# pass catches anything an operator re-scaled before it went away.
for pass in 1 2; do
    scale_kind deployments
    scale_kind statefulsets
    [[ "${pass}" -eq 1 ]] && sleep 20
done

# 5. Stuck pods ------------------------------------------------------------------
log step "5/7 waiting for pods to terminate"
deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
    left=$(kubectl get pods -A -o json | jq --arg keep "${KEEP_NAMESPACES}" '
        [.items[] | select(.metadata.ownerReferences[0].kind != "DaemonSet")
                  | select(.status.phase == "Running" or .status.phase == "Pending")
                  | select(.metadata.namespace as $ns | (" " + $keep + " ") | contains(" " + $ns + " ") | not)] | length')
    [[ "${left}" -eq 0 ]] && break
    log pods "${left} pod(s) still running"
    sleep 10
done
# Pods holding a dead NFS mount never finish terminating; drop them so Longhorn can detach.
kubectl get pods -A -o json \
    | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        kept "${ns}" && continue
        kubectl -n "${ns}" delete pod "${name}" --force --grace-period=0 >/dev/null 2>&1 \
            && log pods "force-removed stuck pod ${ns}/${name}"
    done

# 6. Longhorn --------------------------------------------------------------------
log step "6/7 waiting for Longhorn volumes to detach (up to ${DETACH_TIMEOUT}s)"
if kubectl get crd volumes.longhorn.io >/dev/null 2>&1; then
    deadline=$((SECONDS + DETACH_TIMEOUT))
    while :; do
        attached=$(kubectl -n longhorn-system get volumes.longhorn.io -o json \
            | jq -r '.items[] | select(.status.state != "detached") | "\(.metadata.name)(\(.status.kubernetesStatus.namespace // "?")/\(.status.kubernetesStatus.workloadsStatus[0].workloadName // "?"))"')
        [[ -z "${attached}" ]] && { log longhorn "all volumes detached"; break; }
        if (( SECONDS >= deadline )); then
            log WARN "still attached after ${DETACH_TIMEOUT}s, continuing anyway:"
            printf '  %s\n' ${attached}
            break
        fi
        log longhorn "$(wc -w <<<"${attached}" | tr -d ' ') volume(s) still attached"
        sleep 10
    done
fi

# 7. Power off -------------------------------------------------------------------
if ! ${POWEROFF}; then
    log step "7/7 skipped (--no-poweroff). Cluster is quiesced; run scripts/cluster-startup.sh to undo."
    exit 0
fi
log step "7/7 powering off nodes: ${NODES}"
# --force skips Talos' cordon/drain: workloads are already stopped, and draining
# three control-plane nodes at once just fights PodDisruptionBudgets.
talos shutdown --force --wait=false || log WARN "talosctl shutdown returned non-zero"

deadline=$((SECONDS + 300))
for node in ${NODES}; do
    while (( SECONDS < deadline )) && ping -c1 -t1 "${node}" >/dev/null 2>&1; do sleep 5; done
    if ping -c1 -t1 "${node}" >/dev/null 2>&1; then
        log WARN "${node} still answers ping; check it by hand"
    else
        log node "${node} is down"
    fi
done
log done "Cluster is off. After power returns: boot the nodes, then run scripts/cluster-startup.sh"
