#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track validation status
VALIDATION_FAILED=false

echo "🔍 Validating external HTTPRoute security configurations..."
echo ""

# Find all YAML files and extract HTTPRoutes using envoy-external
TEMP_FILE=$(mktemp)

find kubernetes/apps -name "*.yaml" -type f -print0 | while IFS= read -r -d '' file; do
  # Check if file contains HTTPRoute with envoy-external
  if grep -q "kind: HTTPRoute" "$file" 2>/dev/null && \
     grep -q "name: envoy-external" "$file" 2>/dev/null; then

    # Extract HTTPRoute resources from the file
    yq eval-all 'select(.kind == "HTTPRoute")' "$file" 2>/dev/null | \
      yq eval-all -o=json '.' 2>/dev/null | \
      jq -r --arg file "$file" '
        select(.spec.parentRefs[]? | select(.name == "envoy-external")) |
        {
          name: .metadata.name,
          namespace: .metadata.namespace,
          auth_required: (.metadata.labels["security.home-ops/auth-required"] // ""),
          public: (.metadata.labels["security.home-ops/public"] // ""),
          file: $file
        } | @json
      ' 2>/dev/null >> "$TEMP_FILE"
  fi
done

# Process the collected routes
declare -A CHECKED_ROUTES

while IFS= read -r route_json; do
  if [[ -z "$route_json" ]]; then
    continue
  fi

  route_name=$(echo "$route_json" | jq -r '.name // empty')
  route_namespace=$(echo "$route_json" | jq -r '.namespace // empty')
  auth_required=$(echo "$route_json" | jq -r '.auth_required // empty')
  public=$(echo "$route_json" | jq -r '.public // empty')
  route_file=$(echo "$route_json" | jq -r '.file // empty')

  # Skip invalid entries
  if [[ -z "$route_name" || -z "$route_namespace" ]]; then
    continue
  fi

  # Skip if we've already checked this route
  route_key="${route_namespace}/${route_name}"
  if [[ -n "${CHECKED_ROUTES[$route_key]:-}" ]]; then
    continue
  fi
  CHECKED_ROUTES[$route_key]=1

  # Validate security labels
  if [[ "$auth_required" == "true" ]]; then
    echo -e "${GREEN}✓${NC} ${route_namespace}/${route_name} - Protected (auth-required: true)"
    echo "   File: $route_file"
  elif [[ "$public" == "true" ]]; then
    echo -e "${YELLOW}⚠${NC}  ${route_namespace}/${route_name} - Public (verify opt-out SecurityPolicy exists)"
    echo "   File: $route_file"
    echo "   Note: Ensure public-access component is included in kustomization.yaml"
  else
    echo -e "${RED}✗${NC} ${route_namespace}/${route_name} - MISSING SECURITY LABEL"
    echo "   File: $route_file"
    echo "   Action: Add one of these labels:"
    echo "     - security.home-ops/auth-required: \"true\"  (for protected routes)"
    echo "     - security.home-ops/public: \"true\"          (for public routes)"
    echo ""
    VALIDATION_FAILED=true
  fi
done < "$TEMP_FILE"

rm -f "$TEMP_FILE"

echo ""

if [[ "$VALIDATION_FAILED" == "true" ]]; then
  echo -e "${RED}❌ Validation failed!${NC}"
  echo ""
  echo "External routes must have explicit security configuration:"
  echo "  1. Add security.home-ops/auth-required: \"true\" to rely on gateway default auth"
  echo "  2. Add security.home-ops/public: \"true\" AND include public-access component to opt-out"
  echo ""
  exit 1
else
  echo -e "${GREEN}✅ All external routes have proper security configuration${NC}"
  exit 0
fi
