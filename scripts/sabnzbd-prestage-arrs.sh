#!/usr/bin/env bash
# Pre-stage SABnzbd as a DISABLED download client in Sonarr, Radarr, Radarr4k and
# Prowlarr, then run each client's built-in connectivity test.
#
# This is migration phase P4 (see docs/sabnzbd-migration.md). It changes nothing
# behaviourally: NZBGet stays enabled and keeps serving every grab. The point is to
# have SABnzbd wired, category-correct and proven reachable, so that the P5 cutover
# is nothing but flipping enable flags.
#
# *arr configuration lives in each app's SQLite DB, not in Git, so this is applied
# over the API. It is idempotent — re-running updates the existing client rather
# than creating a duplicate.
#
# The client body is built from each app's own /downloadclient/schema rather than
# from hardcoded field names, because Sonarr, Radarr and Prowlarr each define a
# different field set for the same SABnzbd implementation.
#
#   ./scripts/sabnzbd-prestage-arrs.sh --dry-run   # show what would change
#   ./scripts/sabnzbd-prestage-arrs.sh             # stage (disabled) + test
#
# Requires: an active op-session (for the SABnzbd API key) and a working KUBECONFIG.
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

NS=media
SAB_HOST=sabnzbd.media.svc.cluster.local
SAB_PORT=8080

# app : service-port : api-version : category
TARGETS=(
  "sonarr:8989:v3:tvshows"
  "radarr:7878:v3:movies"
  "radarr4k:7878:v3:movies-4k"
  "prowlarr:9696:v1:"
)

log() { printf '%s\n' "$*" >&2; }

SAB_API_KEY=$(op-session exec op read "op://homeops/sabnzbd/api_key")

pf_pid=""
cleanup() { [[ -n "${pf_pid}" ]] && kill "${pf_pid}" 2>/dev/null || true; }
trap cleanup EXIT

