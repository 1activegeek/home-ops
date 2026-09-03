#!/usr/bin/env bash
# Validates that the carried upstream patch for hermes-agent still applies to
# the image tag the HelmRelease pins.
#
# hermes-agent runs a `patch-memory` initContainer that applies
# configmap-memory-patch.yaml (upstream PR NousResearch/hermes-agent#27183 —
# per-user USER.md isolation) onto a copy of three source files taken out of
# the image. If an image bump moves that code, the initContainer hard-fails
# and — because the Deployment strategy is Recreate — hermes-agent stays down
# until the patch is regenerated. This check moves that failure to PR time.
#
# Runs a throwaway pod on the pinned tag and dry-runs the patch inside it, so
# it validates the real image contents rather than a local guess.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_DIR="${REPO_ROOT}/kubernetes/apps/ai/hermes-agent/app"
HELMRELEASE="${APP_DIR}/helmrelease.yaml"
CONFIGMAP="${APP_DIR}/configmap-memory-patch.yaml"
PATCH_KEY="27183-per-user-usermd.diff"
NAMESPACE="ai"
POD="hermes-patchcheck"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Validating carried hermes-agent patch ==="
echo ""

if [[ ! -f "$CONFIGMAP" ]]; then
  echo -e "${GREEN}✓${NC} No carried patch present — nothing to validate."
  echo "   (Expected once #27183 lands upstream and the patch is removed.)"
  exit 0
fi

for bin in kubectl yq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠${NC}  ${bin} not found — skipping."
    exit 0
  fi
done

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo -e "${YELLOW}⚠${NC}  No cluster access (namespace ${NAMESPACE} unreachable) — skipping."
  exit 0
fi

# The three containers share one anchored image block, so any of them resolves
# to the same tag; read the initContainer's, since that is the one that must
# match the source the patch was generated against.
IMAGE=$(yq eval \
  '.spec.values.controllers.main.initContainers.patch-memory.image
   | .repository + ":" + .tag' "$HELMRELEASE")

if [[ -z "$IMAGE" || "$IMAGE" == "null:null" ]]; then
  echo -e "${RED}✗${NC} Could not read the patch-memory image from ${HELMRELEASE#"$REPO_ROOT"/}"
  exit 1
fi

echo "Image under test: ${IMAGE}"

TMPDIR_LOCAL=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR_LOCAL"
  kubectl -n "$NAMESPACE" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

yq eval ".data.\"${PATCH_KEY}\"" "$CONFIGMAP" > "${TMPDIR_LOCAL}/patch.diff"
if [[ ! -s "${TMPDIR_LOCAL}/patch.diff" ]]; then
  echo -e "${RED}✗${NC} Patch key '${PATCH_KEY}' is missing or empty in ${CONFIGMAP#"$REPO_ROOT"/}"
  exit 1
fi

kubectl -n "$NAMESPACE" delete pod "$POD" --ignore-not-found >/dev/null 2>&1
kubectl -n "$NAMESPACE" run "$POD" --image="$IMAGE" --restart=Never \
  --command -- sleep 900 >/dev/null

echo "Waiting for the throwaway pod (image pull can take a few minutes)..."
if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${POD}" --timeout=600s >/dev/null 2>&1; then
  echo -e "${RED}✗${NC} Throwaway pod never became ready — check 'kubectl -n ${NAMESPACE} describe pod ${POD}'"
  exit 1
fi

kubectl -n "$NAMESPACE" cp "${TMPDIR_LOCAL}/patch.diff" "${NAMESPACE}/${POD}:/tmp/patch.diff" >/dev/null

# Mirrors the initContainer in helmrelease.yaml — keep the two in lockstep.
if kubectl -n "$NAMESPACE" exec "$POD" -- sh -c '
    set -eu
    mkdir -p /tmp/w/agent /tmp/w/gateway /tmp/w/tools
    cp /opt/hermes/agent/agent_init.py       /tmp/w/agent/
    cp /opt/hermes/gateway/slash_commands.py /tmp/w/gateway/
    cp /opt/hermes/tools/memory_tool.py      /tmp/w/tools/
    cd /tmp/w
    git apply -v --ignore-whitespace --recount /tmp/patch.diff
    grep -q "^def safe_user_key" tools/memory_tool.py
    grep -q "mem_dir / \"users\"" tools/memory_tool.py
    grep -q "user_id=user_id" agent/agent_init.py
  '; then
  echo ""
  echo -e "${GREEN}✓${NC} Patch applies cleanly to ${IMAGE}"
  exit 0
fi

echo ""
echo -e "${RED}✗${NC} Patch does NOT apply to ${IMAGE}"
echo "   hermes-agent would fail to start on this tag (strategy: Recreate = outage)."
echo "   See docs/hermes-memory-patch.md — regenerate the diff with:"
echo "     gh pr diff 27183 --repo NousResearch/hermes-agent"
echo "   or drop the patch entirely if #27183 has landed upstream."
exit 1
