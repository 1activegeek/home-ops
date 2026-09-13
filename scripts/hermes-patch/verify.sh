#!/usr/bin/env bash
# Verify the carried hermes-agent source patch against an image tag.
#
#   scripts/hermes-patch/verify.sh                    # tag from helmrelease.yaml
#   scripts/hermes-patch/verify.sh v2026.10.02        # an explicit candidate tag
#   BACKEND=kubectl scripts/hermes-patch/verify.sh     # force the cluster backend
#
# Two backends, same checks. `docker` runs the image locally and is what CI uses;
# `kubectl` runs a throwaway pod in the cluster and is the local default when no
# docker daemon is around. Auto-detects docker first.
#
# Both run the initContainer's OWN script — extracted from helmrelease.yaml rather
# than copied here, so the check and the deployment can never drift — and then
# overlay the patched files the way the Deployment does and run smoke_test.py
# against them. Static greps only prove the patch landed; the smoke test proves it
# still means the same thing, which is the part that matters after an upstream
# refactor.
#
# Exit 0 = safe to deploy. Non-zero = forward-port the patch with regen.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="$REPO_ROOT/kubernetes/apps/ai/hermes-agent/app"
HR="$APP_DIR/helmrelease.yaml"
PATCH_DIR="$APP_DIR/patches"
HERE="$REPO_ROOT/scripts/hermes-patch"
NS="${NS:-ai}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [[ ! -d "$PATCH_DIR" ]] || ! ls "$PATCH_DIR"/*.diff >/dev/null 2>&1; then
  echo -e "${GREEN}✓${NC} No carried patch present — nothing to verify."
  echo "   (Expected once #27183 lands upstream and the patch is removed.)"
  exit 0
fi

py() { python3 -c 'import yaml' 2>/dev/null || { echo -e "${YELLOW}⚠${NC}  PyYAML not installed — skipping."; exit 0; }; }
py

read -r IMG_REPO IMG_TAG < <(python3 - "$HR" <<'PY'
import sys, yaml
img = yaml.safe_load(open(sys.argv[1]))["spec"]["values"]["controllers"]["main"]["initContainers"]["patch-memory"]["image"]
print(img["repository"], img["tag"])
PY
)
TAG="${1:-$IMG_TAG}"
IMAGE="$IMG_REPO:$TAG"

BACKEND="${BACKEND:-auto}"
if [[ "$BACKEND" == "auto" ]]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    BACKEND=docker
  elif command -v kubectl >/dev/null 2>&1 && kubectl get ns "$NS" >/dev/null 2>&1; then
    BACKEND=kubectl
  else
    echo -e "${YELLOW}⚠${NC}  Neither a docker daemon nor cluster access — skipping."
    exit 0
  fi
fi

echo "=== Verifying the carried hermes-agent patch ==="
echo "Image under test: $IMAGE   (backend: $BACKEND)"
echo ""

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
python3 - "$HR" > "$WORK/init.sh" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))["spec"]["values"]["controllers"]["main"]["initContainers"]["patch-memory"]["command"]
sys.stdout.write(c[-1])
PY

# ---------------------------------------------------------------- docker backend
if [[ "$BACKEND" == docker ]]; then
  mkdir -p "$WORK/patched"
  echo "--> [1/2] applying the patch with the initContainer's own script"
  docker run --rm \
    -v "$PATCH_DIR:/patch:ro" -v "$WORK/patched:/patched" -v "$WORK/init.sh:/init.sh:ro" \
    --entrypoint sh "$IMAGE" /init.sh

  echo "--> [2/2] runtime smoke test against the patched modules"
  MOUNTS=()
  while IFS= read -r rel; do
    MOUNTS+=(-v "$WORK/patched/$rel:/opt/hermes/$rel:ro")
  done < <(cd "$WORK/patched" && find . -name '*.py' | sed 's|^\./||' | sort)
  docker run --rm "${MOUNTS[@]}" \
    -v "$HERE/smoke_test.py:/tmp/smoke_test.py:ro" \
    -e HERMES_HOME=/tmp/hermeshome -w /opt/hermes \
    --entrypoint /opt/hermes/.venv/bin/python "$IMAGE" /tmp/smoke_test.py

