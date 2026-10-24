#!/usr/bin/env bash
# Fails when an image reference uses a floating tag that Renovate cannot track
# and that silently changes underneath the cluster:
#   - no tag at all (implicit `latest`) and no digest
#   - channel tags with no version number: latest, main, master, stable, edge,
#     alpine, slim, ...
#   - bare major tags: "18", "18-alpine", "v2"
#
# Scans both image forms used in this repo:
#   image: repo:tag                      (plain manifests, CronJobs, ...)
#   image: { repository: repo, tag: x }  (Helm values, bjw-s app-template)
#
# Justified exceptions go in tags-allowlist.txt next to this script, one
# `repository:tag` per line with a `# reason` comment.
#
# Needs bash and mikefarah yq v4 (preinstalled on GitHub's ubuntu-latest).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ALLOWLIST="$(dirname "${BASH_SOURCE[0]}")/tags-allowlist.txt"
SCAN_DIRS=("${REPO_ROOT}/kubernetes" "${REPO_ROOT}/bootstrap")

command -v yq >/dev/null || { echo "yq (mikefarah v4) is required" >&2; exit 1; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
CHECKED=0
ALLOWED=0

declare -A ALLOW=()
if [[ -f "$ALLOWLIST" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && ALLOW["$line"]=1
  done < "$ALLOWLIST"
fi

echo "=== Checking image references for floating tags ==="
echo ""

# Prints a reason when the tag is floating, nothing when it is pinned.
floating_reason() {
  local tag="$1" digest="$2"
  if [[ -z "$tag" ]]; then
    [[ -n "$digest" ]] && return
    echo "no tag (implicit latest)"
    return
  fi
  if [[ ! "$tag" =~ [0-9] ]]; then
    echo "channel tag with no version"
    return
  fi
  if [[ "$tag" =~ ^v?[0-9]+([-_][A-Za-z][A-Za-z0-9._-]*)?$ ]]; then
    echo "bare major tag"
    return
  fi
}

check_ref() {
  local file="$1" line="$2" repo="$3" tag="$4" digest="$5"

  # Flux postBuild / Helm template values are resolved elsewhere.
  if [[ "$repo$tag$digest" == *'${'* || "$repo$tag$digest" == *'{{'* ]]; then
    return
  fi

  ((CHECKED++)) || true
  local reason
  reason="$(floating_reason "$tag" "$digest")"
  [[ -z "$reason" ]] && return

  local key="${repo}:${tag}"
  if [[ -n "${ALLOW[$key]:-}" ]]; then
    echo -e "${YELLOW}~${NC} ${key} — allowlisted (${file#"$REPO_ROOT/"}:${line})"
    ((ALLOWED++)) || true
    return
  fi

  echo -e "${RED}✗${NC} ${repo}${tag:+:$tag}${digest:+@$digest} — ${reason}"
  echo "   File: ${file#"$REPO_ROOT/"}:${line}"
  ((ERRORS++)) || true
}

# Splits `repo[:tag][@digest]` without mistaking a registry port for a tag.
split_ref() {
  local ref="$1" name digest="" tag=""
  if [[ "$ref" == *@* ]]; then
    digest="${ref#*@}"
    ref="${ref%%@*}"
  fi
  name="$ref"
  local last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    tag="${last##*:}"
    name="${ref%:*}"
  fi
  printf '%s\t%s\t%s\n' "$name" "$tag" "$digest"
}

while IFS= read -r -d '' file; do
  # Plain string form: image: repo:tag
  while IFS=$'\t' read -r line ref; do
    [[ -z "$ref" ]] && continue
    IFS=$'\t' read -r repo tag digest < <(split_ref "$ref")
    check_ref "$file" "$line" "$repo" "$tag" "$digest"
  done < <(yq eval-all -N '
      .. | select(tag == "!!map") | select(has("image")) | .image
      | select(tag == "!!str")
      | (line | tostring) + "\t" + .
    ' "$file" 2>/dev/null || true)

  # Map form: { repository: repo, tag: x [, digest: sha] }
  while IFS=$'\t' read -r line repo tag digest; do
    [[ -z "$repo" ]] && continue
    [[ "$tag" == "null" ]] && tag=""
    [[ "$digest" == "null" ]] && digest=""
    check_ref "$file" "$line" "$repo" "$tag" "$digest"
  done < <(yq eval-all -N '
      .. | select(tag == "!!map")
      | select(has("repository") and (has("tag") or has("digest")))
      | select(.repository | tag == "!!str")
      | (.repository | line | tostring) + "\t" + .repository + "\t"
        + ((.tag // "null") | tostring) + "\t" + ((.digest // "null") | tostring)
    ' "$file" 2>/dev/null || true)
done < <(find "${SCAN_DIRS[@]}" -type f \( -name '*.yaml' -o -name '*.yml' \) \
  ! -name '*.sops.yaml' -print0 2>/dev/null)

echo ""
echo "Checked ${CHECKED} image reference(s), ${ALLOWED} allowlisted"

# yq errors are swallowed per file above, so a broken yq would otherwise pass
# with nothing checked.
if [[ $CHECKED -eq 0 ]]; then
  echo -e "${RED}❌ No image references found — is mikefarah yq v4 installed?${NC}"
  exit 1
fi

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}❌ ${ERRORS} floating image tag(s). Pin an exact version (see AGENTS.md 'Never Use latest Image Tags').${NC}"
  exit 1
fi
echo -e "${GREEN}✅ No floating image tags${NC}"
