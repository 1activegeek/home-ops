#!/usr/bin/env bash
# Compare the Talos and Kubernetes versions the nodes run with the versions on
# main, and fail once they have differed for more than GRACE_DAYS.
#
# Desired (mounted from Git by the version-drift-desired ConfigMap):
#   Talos       desired-versions.yaml  talosRuntimeVersion
#   Kubernetes  talenv.yaml            kubernetesVersion
# Live (Node objects): .status.nodeInfo.osImage ("Talos (v1.14.4)") and
# .status.nodeInfo.kubeletVersion, per node.
#
# State: the ConfigMap STATE_CONFIGMAP holds driftSince (epoch seconds when
# drift was first seen; empty while in sync). It is cleared as soon as every
# node matches again, so the clock measures one continuous period of drift.
#
# Exit 0 = in sync, or drifting for less than GRACE_DAYS. Exit 1 = drifting for
# longer (alert). Exit 2 = the check itself could not run (also alerts).
set -euo pipefail

grace_days="${GRACE_DAYS:-7}"
desired_dir="${DESIRED_DIR:-/desired}"
state_cm="${STATE_CONFIGMAP:-version-drift-state}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { log "ERROR: $*"; exit 2; }

# Top-level `key: value` from a flat YAML file, comments stripped.
yaml_key() {
  sed -n "s/^$1:[[:space:]]*\"\{0,1\}\([^\"#[:space:]]*\).*/\1/p" "$2" | head -n1
}

want_talos=$(yaml_key talosRuntimeVersion "${desired_dir}/desired-versions.yaml")
want_k8s=$(yaml_key kubernetesVersion "${desired_dir}/talenv.yaml")
[ -n "${want_talos}" ] || die "talosRuntimeVersion not found in desired-versions.yaml"
[ -n "${want_k8s}" ] || die "kubernetesVersion not found in talenv.yaml"

ns=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
nodes=$(kubectl get nodes -o json) || die "cannot list nodes"
rows=$(jq -r '.items[] | [.metadata.name, .status.nodeInfo.osImage, .status.nodeInfo.kubeletVersion] | @tsv' <<<"${nodes}")
[ -n "${rows}" ] || die "no nodes returned"

drift=()
while IFS=$'\t' read -r node os kubelet; do
  talos=$(sed -n 's/^Talos (\(v[^)]*\))$/\1/p' <<<"${os}")
  log "${node}: Talos ${talos:-?} (${os}), Kubernetes ${kubelet}"
  [ "${talos}" = "${want_talos}" ] || drift+=("${node} Talos ${talos:-${os}} != ${want_talos}")
  [ "${kubelet}" = "${want_k8s}" ] || drift+=("${node} Kubernetes ${kubelet} != ${want_k8s}")
done <<<"${rows}"

state() {
  kubectl -n "${ns}" patch configmap "${state_cm}" --type merge \
    -p "$(jq -nc --arg s "$1" --arg d "$2" '{data: {driftSince: $s, detail: $d}}')" >/dev/null ||
    die "cannot update ConfigMap ${state_cm}"
}

if [ "${#drift[@]}" -eq 0 ]; then
  state "" ""
  log "in sync: all nodes run Talos ${want_talos}, Kubernetes ${want_k8s}"
  exit 0
fi

detail=$(printf '%s; ' "${drift[@]}")
detail="${detail%; }"
now=$(date +%s)
since=$(kubectl -n "${ns}" get configmap "${state_cm}" -o jsonpath='{.data.driftSince}') ||
  die "cannot read ConfigMap ${state_cm}"
case "${since}" in
  '' | *[!0-9]*) since="${now}" ;;
esac
state "${since}" "${detail}"

age_days=$(((now - since) / 86400))
since_h=$(date -u -d "@${since}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "${since}")
log "DRIFT since ${since_h} (${age_days}d, grace ${grace_days}d): ${detail}"
if [ "$((now - since))" -gt "$((grace_days * 86400))" ]; then
  log "FAIL: cluster has not matched Git for more than ${grace_days} days." \
    "Upgrade the nodes or correct the desired version in Git."
  exit 1
fi
log "within grace period; not alerting yet"
exit 0