# ---------------------------------------------------------------- kubectl backend
else
  POD="hermes-patchcheck"
  cleanup_k8s() {
    kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "$NS" delete cm "$POD-patch" "$POD-init" "$POD-smoke" --ignore-not-found >/dev/null 2>&1 || true
  }
  trap 'cleanup_k8s; rm -rf "$WORK"' EXIT
  cleanup_k8s

  # Only the .diff files — patches/README.md is documentation, not payload.
  PATCH_ARGS=()
  for d in "$PATCH_DIR"/*.diff; do PATCH_ARGS+=(--from-file="$(basename "$d")=$d"); done
  kubectl -n "$NS" create cm "$POD-patch" "${PATCH_ARGS[@]}" >/dev/null
  kubectl -n "$NS" create cm "$POD-init"  --from-file=init.sh="$WORK/init.sh" >/dev/null
  kubectl -n "$NS" create cm "$POD-smoke" --from-file=smoke_test.py="$HERE/smoke_test.py" >/dev/null

  # /initsh, not /init: the image already has a FILE at /init, and mounting a
  # directory over it fails the container create with an opaque runc error.
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS}
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 10000, runAsGroup: 10000}
  volumes:
    - {name: patch, configMap: {name: $POD-patch}}
    - {name: init, configMap: {name: $POD-init}}
    - {name: smoke, configMap: {name: $POD-smoke}}
    - {name: patched, emptyDir: {}}
    - {name: home, emptyDir: {}}
  initContainers:
    - name: patch-memory
      image: $IMAGE
      command: ["sh", "/initsh/init.sh"]
      volumeMounts:
        - {name: patch, mountPath: /patch}
        - {name: patched, mountPath: /patched}
        - {name: init, mountPath: /initsh}
  containers:
    - name: smoke
      image: $IMAGE
      workingDir: /opt/hermes
      command: ["/opt/hermes/.venv/bin/python", "/smoke/smoke_test.py"]
      env:
        - {name: HERMES_HOME, value: /tmp/hermeshome}
      volumeMounts:
        - {name: home, mountPath: /tmp/hermeshome}
        - {name: smoke, mountPath: /smoke}
        - {name: patched, mountPath: /opt/hermes/agent/agent_init.py,        subPath: agent/agent_init.py}
        - {name: patched, mountPath: /opt/hermes/gateway/slash_commands.py,  subPath: gateway/slash_commands.py}
        - {name: patched, mountPath: /opt/hermes/tools/memory_tool.py,       subPath: tools/memory_tool.py}
        - {name: patched, mountPath: /opt/hermes/tools/memory_tool_store.py, subPath: tools/memory_tool_store.py}
YAML

  echo "Waiting for the throwaway pod (image pull can take a few minutes)..."
  PHASE=""
  for _ in $(seq 1 90); do
    PHASE="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$PHASE" in Succeeded|Failed) break;; esac
    sleep 8
  done
  echo ""
  echo "--- initContainer ---"; kubectl -n "$NS" logs "$POD" -c patch-memory 2>&1 || true
  echo "--- smoke test ---";    kubectl -n "$NS" logs "$POD" -c smoke 2>&1 || true
  if [[ "$PHASE" != "Succeeded" ]]; then
    echo ""
    echo -e "${RED}✗${NC} Patch does NOT hold on $IMAGE (pod phase: ${PHASE:-unknown})"
    echo "   hermes-agent would fail to start on this tag (strategy: Recreate = outage)."
    echo "   Forward-port it:  scripts/hermes-patch/regen.sh <old-tag> $TAG"
    echo "   See docs/hermes-memory-patch.md"
    exit 1
  fi
fi

echo ""
echo -e "${GREEN}✓${NC} Patch applies and behaves correctly on $IMAGE"
