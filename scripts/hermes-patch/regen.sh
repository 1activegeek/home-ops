#!/usr/bin/env bash
# Forward-port the carried hermes-agent patch onto a newer image tag.
#
#   scripts/hermes-patch/regen.sh <old-tag> <new-tag>
#   scripts/hermes-patch/regen.sh v2026.9.11 v2026.10.02
#
# <old-tag> is the tag the CURRENT diff applies to (what helmrelease.yaml pinned
# before the bump); <new-tag> is the candidate. Does the mechanical part of the
# port with a real 3-way merge:
#
#   base   = touched files at <old-tag>
#   ours   = base + the current diff
#   theirs = the same files at <new-tag>
#   result = theirs + our changes, merged
#
# Writes the regenerated diff to patches/27183-per-user-usermd.diff when the
# merge is clean, or leaves conflict markers in the work dir and tells you where
# when it is not. Either way, ALWAYS finish by running verify.sh — a clean merge
# is not proof the patch still means the same thing after an upstream refactor.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="$REPO_ROOT/kubernetes/apps/ai/hermes-agent/app"
DIFF="$APP_DIR/patches/27183-per-user-usermd.diff"
IMAGE_REPO="docker.io/nousresearch/hermes-agent"

emit() { # emit <work-dir> — diff merged/ against theirs/ into the patch file
  local work="$1"
  [[ -d "$work/theirs" && -d "$work/merged" ]] || { echo "$work is not a regen work dir"; exit 2; }
  : > "$work/out.diff"
  local f
  while IFS= read -r f; do
    if grep -q '^<<<<<<< ' "$work/merged/$f"; then
      echo "!! $f still has conflict markers — resolve them first"; exit 1
    fi
    diff -u "$work/theirs/$f" "$work/merged/$f" \
      | sed -e "1s|^--- .*|--- a/$f|" -e "2s|^+++ .*|+++ b/$f|" \
      | sed "1i\\
diff --git a/$f b/$f" >> "$work/out.diff" || true
  done < <(sed -n 's|^diff --git a/\(.*\) b/.*|\1|p' "$DIFF")
  cp "$work/out.diff" "$DIFF"
  echo "==> wrote $DIFF — now run scripts/hermes-patch/verify.sh"
}

if [[ "${1:-}" == "--emit" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: regen.sh --emit <work-dir>"; exit 2; }
  emit "$2"; exit 0
fi

OLD_TAG="${1:-}"; NEW_TAG="${2:-}"
[[ -n "$OLD_TAG" && -n "$NEW_TAG" ]] || { sed -n '2,20p' "$0"; exit 2; }

command -v docker >/dev/null || { echo "regen.sh needs docker"; exit 2; }

WORK="$(mktemp -d -t hermes-regen)"
echo "==> work dir: $WORK"

# Files the current diff touches.
FILES=()
while IFS= read -r _f; do FILES+=("$_f"); done \
  < <(sed -n 's|^diff --git a/\(.*\) b/.*|\1|p' "$DIFF")
echo "==> patch touches ${#FILES[@]} file(s): ${FILES[*]}"

extract() { # extract <tag> <dest>
  local tag="$1" dest="$2"
  mkdir -p "$dest"
  docker run --rm --entrypoint sh "$IMAGE_REPO:$tag" \
    -c "cd /opt/hermes && tar cf - $(printf '%s ' "${FILES[@]}") 2>/dev/null" | tar xf - -C "$dest"
}

echo "==> extracting $OLD_TAG (base)"
extract "$OLD_TAG" "$WORK/base"
echo "==> extracting $NEW_TAG (theirs)"
extract "$NEW_TAG" "$WORK/theirs"

MISSING=0
for f in "${FILES[@]}"; do
  [[ -f "$WORK/theirs/$f" ]] || { echo "!! $f no longer exists in $NEW_TAG"; MISSING=1; }
done
if [[ $MISSING -eq 1 ]]; then
  cat <<MSG

!! Upstream moved or deleted a file the patch targets. That is a refactor, not a
!! drift — a 3-way merge cannot find the new home for this code. Port it by hand:
!!   1. find where the code went  (grep the new image for MemoryStore / load_on_disk_store)
!!   2. edit $WORK/theirs/<file> into the shape you want
!!   3. diff -u it back against a pristine copy and update $DIFF
!!   4. run verify.sh
!! Sources are extracted under $WORK for you.
MSG
  exit 1
fi

echo "==> applying the current patch to the base (ours)"
cp -R "$WORK/base" "$WORK/ours"
(cd "$WORK/ours" && git apply -v --ignore-whitespace --recount "$DIFF")

echo "==> 3-way merging our changes onto $NEW_TAG"
cp -R "$WORK/theirs" "$WORK/merged"
CONFLICTS=0
for f in "${FILES[@]}"; do
  if git merge-file -L "$NEW_TAG" -L "$OLD_TAG (base)" -L "ours" \
       "$WORK/merged/$f" "$WORK/base/$f" "$WORK/ours/$f"; then
    echo "   ok        $f"
  else
    echo "   CONFLICT  $f"
    CONFLICTS=1
  fi
done

if [[ $CONFLICTS -eq 1 ]]; then
  cat <<MSG

!! Conflicts left in $WORK/merged — resolve the markers there, then:
!!   scripts/hermes-patch/regen.sh --emit $WORK   # (or diff -u by hand)
!! and finish with verify.sh.
MSG
  exit 1
fi

echo "==> emitting the regenerated diff"
: > "$WORK/out.diff"
for f in "${FILES[@]}"; do
  diff -u "$WORK/theirs/$f" "$WORK/merged/$f" \
    | sed -e "1s|^--- .*|--- a/$f|" -e "2s|^+++ .*|+++ b/$f|" \
    | sed "1i\\
diff --git a/$f b/$f" >> "$WORK/out.diff" || true
done
cp "$WORK/out.diff" "$DIFF"
echo "==> wrote $DIFF"

cat <<MSG

Next:
  1. bump the tag in helmrelease.yaml to $NEW_TAG
  2. scripts/hermes-patch/verify.sh          # MUST pass before merging
  3. read the diff — a clean 3-way merge can still land our code in a spot where
     upstream changed what it means
MSG
