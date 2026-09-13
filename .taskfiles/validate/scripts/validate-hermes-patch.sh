#!/usr/bin/env bash
# Thin wrapper kept for `task validate:hermes-patch` (and validate:all /
# validate:preflight, which depend on it).
#
# The real implementation is scripts/hermes-patch/verify.sh — one script, shared
# with .github/workflows/hermes-patch.yaml, so the local task and the CI gate can
# never check different things. It picks the docker backend when a daemon is
# available and the cluster backend otherwise, and self-skips green when the
# carried patch is gone (expected once upstream #27183 lands).
#
# See docs/hermes-memory-patch.md.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec "${REPO_ROOT}/scripts/hermes-patch/verify.sh" "$@"
