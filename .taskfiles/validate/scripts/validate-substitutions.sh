#!/usr/bin/env bash
# Detects Flux variable substitution collisions.
#
# Flux's postBuild.substituteFrom rewrites ${VAR} in every rendered manifest of a
# Kustomization. A var that none of the referenced Secrets provides is replaced with
# an EMPTY STRING, silently, at apply time — flux-local CI builds fine and the job
# fails at runtime. App-level variables that must survive are escaped $${VAR}.
#
# Three things this script has to get right, each of which it previously got wrong:
#
#   1. PCRE availability. It used `grep -oP`, which BSD grep (macOS) does not
#      support. The failure was swallowed by `2>/dev/null ... || true`, so every
#      file matched nothing and the script reported a clean pass over the whole
#      repo. The guard-rail silently did nothing on every developer Mac.
#
#   2. Which Kustomization owns a file. Substitution only happens if the owning
#      Flux Kustomization declares postBuild.substituteFrom. Where it does not,
#      ${VAR} passes through untouched and escaping it as $${VAR} is actively
#      WRONG — the shell sees a literal $${VAR} with $$ expanding to the PID.
#      Ownership cannot be inferred by walking up to the nearest ks.yaml: 16 of
#      this repo's 104 Flux Kustomizations are not named ks.yaml, and some ks.yaml
#      files scope `spec.path` to a subdirectory that excludes their siblings
#      (teslamate/ks.yaml covers only app/, while grafana/ belongs to
#      grafana-ks.yaml). Ownership is resolved here by longest `spec.path` prefix.
#
#   3. Sources beyond cluster-secrets. A Kustomization may substitute from several
#      Secrets — teslamate's grafana-ks.yaml adds teslamate-grafana-vars, which is
#      where TESLAMATE_DB_PASSWORD legitimately comes from. Those Secrets are
#      ExternalSecret-provided and their keys are not knowable from git, so files
#      owned by such a Kustomization are reported as INFO, not ERROR.
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
SKIPPED=0
UNVERIFIABLE=0

echo "=== Detecting Flux \${VAR} substitution collisions ==="
echo ""

# ---------------------------------------------------------------- PCRE matcher
# Fail loudly rather than pass vacuously if no engine is available.
if echo 'x${A}' | grep -qoP '(?<!\$)\$\{[A-Z0-9_]+\}' 2>/dev/null; then
  pcre_matches() { grep -oP '(?<!\$)\$\{[A-Z0-9_]+\}' "$1" 2>/dev/null | sort -u; }
  MATCHER="grep -P"
elif command -v ggrep >/dev/null 2>&1 && echo 'x${A}' | ggrep -qoP '(?<!\$)\$\{[A-Z0-9_]+\}' 2>/dev/null; then
  pcre_matches() { ggrep -oP '(?<!\$)\$\{[A-Z0-9_]+\}' "$1" 2>/dev/null | sort -u; }
  MATCHER="ggrep -P"
elif command -v perl >/dev/null 2>&1; then
  pcre_matches() { perl -ne 'print "$1\n" while /(?<!\$)(\$\{[A-Z0-9_]+\})/g' "$1" 2>/dev/null | sort -u; }
  MATCHER="perl"
else
  echo -e "${RED}✗${NC} No PCRE-capable matcher found (need GNU grep -P, ggrep, or perl)."
  echo "   Refusing to report a pass that was never actually checked."
  exit 1
fi
echo "Matcher: ${MATCHER}"

