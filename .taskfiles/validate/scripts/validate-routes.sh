#!/usr/bin/env bash
# Cross-references HTTPRoute backendRef service names against Services defined
# in the same app directory. Catches the common failure where a backendRef uses
# the wrong service name (e.g. "myapp" vs "myapp-app" after chart rendering).
#
# Strategy:
# - For bjw-s app-template HelmReleases: service names are predictable
#   (<release-name>-<service-key>). We validate these exactly.
# - For upstream Helm charts (authentik, grafana, etc.): service names come
#   from the chart itself. We can't predict them statically, so we warn only.
# - A static HTTPRoute in the SAME app directory as a bjw-s HelmRelease is
#   validated against that HelmRelease's services.
# - A static HTTPRoute with no corresponding bjw-s HelmRelease gets a warning.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

echo "=== Validating HTTPRoute backend service references ==="
echo ""

# For each app directory, determine if it uses bjw-s app-template
# (identified by having .spec.values.service with controller refs) and if so,
# what services it would create: <helmrelease-name>-<service-key>
#
# Key: app-dir path -> newline-delimited service names
declare -A BJWS_SERVICES  # app_dir -> newline-separated service names
declare -A BJWS_HR_NAME   # app_dir -> helmrelease name

while IFS= read -r -d '' file; do
  app_dir=$(dirname "$file")  # the .../app/ directory
  hr_name=$(yq eval '.metadata.name // ""' "$file" 2>/dev/null | head -1)
  [[ -z "$hr_name" || "$hr_name" == "null" ]] && continue

  # Check if this is a bjw-s app-template HelmRelease by verifying the OCIRepository
  # in the same directory points to app-template. Upstream charts (longhorn, grafana,
  # authentik, etc.) also have .spec.values.service but don't use bjw-s naming conventions.
  is_bjws=false
  if [[ -f "${app_dir}/ocirepository.yaml" ]]; then
    oci_url=$(yq eval '.spec.url // ""' "${app_dir}/ocirepository.yaml" 2>/dev/null | head -1)
    if [[ "$oci_url" == *"app-template"* || "$oci_url" == *"bjw-s"* ]]; then
      is_bjws=true
    fi
  fi
  $is_bjws || continue

  # Check for .spec.values.service block
  service_block=$(yq eval '.spec.values.service' "$file" 2>/dev/null | head -1)
  [[ -z "$service_block" || "$service_block" == "null" ]] && continue

  # Collect service keys and build service names using actual bjw-s naming rules:
  # - 1 service  → name is just <release-name> (no key suffix)
  # - 2+ services → name is <release-name>-<service-key> for each
  service_keys=()
  while IFS= read -r svc_key; do
    [[ -z "$svc_key" || "$svc_key" == "null" ]] && continue
    service_keys+=("$svc_key")
  done < <(yq eval '.spec.values.service | keys | .[]' "$file" 2>/dev/null | grep -v "^null$")

  [[ ${#service_keys[@]} -eq 0 ]] && continue

  svc_names=""
  if [[ ${#service_keys[@]} -eq 1 ]]; then
    # Single service: name is just the release name
    svc_names="${hr_name}"$'\n'
  else
    # Multiple services: name is <release-name>-<key>
    for svc_key in "${service_keys[@]}"; do
      svc_names+="${hr_name}-${svc_key}"$'\n'
    done
  fi

  if [[ -n "$svc_names" ]]; then
    BJWS_SERVICES["$app_dir"]="$svc_names"
    BJWS_HR_NAME["$app_dir"]="$hr_name"
  fi
done < <(find "$KUBERNETES_DIR/apps" -name "helmrelease.yaml" -print0)

# Also index all bjw-s services globally for cross-directory lookup
ALL_BJWS_SERVICES=""
for dir in "${!BJWS_SERVICES[@]}"; do
  ALL_BJWS_SERVICES+="${BJWS_SERVICES[$dir]}"
done

echo "bjw-s app-template apps detected: ${#BJWS_SERVICES[@]}"
echo ""

# --- Validate static HTTPRoute files ---
echo "--- Checking static httproute.yaml files ---"

while IFS= read -r -d '' file; do
  rel_file="${file#"$REPO_ROOT/"}"
  app_dir=$(dirname "$file")

  doc_count=$(yq eval-all '[select(.kind == "HTTPRoute")] | length' "$file" 2>/dev/null || echo 0)
  for ((i = 0; i < doc_count; i++)); do
    route_name=$(yq eval-all "select(.kind == \"HTTPRoute\") | select(document_index == $i) | .metadata.name" "$file" 2>/dev/null | head -1)
    [[ -z "$route_name" || "$route_name" == "null" ]] && continue

    # Check if this app dir has a known bjw-s HelmRelease
    has_bjws="${BJWS_SERVICES[$app_dir]:-}"

    while IFS= read -r backend_name; do
      [[ -z "$backend_name" || "$backend_name" == "null" ]] && continue
      [[ "$backend_name" == *'${'* ]] && continue  # skip template vars

      if [[ -n "$has_bjws" ]]; then
        # We can validate exactly against the bjw-s services from this app dir
        if echo "$has_bjws" | grep -Fxq "$backend_name"; then
          echo -e "${GREEN}✓${NC} ${route_name}: backendRef '${backend_name}' matches bjw-s service"
        else
          # Check if it matches any bjw-s service globally (maybe cross-namespace)
          if echo "$ALL_BJWS_SERVICES" | grep -Fxq "$backend_name"; then
            echo -e "${YELLOW}⚠${NC}  ${route_name}: backendRef '${backend_name}' exists in a different app — verify namespace"
            echo "   File: ${rel_file}"
            ((WARNINGS++)) || true
          else
            hr_name="${BJWS_HR_NAME[$app_dir]:-unknown}"
            expected=$(echo "$has_bjws" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
            echo -e "${RED}✗${NC} ${route_name}: backendRef '${backend_name}' — not a valid service for '${hr_name}'"
            echo "   Expected one of: ${expected}"
            echo "   File: ${rel_file}"
            ((ERRORS++)) || true
          fi
        fi
      else
        # No bjw-s HelmRelease in this dir — likely upstream chart, can't validate statically
        echo -e "${YELLOW}⚠${NC}  ${route_name}: backendRef '${backend_name}' — upstream chart, cannot verify statically"
        echo "   File: ${rel_file}"
        ((WARNINGS++)) || true
      fi
    done < <(yq eval-all "select(.kind == \"HTTPRoute\") | select(document_index == $i) | .spec.rules[].backendRefs[].name" "$file" 2>/dev/null | grep -v "^null$")
  done

done < <(find "$KUBERNETES_DIR/apps" -name "httproute*.yaml" -print0)

echo ""

# --- Validate HelmRelease embedded route backendRefs with explicit name (not identifier) ---
echo "--- Checking HelmRelease embedded route backendRefs (name-based, not identifier) ---"

while IFS= read -r -d '' file; do
  rel_file="${file#"$REPO_ROOT/"}"
  app_dir=$(dirname "$file")
  hr_name=$(yq eval '.metadata.name // ""' "$file" 2>/dev/null | head -1)
  [[ -z "$hr_name" || "$hr_name" == "null" ]] && continue

  has_bjws="${BJWS_SERVICES[$app_dir]:-}"

  while IFS='|' read -r route_key backend_name; do
    [[ -z "$backend_name" || "$backend_name" == "null" ]] && continue
    [[ "$backend_name" == *'${'* ]] && continue

    if [[ -n "$has_bjws" ]]; then
      if echo "$has_bjws" | grep -Fxq "$backend_name"; then
        echo -e "${GREEN}✓${NC} ${hr_name} route '${route_key}': backendRef '${backend_name}' matches bjw-s service"
      else
        expected=$(echo "$has_bjws" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
        echo -e "${RED}✗${NC} ${hr_name} route '${route_key}': backendRef '${backend_name}' — not a valid service"
        echo "   Expected one of: ${expected}"
        echo "   File: ${rel_file}"
        ((ERRORS++)) || true
      fi
    fi
    # If not bjw-s, skip (identifier refs are validated by the chart itself)
  done < <(yq eval '
    .spec.values.route | to_entries | .[] |
    .key as $rkey |
    .value.rules[]?.backendRefs[]? |
    select(has("name")) |
    ($rkey + "|" + .name)
  ' "$file" 2>/dev/null | grep -v "^null$\|^|$")

done < <(find "$KUBERNETES_DIR/apps" -name "helmrelease.yaml" -print0)

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}❌ Route validation failed: ${ERRORS} backendRef(s) reference non-existent Services${NC}"
  echo "   (${WARNINGS} warning(s) for upstream charts that cannot be statically validated)"
  exit 1
else
  echo -e "${GREEN}✅ Route validation passed${NC} (${WARNINGS} upstream-chart routes could not be statically verified)"
fi