prestage() {
  local app=$1 port=$2 apiver=$3 cat=$4
  local lport=$((port + 20000))
  local rc=0

  kubectl port-forward -n "$NS" "svc/$app" "$lport:$port" >/dev/null 2>&1 &
  pf_pid=$!
  sleep 3

  local key base
  key=$(kubectl get secret -n "$NS" "$app-secret" -o jsonpath='{.data}' \
        | python3 -c "import sys,json,base64;d=json.load(sys.stdin);print(next(base64.b64decode(v).decode() for k,v in d.items() if 'APIKEY' in k.upper().replace('_','')))")
  base="http://localhost:$lport/api/$apiver"

  local body
  body=$(SAB_HOST="$SAB_HOST" SAB_PORT="$SAB_PORT" SAB_API_KEY="$SAB_API_KEY" CAT="$cat" \
         SCHEMA="$(curl -sf -H "X-Api-Key: $key" "$base/downloadclient/schema")" \
         EXISTING="$(curl -sf -H "X-Api-Key: $key" "$base/downloadclient")" \
         python3 - <<'PY'
import json, os, sys

schema = json.loads(os.environ["SCHEMA"])
existing = json.loads(os.environ["EXISTING"])
cat = os.environ["CAT"]

tmpl = next((s for s in schema if s.get("implementation") == "Sabnzbd"), None)
if tmpl is None:
    sys.exit("this app's schema has no Sabnzbd implementation")

values = {
    "host": os.environ["SAB_HOST"],
    "port": int(os.environ["SAB_PORT"]),
    "apiKey": os.environ["SAB_API_KEY"],
    "useSsl": False,
    "urlBase": "",
}
# whichever category field this app happens to define. Always set it, even to
# "" - Prowlarr's schema ships a default category ("prowlarr") that does not
# exist in SABnzbd, and its test rejects a category SABnzbd lacks.
for f in tmpl.get("fields", []):
    if f["name"] in ("tvCategory", "movieCategory", "category"):
        values[f["name"]] = cat

body = dict(tmpl)
body["name"] = "SABnzbd"
body["enable"] = False           # P4 stages it inert. P5 flips this to True.
body["priority"] = 1
body["tags"] = []
body["fields"] = [
    {**f, "value": values.get(f["name"], f.get("value"))} for f in tmpl.get("fields", [])
]
for k in ("removeCompletedDownloads", "removeFailedDownloads"):
    if k in body:
        body[k] = True

prior = next((c for c in existing if c.get("implementation") == "Sabnzbd"), None)
if prior:
    body["id"] = prior["id"]

print(json.dumps({
    "body": body,
    "id": prior["id"] if prior else "",
    "catfields": [f["name"] for f in tmpl.get("fields", []) if f["name"] in values and "ategory" in f["name"]],
}))
PY
) || { log "  ✗ $app: could not build client body"; kill "$pf_pid" 2>/dev/null; pf_pid=""; return 1; }

  local payload id catf
  payload=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(json.dumps(d['body']))" <<<"$body")
  id=$(python3 -c "import json,sys;print(json.load(sys.stdin)['id'])" <<<"$body")
  catf=$(python3 -c "import json,sys;print(','.join(json.load(sys.stdin)['catfields']) or 'n/a')" <<<"$body")

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  [dry-run] would $( [[ -n $id ]] && echo update || echo create ) SABnzbd on $app (enable=false, $catf=${cat:-none})"
    kill "$pf_pid" 2>/dev/null; pf_pid=""; return 0
  fi

  log "  testing $app -> $SAB_HOST:$SAB_PORT ..."
  local tcode
  tcode=$(curl -s -o "/tmp/sabtest.$app" -w '%{http_code}' -X POST -H "X-Api-Key: $key" \
          -H 'Content-Type: application/json' -d "$payload" "$base/downloadclient/test")
  WARN_ONLY=$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("no"); sys.exit()
print("yes" if isinstance(d,list) and d and all(e.get("isWarning") for e in d) else "no")' "/tmp/sabtest.$app")

  if [[ "$tcode" != "200" && "$tcode" != "202" && "$WARN_ONLY" != "yes" ]]; then
    log "  ✗ $app: connectivity test FAILED (HTTP $tcode)"
    head -c 400 "/tmp/sabtest.$app" >&2; echo >&2
    rc=1
  else
    if [[ "$WARN_ONLY" == "yes" ]]; then
      msg=$(python3 -c 'import json,sys
print("; ".join(e.get("errorMessage","?") for e in json.load(open(sys.argv[1]))))' "/tmp/sabtest.$app")
      log "  ! $app: reachable; advisory only ($msg)"
    else
      log "  ✓ $app: SABnzbd reachable and authenticated"
    fi
    local scode
    if [[ -n "$id" ]]; then
      scode=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "X-Api-Key: $key" \
              -H 'Content-Type: application/json' -d "$payload" "$base/downloadclient/$id")
    else
      scode=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Api-Key: $key" \
              -H 'Content-Type: application/json' -d "$payload" "$base/downloadclient")
    fi
    case "$scode" in
      200|201|202) log "  ✓ $app: staged disabled ($catf=${cat:-none})" ;;
      *)           log "  ✗ $app: save failed (HTTP $scode)"; rc=1 ;;
    esac
  fi

  kill "$pf_pid" 2>/dev/null; pf_pid=""
  return $rc
}

log "=== P4 pre-stage: SABnzbd as a DISABLED download client ==="
log "NZBGet stays enabled and untouched. Nothing changes behaviourally."
log ""

overall=0
for t in "${TARGETS[@]}"; do
  IFS=: read -r app port apiver cat <<<"$t"
  log "$app:"
  prestage "$app" "$port" "$apiver" "$cat" || overall=1
  log ""
done

if [[ $overall -eq 0 ]]; then
  log "=== all targets staged and connectivity-tested; nothing is live ==="
else
  log "=== completed with errors - see above ==="
fi
exit $overall
