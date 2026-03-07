#!/usr/bin/env bash
# Flags container images running as UID 65534 (our default) that may need a
# different UID. Images from known-safe image sets (e.g., home-operations/*)
# are designed for UID 65534. Unknown images get a warning to verify.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBERNETES_DIR="${REPO_ROOT}/kubernetes"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WARNINGS=0

echo "=== Checking security context UID compatibility ==="
echo ""

# Images known to support running as UID 65534 (nonroot)
# Extend this list as you verify images work with UID 65534
SAFE_REGISTRIES=(
  "ghcr.io/home-operations/"
  "ghcr.io/bjw-s"
)

SAFE_IMAGE_PATTERNS=(
  "home-operations/"
  "bjw-s-labs/"
)

# Images known to require a specific non-65534 UID (add as discovered)
# Format: "image_pattern:required_uid"
KNOWN_UID_REQUIREMENTS=(
  "home-assistant/home-assistant:0"
  "metube:1000"
  "qdm12/gluetun:0"
)

is_safe_for_65534() {
  local repo="$1"
  for pattern in "${SAFE_REGISTRIES[@]}" "${SAFE_IMAGE_PATTERNS[@]}"; do
    [[ "$repo" == *"$pattern"* ]] && return 0
  done
  return 1
}

get_known_uid() {
  local repo="$1"
  for req in "${KNOWN_UID_REQUIREMENTS[@]}"; do
    local pattern="${req%%:*}"
    local uid="${req##*:}"
    [[ "$repo" == *"$pattern"* ]] && echo "$uid" && return
  done
  echo ""
}

while IFS= read -r -d '' file; do
  rel_file="${file#"$REPO_ROOT/"}"
  hr_name=$(yq eval '.metadata.name // ""' "$file" 2>/dev/null | head -1)
  [[ -z "$hr_name" || "$hr_name" == "null" ]] && continue

  # Get the pod-level runAsUser
  pod_run_as_user=$(yq eval '.spec.values.defaultPodOptions.securityContext.runAsUser // ""' "$file" 2>/dev/null | head -1)

  # Get container-level images and their securityContext.runAsUser
  while IFS='|' read -r controller_name container_name repo tag container_uid; do
    [[ -z "$repo" || "$repo" == "null" ]] && continue

    # Determine effective UID
    effective_uid="${container_uid:-$pod_run_as_user}"
    [[ -z "$effective_uid" || "$effective_uid" == "null" ]] && continue

    # Skip template variables
    [[ "$repo" == *'${'* ]] && continue

    known_uid=$(get_known_uid "$repo")

    if [[ "$effective_uid" == "65534" ]]; then
      if is_safe_for_65534 "$repo"; then
        echo -e "${GREEN}✓${NC} ${hr_name}/${container_name}: ${repo}:${tag} — UID 65534 (known-safe image)"
      elif [[ -n "$known_uid" && "$known_uid" != "65534" ]]; then
        echo -e "${YELLOW}⚠${NC}  ${hr_name}/${container_name}: ${repo}:${tag}"
        echo "     Running as UID 65534 but this image typically requires UID ${known_uid}"
        echo "     File: ${rel_file}"
        ((WARNINGS++)) || true
      else
        echo -e "${YELLOW}⚠${NC}  ${hr_name}/${container_name}: ${repo}:${tag}"
        echo "     Running as UID 65534 — verify this image supports nonroot execution"
        echo "     If it fails with permission errors, set runAsUser to the image's expected UID"
        echo "     File: ${rel_file}"
        ((WARNINGS++)) || true
      fi
    elif [[ -n "$known_uid" && "$effective_uid" != "$known_uid" ]]; then
      echo -e "${YELLOW}⚠${NC}  ${hr_name}/${container_name}: ${repo}:${tag}"
      echo "     Running as UID ${effective_uid} but this image typically requires UID ${known_uid}"
      echo "     File: ${rel_file}"
      ((WARNINGS++)) || true
    else
      echo -e "${GREEN}✓${NC} ${hr_name}/${container_name}: ${repo}:${tag} — UID ${effective_uid}"
    fi

  done < <(yq eval '
    .spec.values.controllers | to_entries | .[] |
    .key as $ctrl |
    .value.containers | to_entries | .[] |
    .key as $ctr |
    .value |
    select(has("image")) |
    ($ctrl + "|" + $ctr + "|" + .image.repository + "|" + (.image.tag | tostring) + "|" + (.securityContext.runAsUser // "" | tostring))
  ' "$file" 2>/dev/null | grep -v "^null\|^|||")

done < <(find "$KUBERNETES_DIR/apps" -name "helmrelease.yaml" -print0)

echo ""
if [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}⚠  Security context check: ${WARNINGS} warning(s) — review images above${NC}"
  echo ""
  echo "To add an image to the known-safe list, edit SAFE_IMAGE_PATTERNS in this script."
  echo "To document a known UID requirement, add to KNOWN_UID_REQUIREMENTS."
else
  echo -e "${GREEN}✅ Security context check passed${NC}"
fi
# Always exit 0 — this is advisory only
exit 0
