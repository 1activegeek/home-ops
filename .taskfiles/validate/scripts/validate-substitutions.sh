#!/usr/bin/env bash
# Detects Flux variable substitution collisions.
# Warns when ${VAR} patterns appear in YAML values that are NOT known Flux cluster-secrets,
# since Flux's postBuild.substituteFrom will silently strip them (replacing with empty string).
# App-level variables that should survive must use $${VAR} escaping.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"
SOPS_FILE="${KUBERNETES_DIR}/components/sops/cluster-secrets.sops.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

echo "=== Detecting Flux \${VAR} substitution collisions ==="
echo ""

# Extract known cluster-secret variable names from the SOPS file key names
# The SOPS file has encrypted values, but the keys are in plaintext in stringData
KNOWN_VARS=()
if [[ -f "$SOPS_FILE" ]]; then
  while IFS= read -r var; do
    [[ -n "$var" ]] && KNOWN_VARS+=("$var")
  done < <(yq eval '.stringData | keys | .[]' "$SOPS_FILE" 2>/dev/null)
fi

if [[ ${#KNOWN_VARS[@]} -eq 0 ]]; then
  echo -e "${YELLOW}⚠${NC}  Could not read cluster-secrets variable names from ${SOPS_FILE}"
  echo "   (This is expected if the file is encrypted and you haven't decrypted it)"
  echo "   Defaulting to known variable names from codebase analysis..."
  # Hardcoded fallback based on known cluster-secrets
  KNOWN_VARS=(
    SECRET_DOMAIN
    CLUSTER_DOMAIN
    CLUSTER_VIP
    CLUSTER_NODE_1_IP
    CLUSTER_NODE_2_IP
    CLUSTER_NODE_3_IP
    CLUSTER_LB_IP
    CLUSTER_DNS_IP
    CLUSTER_POD_CIDR
    CLUSTER_SVC_CIDR
    NFS_SERVER
  )
fi

echo "Known Flux substitution variables: ${KNOWN_VARS[*]}"
echo ""

# Build a lookup set
declare -A KNOWN_SET
for v in "${KNOWN_VARS[@]}"; do
  KNOWN_SET["$v"]=1
done

# Scan all non-sops YAML files in kubernetes/apps
while IFS= read -r -d '' file; do
  rel_file="${file#"$REPO_ROOT/"}"

  # Find all ${VAR_NAME} patterns (not $${...} — those are already escaped)
  # We look for $ followed by { but NOT $$ followed by {
  matches=$(grep -oP '(?<!\$)\$\{[A-Z0-9_]+\}' "$file" 2>/dev/null | sort -u) || true
  [[ -z "$matches" ]] && continue

  file_warnings=()
  file_errors=()

  # Check if this file is a ConfigMap (app-level configmaps almost never need Flux substitution)
  is_configmap=false
  if grep -q "kind: ConfigMap" "$file" 2>/dev/null; then
    is_configmap=true
  fi

  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    # Extract the variable name (strip ${ and })
    var_name="${match#\$\{}"
    var_name="${var_name%\}}"

    if [[ -n "${KNOWN_SET[$var_name]:-}" ]]; then
      # Known Flux var — this is intentional substitution, fine
      :
    else
      if $is_configmap; then
        # ConfigMap with unknown Flux var — very likely a bug
        file_errors+=("${match} (ConfigMap — use \$\${${var_name}} to prevent Flux substitution)")
      else
        # Non-ConfigMap with unknown var — warn (may need escaping)
        file_warnings+=("${match} (not a known cluster-secret — use \$\${${var_name}} if this is an app var)")
      fi
    fi
  done <<< "$matches"

  if [[ ${#file_errors[@]} -gt 0 ]]; then
    echo -e "${RED}✗${NC} ${rel_file}:"
    for e in "${file_errors[@]}"; do
      echo "     ERROR: ${e}"
    done
    ((ERRORS += ${#file_errors[@]})) || true
  fi

  if [[ ${#file_warnings[@]} -gt 0 ]]; then
    echo -e "${YELLOW}⚠${NC}  ${rel_file}:"
    for w in "${file_warnings[@]}"; do
      echo "     WARN: ${w}"
    done
    ((WARNINGS += ${#file_warnings[@]})) || true
  fi

done < <(find "$KUBERNETES_DIR/apps" -name "*.yaml" ! -name "*.sops.yaml" -print0)

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}❌ Substitution validation failed: ${ERRORS} error(s), ${WARNINGS} warning(s)${NC}"
  echo ""
  echo "Errors indicate Flux will strip these variables, likely causing runtime failures."
  echo "Fix: escape with \$\${VAR_NAME} in the YAML to preserve them as literal app variables."
  exit 1
elif [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}⚠  Substitution validation: ${WARNINGS} warning(s) — review above${NC}"
  echo ""
  echo "Warnings may indicate app variables that will be silently stripped by Flux."
  echo "If intentional (chart-level variable that Flux should substitute), these are fine."
  exit 0
else
  echo -e "${GREEN}✅ Substitution validation passed — no unknown \${VAR} patterns found${NC}"
fi
