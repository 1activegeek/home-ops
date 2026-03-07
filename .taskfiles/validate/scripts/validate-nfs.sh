#!/usr/bin/env bash
# Validates that NFS exports referenced in helmrelease.yaml persistence sections
# are actually exported from the NFS server.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"
SOPS_FILE="${KUBERNETES_DIR}/components/sops/cluster-secrets.sops.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0
CHECKED=0

echo "=== Validating NFS exports ==="
echo ""

# Try to resolve NFS_SERVER from cluster-secrets (plaintext key names, encrypted values)
# We can't decrypt without the age key, so we resolve the actual server IP differently.
# Check environment first, then try sops decrypt if age key is present.
NFS_SERVER_IP="${NFS_SERVER:-}"

if [[ -z "$NFS_SERVER_IP" ]]; then
  if [[ -f "${REPO_ROOT}/age.key" ]]; then
    NFS_SERVER_IP=$(SOPS_AGE_KEY_FILE="${REPO_ROOT}/age.key" sops -d "$SOPS_FILE" 2>/dev/null | \
      yq eval '.stringData.NFS_SERVER' - 2>/dev/null || true)
  fi
fi

if [[ -z "$NFS_SERVER_IP" || "$NFS_SERVER_IP" == "null" ]]; then
  echo -e "${YELLOW}⚠${NC}  Could not resolve NFS_SERVER IP."
  echo "   Set NFS_SERVER env var or ensure age.key is present for SOPS decryption."
  echo "   Skipping NFS validation."
  exit 0
fi

echo "NFS server: ${NFS_SERVER_IP}"
echo ""

# Get the list of exports from the NFS server
NFS_EXPORTS=$(showmount -e "$NFS_SERVER_IP" --no-headers 2>/dev/null | awk '{print $1}' | sort)
if [[ -z "$NFS_EXPORTS" ]]; then
  echo -e "${YELLOW}⚠${NC}  Could not retrieve NFS exports from ${NFS_SERVER_IP}"
  echo "   Ensure showmount is available and the NFS server is reachable."
  exit 0
fi

echo "Available exports:"
while IFS= read -r export; do
  echo "  ${export}"
done <<< "$NFS_EXPORTS"
echo ""

# Extract NFS server+path pairs from helmrelease.yaml files
declare -A CHECKED_PATHS

while IFS= read -r -d '' file; do
  rel_file="${file#"$REPO_ROOT/"}"

  # Extract all NFS persistence blocks
  while IFS='|' read -r server path; do
    [[ -z "$server" || "$server" == "null" || -z "$path" || "$path" == "null" ]] && continue

    # Resolve ${NFS_SERVER} template variable
    resolved_server="${server/\$\{NFS_SERVER\}/$NFS_SERVER_IP}"
    resolved_server="${resolved_server//\$\{NFS_SERVER\}/$NFS_SERVER_IP}"

    path_key="${resolved_server}:${path}"
    [[ -n "${CHECKED_PATHS[$path_key]:-}" ]] && continue
    CHECKED_PATHS["$path_key"]=1
    ((CHECKED++)) || true

    if echo "$NFS_EXPORTS" | grep -qx "$path"; then
      echo -e "${GREEN}✓${NC} ${resolved_server}:${path} — exported and accessible"
    else
      echo -e "${RED}✗${NC} ${resolved_server}:${path} — NOT exported"
      echo "   File: ${rel_file}"
      ((ERRORS++)) || true
    fi

  done < <(yq eval '
    .spec.values.persistence | to_entries | .[] |
    select(.value.type == "nfs") |
    (.value.server + "|" + .value.path)
  ' "$file" 2>/dev/null | grep -v "^null$\|^|$" || true)

done < <(find "$KUBERNETES_DIR/apps" -name "helmrelease.yaml" -print0)

echo ""
echo "Checked ${CHECKED} NFS path(s)"

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}❌ NFS validation failed: ${ERRORS} path(s) not exported${NC}"
  exit 1
else
  echo -e "${GREEN}✅ All NFS paths are exported and accessible${NC}"
fi
