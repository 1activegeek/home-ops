#!/usr/bin/env bash
# Cross-references Secret keys provided by ExternalSecret templates against
# the keys expected by workloads (envFrom, existingSecret references).
#
# Two checks:
# 1. Print all known secrets and their keys (always useful for debugging)
# 2. Check existingSecret + existingSecretKey combos in HelmRelease values
#    against the keys provided by ExternalSecret template.data
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

echo "=== Cross-referencing Secret keys against workload references ==="
echo ""

# Build a map of secret-name -> comma-separated provided keys, keyed by app-dir
declare -A SECRET_KEYS    # "app_dir/secret_name" -> comma-separated keys
declare -A SECRET_BY_NAME # "secret_name" -> comma-separated keys (global)

while IFS= read -r -d '' file; do
  app_dir=$(dirname "$file")

  doc_count=$(yq eval-all '[select(.kind == "ExternalSecret")] | length' "$file" 2>/dev/null || echo 0)
  for ((i = 0; i < doc_count; i++)); do
    target_name=$(yq eval-all "select(.kind == \"ExternalSecret\") | select(document_index == $i) | .spec.target.name" "$file" 2>/dev/null | head -1)
    [[ -z "$target_name" || "$target_name" == "null" ]] && continue

    # Extract all keys from template.data
    keys=$(yq eval-all "select(.kind == \"ExternalSecret\") | select(document_index == $i) | .spec.target.template.data | keys | .[]" "$file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    [[ -z "$keys" ]] && continue

    map_key="${app_dir}::${target_name}"
    SECRET_KEYS["$map_key"]="$keys"
    SECRET_BY_NAME["$target_name"]="$keys"
  done
done < <(find "$KUBERNETES_DIR/apps" -name "externalsecret.yaml" -print0)

if [[ ${#SECRET_KEYS[@]} -eq 0 ]]; then
  echo -e "${YELLOW}⚠${NC}  No ExternalSecret template data found — skipping"
  exit 0
fi

echo "Found ${#SECRET_KEYS[@]} secret(s) with template.data keys"
echo ""

# --- Check 1: existingSecret + key combos in HelmRelease values ---
echo "--- Checking existingSecret references in HelmRelease values ---"
found_refs=false

while IFS= read -r -d '' file; do
  app_dir=$(dirname "$file")
  hr_name=$(yq eval '.metadata.name // ""' "$file" 2>/dev/null | head -1)
  [[ -z "$hr_name" || "$hr_name" == "null" ]] && continue

  # Extract existingSecret + existingSecretKey pairs
  # yq outputs one item per match; we format as "secret_name:key_name"
  refs=$(yq eval '
    [.. | select(type == "!!map") |
    select(has("existingSecret")) |
    select(has("existingSecretKey") or has("key")) |
    (.existingSecret + ":::" + (.existingSecretKey // .key // ""))] |
    unique | .[]
  ' "$file" 2>/dev/null) || true

  [[ -z "$refs" ]] && continue

  while IFS= read -r ref; do
    [[ -z "$ref" || "$ref" == "null" ]] && continue
    secret_name="${ref%%:::*}"
    key_name="${ref##*:::}"
    [[ -z "$key_name" || -z "$secret_name" ]] && continue

    found_refs=true

    # Look up the secret by name
    if [[ -n "${SECRET_BY_NAME[$secret_name]:-}" ]]; then
      provided_keys="${SECRET_BY_NAME[$secret_name]}"
      # Check if the key exists (exact match in comma-separated list)
      if echo ",$provided_keys," | grep -qF ",$key_name,"; then
        echo -e "${GREEN}✓${NC} ${hr_name}: existingSecret '${secret_name}' has key '${key_name}'"
      else
        echo -e "${RED}✗${NC} ${hr_name}: existingSecret '${secret_name}' is missing key '${key_name}'"
        echo "   Provided keys: ${provided_keys}"
        echo "   File: ${file#"$REPO_ROOT/"}"
        ((ERRORS++)) || true
      fi
    else
      echo -e "${YELLOW}⚠${NC}  ${hr_name}: references secret '${secret_name}' but no ExternalSecret found for it"
      echo "   Key expected: ${key_name}"
      echo "   File: ${file#"$REPO_ROOT/"}"
      ((WARNINGS++)) || true
    fi
  done <<< "$refs"

done < <(find "$KUBERNETES_DIR/apps" -name "helmrelease.yaml" -print0)

if ! $found_refs; then
  echo "  (no explicit existingSecret+key references found — chart-internal secret usage)"
fi

echo ""

# --- Summary: all known secrets and their keys ---
echo "--- Known secrets and provided keys ---"
# Use ${!SECRET_KEYS[@]} with quoted for to handle spaces in paths
for map_key in "${!SECRET_KEYS[@]}"; do
  secret_name="${map_key##*::}"
  app_path="${map_key%%::*}"
  rel_path="${app_path#"$REPO_ROOT/"}"
  echo "  [${rel_path}] ${secret_name}: ${SECRET_KEYS[$map_key]}"
done | sort
echo ""

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}❌ Secret key validation failed: ${ERRORS} error(s), ${WARNINGS} warning(s)${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Secret key validation passed${NC} (${WARNINGS} warning(s))"
fi