# Same pattern, but only over lines that are not pure YAML comments. A ${VAR} inside
# a comment is documentation, not something Flux will strip — several files in this
# repo comment about escaping and were false-positived by the old scan.
pcre_matches_noncomment() {
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null > "$TMPD/noncomment.yaml" || true
  pcre_matches "$TMPD/noncomment.yaml"
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# ------------------------------------------------------- known cluster-secrets
KNOWN_VARS=()
if [[ -f "$SOPS_FILE" ]]; then
  while IFS= read -r var; do
    [[ -n "$var" ]] && KNOWN_VARS+=("$var")
  done < <(yq eval '.stringData | keys | .[]' "$SOPS_FILE" 2>/dev/null)
fi

if [[ ${#KNOWN_VARS[@]} -eq 0 ]]; then
  echo -e "${YELLOW}⚠${NC}  Could not read cluster-secrets variable names from ${SOPS_FILE}"
  echo "   Falling back to the known set."
  KNOWN_VARS=(
    SECRET_DOMAIN CLUSTER_DOMAIN CLUSTER_VIP
    CLUSTER_NODE_1_IP CLUSTER_NODE_2_IP CLUSTER_NODE_3_IP
    CLUSTER_LB_IP CLUSTER_DNS_IP CLUSTER_POD_CIDR CLUSTER_SVC_CIDR
    NFS_SERVER
  )
fi

declare -A KNOWN_SET
for v in "${KNOWN_VARS[@]}"; do KNOWN_SET["$v"]=1; done
echo "Known cluster-secrets variables: ${KNOWN_VARS[*]}"
echo ""

# --------------------------------------------- index Flux Kustomizations by path
# KS_MODE[path] = none | cluster-secrets | extra
declare -A KS_MODE
ks_count=0
while IFS= read -r -d '' ksfile; do
  # A file may hold several documents; handle each Kustomization in it.
  while IFS=$'\t' read -r kpath ksources; do
    [[ -z "$kpath" || "$kpath" == "null" ]] && continue
    kpath="${kpath#./}"; kpath="${kpath%/}"
    if [[ -z "$ksources" || "$ksources" == "null" ]]; then
      KS_MODE["$kpath"]="none"
    elif [[ "$ksources" == "cluster-secrets" ]]; then
      KS_MODE["$kpath"]="cluster-secrets"
    else
      KS_MODE["$kpath"]="extra:${ksources}"
    fi
    ((ks_count++)) || true
  done < <(yq eval-all '
      select(.kind == "Kustomization" and (.apiVersion | test("kustomize.toolkit.fluxcd.io")))
      | [(.spec.path // ""), ((.spec.postBuild.substituteFrom // []) | map(.name) | join(","))]
      | @tsv' "$ksfile" 2>/dev/null)
  # `grep -rlZ` is not portable here: BSD grep (macOS) returns nothing for it,
  # which silently produced an empty index and made every file look substituted.
done < <(find "$KUBERNETES_DIR" -name '*.yaml' ! -name '*.sops.yaml' -print0 \
         | xargs -0 grep -l 'kustomize.toolkit.fluxcd.io' 2>/dev/null | tr '\n' '\0')

echo "Indexed ${ks_count} Flux Kustomization(s) by spec.path"
echo ""

# Longest spec.path prefix wins.
owner_mode() {
  local rel="$1" best="" best_len=0 p
  for p in "${!KS_MODE[@]}"; do
    if [[ "$rel" == "$p/"* || "$rel" == "$p" ]]; then
      if (( ${#p} > best_len )); then best="$p"; best_len=${#p}; fi
    fi
  done
  [[ -n "$best" ]] && echo "${KS_MODE[$best]}" || echo "unowned"
}

# ------------------------------------------------------------------- main scan
while IFS= read -r -d '' file; do
  rel_file="${file#"$REPO_ROOT/"}"

  matches="$(pcre_matches_noncomment "$file")" || true
  [[ -z "$matches" ]] && continue

  mode="$(owner_mode "$rel_file")"

  # Never substituted: bare ${VAR} is correct here and escaping would break it.
  if [[ "$mode" == "none" ]]; then
    ((SKIPPED++)) || true
    continue
  fi

  # Substituted from sources we cannot enumerate from git.
  if [[ "$mode" == extra:* ]]; then
    unknown=()
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      var_name="${match#\$\{}"; var_name="${var_name%\}}"
      [[ -n "${KNOWN_SET[$var_name]:-}" ]] || unknown+=("$match")
    done <<< "$matches"
    if [[ ${#unknown[@]} -gt 0 ]]; then
      echo -e "${CYAN}ℹ${NC}  ${rel_file}:"
      echo "     INFO: ${unknown[*]} — owning Kustomization also substitutes from ${mode#extra:}; keys not knowable from git, verify by hand"
      ((UNVERIFIABLE += ${#unknown[@]})) || true
    fi
    continue
  fi

  is_configmap=false
  grep -q "kind: ConfigMap" "$file" 2>/dev/null && is_configmap=true

  file_warnings=(); file_errors=()
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    var_name="${match#\$\{}"; var_name="${var_name%\}}"
    [[ -n "${KNOWN_SET[$var_name]:-}" ]] && continue
    if $is_configmap; then
      file_errors+=("${match} (ConfigMap — use \$\${${var_name}} to prevent Flux substitution)")
    else
      file_warnings+=("${match} (not a known cluster-secret — use \$\${${var_name}} if this is an app var)")
    fi
  done <<< "$matches"

  if [[ ${#file_errors[@]} -gt 0 ]]; then
    echo -e "${RED}✗${NC} ${rel_file}:"
    for e in "${file_errors[@]}"; do echo "     ERROR: ${e}"; done
    ((ERRORS += ${#file_errors[@]})) || true
  fi
  if [[ ${#file_warnings[@]} -gt 0 ]]; then
    echo -e "${YELLOW}⚠${NC}  ${rel_file}:"
    for w in "${file_warnings[@]}"; do echo "     WARN: ${w}"; done
    ((WARNINGS += ${#file_warnings[@]})) || true
  fi
done < <(find "$KUBERNETES_DIR/apps" -name "*.yaml" ! -name "*.sops.yaml" -print0)

echo ""
[[ $SKIPPED -gt 0 ]] && echo -e "${CYAN}ℹ${NC}  Skipped ${SKIPPED} file(s) whose owning Kustomization declares no postBuild.substituteFrom — \${VAR} there is never substituted and must stay unescaped."
[[ $UNVERIFIABLE -gt 0 ]] && echo -e "${CYAN}ℹ${NC}  ${UNVERIFIABLE} reference(s) resolve against a Secret whose keys git cannot see."
[[ $SKIPPED -gt 0 || $UNVERIFIABLE -gt 0 ]] && echo ""

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
