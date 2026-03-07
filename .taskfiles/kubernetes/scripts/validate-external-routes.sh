#!/usr/bin/env bash
# Validates external HTTPRoute security posture.
#
# Security model in this cluster:
# - envoy-external gateway has a default SecurityPolicy enforcing Authentik forward-auth
# - ALL routes through envoy-external are protected by default (correct/safe)
# - Apps that are intentionally PUBLIC (Authentik login page, webhooks) need an
#   explicit HTTPRoute-level SecurityPolicy to opt out of the gateway-level auth
#
# This script:
# 1. Finds all HTTPRoutes referencing envoy-external
# 2. Checks for any HTTPRoute-level SecurityPolicy overrides (public opt-outs)
# 3. Reports the security posture of each external route
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=== Validating external HTTPRoute security configurations ==="
echo ""
echo "Security model: envoy-external gateway enforces Authentik forward-auth by default."
echo "All external routes are protected unless an explicit SecurityPolicy opts them out."
echo ""

# Collect any SecurityPolicy resources that override auth (opt-out = public routes)
declare -A PUBLIC_ROUTES  # "namespace/route-name" -> file

while IFS= read -r -d '' file; do
  doc_count=$(yq eval-all '[select(.kind == "SecurityPolicy")] | length' "$file" 2>/dev/null || echo 0)
  for ((i = 0; i < doc_count; i++)); do
    sp_ns=$(yq eval-all "select(.kind == \"SecurityPolicy\") | select(document_index == $i) | .metadata.namespace" "$file" 2>/dev/null | head -1)
    # Look for SecurityPolicies targeting HTTPRoutes (not Gateways)
    target_kind=$(yq eval-all "select(.kind == \"SecurityPolicy\") | select(document_index == $i) | .spec.targetRefs[].kind" "$file" 2>/dev/null | head -1)
    target_name=$(yq eval-all "select(.kind == \"SecurityPolicy\") | select(document_index == $i) | .spec.targetRefs[].name" "$file" 2>/dev/null | head -1)

    [[ "$target_kind" != "HTTPRoute" ]] && continue
    [[ -z "$target_name" || "$target_name" == "null" ]] && continue

    route_key="${sp_ns:-unknown}/${target_name}"
    PUBLIC_ROUTES["$route_key"]="${file#"$REPO_ROOT/"}"
  done
done < <(find "$KUBERNETES_DIR/apps" -name "*.yaml" ! -name "*.sops.yaml" -print0)

# Find all HTTPRoutes using envoy-external
ROUTE_COUNT=0
PROTECTED_COUNT=0
PUBLIC_COUNT=0

while IFS= read -r -d '' file; do
  rel_file="${file#"$REPO_ROOT/"}"

  doc_count=$(yq eval-all '[select(.kind == "HTTPRoute")] | length' "$file" 2>/dev/null || echo 0)
  for ((i = 0; i < doc_count; i++)); do
    # Check if this HTTPRoute uses envoy-external
    uses_external=$(yq eval-all "
      select(.kind == \"HTTPRoute\") |
      select(document_index == $i) |
      .spec.parentRefs[]? | select(.name == \"envoy-external\") |
      \"yes\"
    " "$file" 2>/dev/null | head -1)

    [[ "$uses_external" != "yes" ]] && continue

    route_name=$(yq eval-all "select(.kind == \"HTTPRoute\") | select(document_index == $i) | .metadata.name" "$file" 2>/dev/null | head -1)
    route_ns=$(yq eval-all "select(.kind == \"HTTPRoute\") | select(document_index == $i) | .metadata.namespace" "$file" 2>/dev/null | head -1)
    hostnames=$(yq eval-all "select(.kind == \"HTTPRoute\") | select(document_index == $i) | .spec.hostnames[]" "$file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

    [[ -z "$route_name" || "$route_name" == "null" ]] && continue

    ((ROUTE_COUNT++)) || true
    route_key="${route_ns:-unknown}/${route_name}"

    if [[ -n "${PUBLIC_ROUTES[$route_key]:-}" ]]; then
      echo -e "${YELLOW}⚠${NC}  [PUBLIC] ${route_key}"
      echo "   Hostnames: ${hostnames}"
      echo "   Has SecurityPolicy override at: ${PUBLIC_ROUTES[$route_key]}"
      echo "   File: ${rel_file}"
      ((PUBLIC_COUNT++)) || true
    else
      echo -e "${GREEN}✓${NC}  [PROTECTED] ${route_key}"
      echo "   Hostnames: ${hostnames}"
      echo "   Protected by gateway-level Authentik forward-auth (default)"
      ((PROTECTED_COUNT++)) || true
    fi
    echo ""
  done

done < <(find "$KUBERNETES_DIR/apps" -name "*.yaml" ! -name "*.sops.yaml" -print0)

echo "---"
echo "Summary: ${ROUTE_COUNT} external route(s) — ${PROTECTED_COUNT} protected, ${PUBLIC_COUNT} public opt-out"
echo ""

if [[ $ROUTE_COUNT -eq 0 ]]; then
  echo -e "${CYAN}No external HTTPRoutes found.${NC}"
else
  echo -e "${GREEN}✅ All external routes have documented security posture${NC}"
  if [[ $PUBLIC_COUNT -gt 0 ]]; then
    echo ""
    echo "Public routes above bypass Authentik auth. Verify each one is intentionally public."
    echo "If an app has OIDC built-in (Authentik itself, etc.), this is expected."
  fi
fi
