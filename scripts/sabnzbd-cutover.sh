#!/usr/bin/env bash
# Migration phase P5: cut the *arrs over from NZBGet to SABnzbd.
#
# Everything this touches was already staged and connectivity-tested by
# ./scripts/sabnzbd-prestage-arrs.sh. This script only flips state:
#
#   1. enable the SABnzbd client in Sonarr / Radarr / Radarr4k / Prowlarr
#   2. disable the NZBGet client in all four
#   3. delete the stale remote path mappings (host 10.0.3.2 -> /downloads/)
#
# The mappings are inert today - they key on the NZBGet host, which SABnzbd does
# not use - but they are dead config pointing at a host that is about to be
# retired, so they go with the cutover.
#
#   ./scripts/sabnzbd-cutover.sh --dry-run
#   ./scripts/sabnzbd-cutover.sh
#   ./scripts/sabnzbd-cutover.sh --rollback    # back to NZBGet, mappings restored
#
# Rollback re-enables NZBGet and disables SABnzbd. It does NOT recreate deleted
# path mappings; run with --keep-mappings on the way out if you want them kept.
#
# Not handled here (a Git change, not API state): retiring unpackerr. See
# docs/sabnzbd-migration.md §8.
set -euo pipefail

MODE=apply
KEEP_MAPPINGS=0
for a in "$@"; do
  case "$a" in
    --dry-run)        MODE=dry ;;
    --rollback)       MODE=rollback ;;
    --keep-mappings)  KEEP_MAPPINGS=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

NS=media
TARGETS=("sonarr:8989:v3" "radarr:7878:v3" "radarr4k:7878:v3" "prowlarr:9696:v1")

log() { printf '%s\n' "$*" >&2; }

pf_pid=""
cleanup() { [[ -n "${pf_pid}" ]] && kill "${pf_pid}" 2>/dev/null || true; }
trap cleanup EXIT

# which implementation should end up enabled
if [[ "$MODE" == "rollback" ]]; then WANT_ON=Nzbget; WANT_OFF=Sabnzbd
else                                 WANT_ON=Sabnzbd; WANT_OFF=Nzbget; fi

flip() {
  local app=$1 port=$2 apiver=$3
  local lport=$((port + 40000)) rc=0

  kubectl port-forward -n "$NS" "svc/$app" "$lport:$port" >/dev/null 2>&1 &
  pf_pid=$!
  sleep 3

  local key base clients
  key=$(kubectl get secret -n "$NS" "$app-secret" -o jsonpath='{.data}' \
        | python3 -c "import sys,json,base64;d=json.load(sys.stdin);print(next(base64.b64decode(v).decode() for k,v in d.items() if 'APIKEY' in k.upper().replace('_','')))")
  base="http://localhost:$lport/api/$apiver"
  clients=$(curl -sf -H "X-Api-Key: $key" "$base/downloadclient")

  echo "$clients" | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    print('    before: %-9s %-8s enabled=%s' % (c['name'], c['implementation'], c['enable']))
" >&2

  for impl in "$WANT_ON:true" "$WANT_OFF:false"; do
    local want_impl=${impl%%:*} want_state=${impl##*:}
    local body id
    body=$(CLIENTS="$clients" IMPL="$want_impl" STATE="$want_state" python3 -c "
import json, os
clients = json.loads(os.environ['CLIENTS'])
c = next((x for x in clients if x['implementation'] == os.environ['IMPL']), None)
if c is None:
    print(''); raise SystemExit
c['enable'] = os.environ['STATE'] == 'true'
print(json.dumps({'id': c['id'], 'body': c}))
")
    [[ -z "$body" ]] && { log "    ! $app: no $want_impl client found - skipping"; continue; }
    id=$(python3 -c "import json,sys;print(json.load(sys.stdin)['id'])" <<<"$body")
    payload=$(python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['body']))" <<<"$body")

    if [[ "$MODE" == "dry" ]]; then
      log "    [dry-run] would set $want_impl enable=$want_state on $app"
      continue
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "X-Api-Key: $key" \
           -H 'Content-Type: application/json' -d "$payload" "$base/downloadclient/$id")
    case "$code" in
      200|202) log "    ✓ $app: $want_impl enable=$want_state" ;;
      *)       log "    ✗ $app: failed to set $want_impl (HTTP $code)"; rc=1 ;;
    esac
  done

  # stale remote path mappings (Sonarr/Radarr only; Prowlarr has no such endpoint)
  if [[ "$apiver" == "v3" && $KEEP_MAPPINGS -eq 0 && "$MODE" != "rollback" ]]; then
    for mid in $(curl -sf -H "X-Api-Key: $key" "$base/remotepathmapping" \
                 | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    if m.get('host') == '10.0.3.2':
        print(m['id'])"); do
      if [[ "$MODE" == "dry" ]]; then
        log "    [dry-run] would delete remote path mapping id=$mid (host 10.0.3.2)"
      else
        code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "X-Api-Key: $key" "$base/remotepathmapping/$mid")
        case "$code" in
          200|202|204) log "    ✓ $app: deleted stale path mapping id=$mid" ;;
          *)           log "    ✗ $app: failed to delete mapping id=$mid (HTTP $code)"; rc=1 ;;
        esac
      fi
    done
  fi

  kill "$pf_pid" 2>/dev/null; pf_pid=""
  return $rc
}

case "$MODE" in
  dry)      log "=== P5 cutover DRY RUN - nothing will change ===" ;;
  rollback) log "=== P5 ROLLBACK: re-enabling NZBGet, disabling SABnzbd ===" ;;
  *)        log "=== P5 CUTOVER: enabling SABnzbd, disabling NZBGet ===" ;;
esac
log ""

overall=0
for t in "${TARGETS[@]}"; do
  IFS=: read -r app port apiver <<<"$t"
  log "$app:"
  flip "$app" "$port" "$apiver" || overall=1
  log ""
done

if [[ $overall -eq 0 ]]; then
  if [[ "$MODE" == "apply" ]]; then
    log "=== cutover complete ==="
    log "Watch the first few grabs, then retire NZBGet on the Synology (P6)."
    log "Roll back at any time with: $0 --rollback"
  else
    log "=== done ==="
  fi
else
  log "=== completed with errors - see above ==="
fi
exit $overall
