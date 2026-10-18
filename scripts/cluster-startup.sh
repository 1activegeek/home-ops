#!/usr/bin/env bash
# Undo scripts/cluster-shutdown.sh after the nodes have booted again.
#
# Restores only what the shutdown script changed, using the annotations it left:
#   1. wait for nodes Ready and Longhorn's manager to be up
#   2. wake CNPG Postgres clusters it hibernated
#   3. scale Deployments/StatefulSets back to their recorded replica counts
#   4. resume CronJobs, then Flux Kustomizations + HelmReleases, it suspended
#   5. ask Flux to reconcile
#
# Start the Synology first if apps need NFS; they will sit in ContainerCreating
# until it is back but recover on their own once it is.
#
# Usage: scripts/cluster-startup.sh [--yes]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/kubeconfig}"
A="home-ops.break-glass"

ASSUME_YES=false
for arg in "$@"; do
    case "${arg}" in
        -y|--yes) ASSUME_YES=true ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done

log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }
die() { log ERROR "$1"; exit 1; }

for bin in kubectl jq; do
    command -v "${bin}" >/dev/null || die "missing required tool: ${bin}"
done

if ! ${ASSUME_YES}; then
    read -r -p "Restore workloads stopped by cluster-shutdown.sh? [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || die "aborted"
fi

# 1. Wait for the platform ------------------------------------------------------
log step "1/5 waiting for the API and nodes"
until kubectl get nodes >/dev/null 2>&1; do log wait "API not reachable yet"; sleep 10; done
kubectl wait nodes --all --for=condition=Ready --timeout=15m || die "nodes not Ready"
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=10m \
    || log WARN "longhorn-manager not fully rolled out; continuing"

# selects objects carrying annotation $2 == "$3"
annotated() {
    kubectl get "$1" -A -o json 2>/dev/null \
        | jq -r --arg k "$2" --arg v "$3" '.items[] | select(.metadata.annotations[$k] == $v) | "\(.metadata.namespace) \(.metadata.name)"'
}

# 2. Postgres -------------------------------------------------------------------
log step "2/5 waking Postgres (CNPG)"
annotated clusters.postgresql.cnpg.io "${A}/hibernated" true | while read -r ns name; do
    kubectl -n "${ns}" annotate clusters.postgresql.cnpg.io "${name}" \
        cnpg.io/hibernation=off "${A}/hibernated-" --overwrite >/dev/null \
        && log cnpg "woke ${ns}/${name}"
done

# 3. Replicas -------------------------------------------------------------------
log step "3/5 restoring replica counts"
for kind in deployments statefulsets; do
    kubectl get "${kind}" -A -o json \
        | jq -r --arg k "${A}/replicas" '.items[] | select(.metadata.annotations[$k] != null) | "\(.metadata.namespace) \(.metadata.name) \(.metadata.annotations[$k])"' \
        | while read -r ns name replicas; do
            kubectl -n "${ns}" scale "${kind}" "${name}" --replicas="${replicas}" >/dev/null \
                && kubectl -n "${ns}" annotate "${kind}" "${name}" "${A}/replicas-" >/dev/null \
                && log scale "${kind} ${ns}/${name} -> ${replicas}"
        done
done

# 4. Resume ---------------------------------------------------------------------
log step "4/5 resuming CronJobs and Flux"
for kind in cronjobs kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
    annotated "${kind}" "${A}/suspended" true | while read -r ns name; do
        kubectl -n "${ns}" patch "${kind}" "${name}" --type merge -p '{"spec":{"suspend":false}}' >/dev/null \
            && kubectl -n "${ns}" annotate "${kind}" "${name}" "${A}/suspended-" >/dev/null \
            && log resume "${kind} ${ns}/${name}"
    done
done

# 5. Reconcile ------------------------------------------------------------------
log step "5/5 requesting Flux reconcile"
now="$(date +%s)"
kubectl -n flux-system annotate gitrepository flux-system "reconcile.fluxcd.io/requestedAt=${now}" --overwrite >/dev/null
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json \
    | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        kubectl -n "${ns}" annotate kustomizations.kustomize.toolkit.fluxcd.io "${name}" \
            "reconcile.fluxcd.io/requestedAt=${now}" --overwrite >/dev/null
    done
log done "Restore requested. Watch: kubectl get pods -A | grep -v Running ; flux get ks -A"
