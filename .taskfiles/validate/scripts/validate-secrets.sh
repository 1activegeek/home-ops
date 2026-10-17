#!/usr/bin/env bash
# Validates that 1Password items contain all fields referenced in ExternalSecret templates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

echo "=== Validating 1Password fields against ExternalSecret templates ==="
echo ""

# Find all externalsecret.yaml files
while IFS= read -r -d '' file; do
  # Each file may have multiple ExternalSecret documents
  doc_count=$(yq eval-all '[select(.kind == "ExternalSecret")] | length' "$file" 2>/dev/null || echo 0)

  for ((i = 0; i < doc_count; i++)); do
    es_name=$(yq eval-all "select(.kind == \"ExternalSecret\") | select(document_index == $i) | .metadata.name" "$file" 2>/dev/null | head -1)
    [[ -z "$es_name" || "$es_name" == "null" ]] && continue

    es_doc="select(.kind == \"ExternalSecret\") | select(document_index == $i)"

    # 1Password items merged in whole via dataFrom[].extract.key (may be several)
    item_keys=$(yq eval-all "${es_doc} | .spec.dataFrom[].extract.key" "$file" 2>/dev/null | grep -v '^null$' || true)
    if [[ -z "$item_keys" ]]; then
      echo -e "${YELLOW}⚠${NC}  ${es_name}: no dataFrom.extract.key found (may use data[] instead — skipping)"
      ((WARNINGS++)) || true
      continue
    fi
    item_key=$(echo "$item_keys" | paste -sd, -)

    # Get template.data values and extract .field_name references
    template_data=$(yq eval-all "${es_doc} | .spec.target.template.data" "$file" 2>/dev/null)
    if [[ -z "$template_data" || "$template_data" == "null" ]]; then
      echo -e "${YELLOW}⚠${NC}  ${es_name}: no template.data found — skipping"
      ((WARNINGS++)) || true
      continue
    fi

    # Extract field references: {{ .field_name }} patterns in a way that works on macOS/BSD tools too.
    # Lowercased to match op_fields below (1Password labels are compared case-insensitively).
    referenced_fields=$(echo "$template_data" | perl -nle 'while(/\{\{\s*\.([a-zA-Z0-9_]+)/g){print lc $1}' | sort -u)
    if [[ -z "$referenced_fields" ]]; then
      echo -e "${YELLOW}⚠${NC}  ${es_name}: no {{ .field }} references found in template.data — skipping"
      ((WARNINGS++)) || true
      continue
    fi

    # Collect available field labels (lowercase) from every extracted item
    op_fields=""
    item_missing=0
    while IFS= read -r key; do
      item_json=$(op item get "$key" --vault homeops --format json 2>/dev/null) || {
        echo -e "${RED}✗${NC} ${es_name}: 1Password item '${key}' not found in vault 'homeops'"
        echo "   File: ${file#"$REPO_ROOT/"}"
        item_missing=1
        continue
      }
      op_fields+=$(echo "$item_json" | jq -r '.fields[]? | select(.purpose != "PASSWORD" or .label != "") | .label // .id' | tr '[:upper:]' '[:lower:]')$'\n'
    done <<< "$item_keys"
    if [[ $item_missing -eq 1 ]]; then
      ((ERRORS++)) || true
      continue
    fi

    # data[] entries: each remoteRef key/property must exist; its secretKey then
    # becomes available to the template like an extracted field.
    data_count=$(yq eval-all "${es_doc} | .spec.data | length" "$file" 2>/dev/null | head -1)
    for ((d = 0; d < ${data_count:-0}; d++)); do
      ref=$(yq eval-all "${es_doc} | .spec.data[$d] | [.secretKey, .remoteRef.key, .remoteRef.property] | join(\"|\")" "$file" 2>/dev/null | head -1)
      IFS='|' read -r secret_key ref_key ref_prop <<< "$ref"
      if [[ -n "$ref_prop" ]] && ! op item get "$ref_key" --vault homeops --format json 2>/dev/null \
          | jq -e --arg p "$ref_prop" '.fields[]? | select((.label // "" | ascii_downcase) == ($p | ascii_downcase))' >/dev/null; then
        echo -e "${RED}✗${NC} ${es_name}: data[] remoteRef '${ref_key}' has no field '${ref_prop}'"
        echo "   File: ${file#"$REPO_ROOT/"}"
        item_missing=1
        continue
      fi
      op_fields+=$(echo "$secret_key" | tr '[:upper:]' '[:lower:]')$'\n'
    done
    if [[ $item_missing -eq 1 ]]; then
      ((ERRORS++)) || true
      continue
    fi
    op_fields=$(echo "$op_fields" | sed '/^$/d' | sort -u)

    # Compare
    missing_fields=()
    while IFS= read -r field; do
      [[ -z "$field" ]] && continue
      # op field labels use hyphens but our template refs use underscores — normalize both
      field_normalized="${field//_/-}"
      if ! echo "$op_fields" | grep -qx "$field" && ! echo "$op_fields" | grep -qx "$field_normalized"; then
        missing_fields+=("$field")
      fi
    done <<< "$referenced_fields"

    if [[ ${#missing_fields[@]} -eq 0 ]]; then
      field_count=$(echo "$referenced_fields" | wc -l | tr -d ' ')
      echo -e "${GREEN}✓${NC} ${es_name} (item: ${item_key}): all ${field_count} field(s) matched"
    else
      echo -e "${RED}✗${NC} ${es_name} (item: ${item_key}): missing field(s) in 1Password:"
      for f in "${missing_fields[@]}"; do
        echo "     missing: ${f}"
      done
      echo "   Available fields: $(echo "$op_fields" | tr '\n' ', ' | sed 's/,$//')"
      echo "   File: ${file#"$REPO_ROOT/"}"
      ((ERRORS++)) || true
    fi
  done

done < <(find "$KUBERNETES_DIR/apps" -name "externalsecret.yaml" -print0)

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}❌ Secret validation failed: ${ERRORS} error(s), ${WARNINGS} warning(s)${NC}"
  exit 1
else
  echo -e "${GREEN}✅ Secret validation passed${NC} (${WARNINGS} warning(s))"
fi
