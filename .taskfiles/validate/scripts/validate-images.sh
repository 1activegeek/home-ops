#!/usr/bin/env bash
# Validates that container image tags referenced in helmrelease.yaml files
# exist in their respective container registries.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0
CHECKED=0

# Tags that are mutable/semantic — skip existence check, just warn
MUTABLE_TAGS=("latest" "stable" "main" "master" "edge" "develop" "nightly" "rolling" "release")

echo "=== Validating container image tags ==="
echo ""

# Check if a tag is mutable
is_mutable_tag() {
  local tag="$1"
  for mutable in "${MUTABLE_TAGS[@]}"; do
    [[ "$tag" == "$mutable" ]] && return 0
  done
  return 1
}

# Get a GHCR anonymous auth token for a given image path
ghcr_token() {
  local image_path="$1"
  curl -sf "https://ghcr.io/token?scope=repository:${image_path}:pull" \
    | jq -r '.token // empty' 2>/dev/null
}

# Check if a ghcr.io image:tag exists
check_ghcr() {
  local repo="$1"  # e.g. home-operations/plex
  local tag="$2"
  local token
  token=$(ghcr_token "$repo")
  if [[ -z "$token" ]]; then
    echo "no-token"
    return
  fi
  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" 2>/dev/null)
  echo "$status"
}

# Check if a docker.io image:tag exists (using Docker Hub API)
check_dockerhub() {
  local repo="$1"  # e.g. library/nginx or myorg/myapp
  local tag="$2"
  # Add library/ prefix for official images
  [[ "$repo" != */* ]] && repo="library/${repo}"
  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" \
    "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}" 2>/dev/null)
  echo "$status"
}

# Check if a quay.io image:tag exists
check_quay() {
  local repo="$1"
  local tag="$2"
  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" \
    "https://quay.io/api/v1/repository/${repo}/tag/?specificTag=${tag}&limit=1" 2>/dev/null)
  echo "$status"
}

check_image() {
  local repository="$1"
  local tag="$2"
  local source_file="$3"

  # Skip template variables
  if [[ "$repository" == *'${'* || "$tag" == *'${'* ]]; then
    return
  fi

  # Check for mutable tags
  if is_mutable_tag "$tag"; then
    echo -e "${YELLOW}⚠${NC}  ${repository}:${tag} — mutable tag, skipping existence check"
    echo "   File: ${source_file#"$REPO_ROOT/"}"
    ((WARNINGS++)) || true
    return
  fi

  ((CHECKED++)) || true

  # Route to the right registry checker
  if [[ "$repository" == ghcr.io/* ]]; then
    local image_path="${repository#ghcr.io/}"
    local status
    status=$(check_ghcr "$image_path" "$tag")
    if [[ "$status" == "200" ]]; then
      echo -e "${GREEN}✓${NC} ghcr.io/${image_path}:${tag}"
    elif [[ "$status" == "no-token" ]]; then
      echo -e "${YELLOW}⚠${NC}  ghcr.io/${image_path}:${tag} — could not obtain auth token (skipping)"
      ((WARNINGS++)) || true
    else
      echo -e "${RED}✗${NC} ghcr.io/${image_path}:${tag} — NOT FOUND (HTTP ${status})"
      echo "   File: ${source_file#"$REPO_ROOT/"}"
      ((ERRORS++)) || true
    fi

  elif [[ "$repository" == docker.io/* || "$repository" != */* || "$repository" == *docker* ]]; then
    local image_path="${repository#docker.io/}"
    local status
    status=$(check_dockerhub "$image_path" "$tag")
    if [[ "$status" == "200" ]]; then
      echo -e "${GREEN}✓${NC} docker.io/${image_path}:${tag}"
    else
      echo -e "${RED}✗${NC} docker.io/${image_path}:${tag} — NOT FOUND (HTTP ${status})"
      echo "   File: ${source_file#"$REPO_ROOT/"}"
      ((ERRORS++)) || true
    fi

  elif [[ "$repository" == quay.io/* ]]; then
    local image_path="${repository#quay.io/}"
    local status
    status=$(check_quay "$image_path" "$tag")
    if [[ "$status" == "200" ]]; then
      echo -e "${GREEN}✓${NC} quay.io/${image_path}:${tag}"
    else
      echo -e "${RED}✗${NC} quay.io/${image_path}:${tag} — NOT FOUND (HTTP ${status})"
      echo "   File: ${source_file#"$REPO_ROOT/"}"
      ((ERRORS++)) || true
    fi

  else
    echo -e "${YELLOW}⚠${NC}  ${repository}:${tag} — unsupported registry, skipping"
    ((WARNINGS++)) || true
  fi
}

# Extract image repository+tag pairs from helmrelease.yaml files
while IFS= read -r -d '' file; do
  # Extract all image repository/tag pairs using yq
  # This handles the nested bjw-s app-template structure
  while IFS='|' read -r repo tag; do
    [[ -z "$repo" || "$repo" == "null" || -z "$tag" || "$tag" == "null" ]] && continue
    check_image "$repo" "$tag" "$file"
  done < <(yq eval '
    [
      .. | select(has("image")) |
      select(.image | has("repository")) |
      select(.image | has("tag")) |
      (.image.repository + "|" + (.image.tag | tostring))
    ] | unique | .[]
  ' "$file" 2>/dev/null | grep -v "^null$")
done < <(find "$KUBERNETES_DIR/apps" -name "helmrelease.yaml" -print0)

echo ""
echo "Checked ${CHECKED} image tag(s)"

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}❌ Image validation failed: ${ERRORS} invalid tag(s), ${WARNINGS} warning(s)${NC}"
  exit 1
elif [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}⚠  Image validation: ${WARNINGS} warning(s) (mutable/unknown-registry tags)${NC}"
else
  echo -e "${GREEN}✅ All image tags validated successfully${NC}"
fi
