#!/usr/bin/env bash
# Round-trip the running SABnzbd configuration back into 1Password.
#
# The seed-merge init container treats a declared set of keys (news servers,
# categories, folders, the tuning in docs/sabnzbd-migration.md §4/§5d) as
# 1Password-authoritative. Everything else you change in the web UI persists on
# the PVC untouched. When you deliberately change one of the MANAGED keys in the
# UI and want it to stick across a PVC rebuild, run this to make the vault match.
#
# Volatile runtime state is stripped so the seed stays a configuration document
# rather than a snapshot of counters.
#
#   ./scripts/sabnzbd-export-config.sh --diff   # show what would change
#   ./scripts/sabnzbd-export-config.sh          # write it back to 1Password
#
# Requires: an active op-session and a working KUBECONFIG.
set -euo pipefail

MODE="${1:-write}"
NS=media
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=sabnzbd -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "no sabnzbd pod found in $NS" >&2; exit 1; }

kubectl exec -n "$NS" "$POD" -c app -- cat /config/sabnzbd.ini > "$WORK/live.ini"

# Drop keys SABnzbd rewrites constantly; they are state, not configuration.
python3 - "$WORK/live.ini" "$WORK/clean.ini" <<'PY'
import sys
VOLATILE = {
    "__version__", "check_new_rel", "last_opendir", "queue_complete",
    "notified_new_skin", "direct_unpack_tested", "config_conversion_version",
    "sorters_converted", "fixed_ports", "usage_at_start", "expire_date",
}
src, dst = sys.argv[1], sys.argv[2]
out = []
for line in open(src).read().splitlines():
    key = line.split("=")[0].strip() if "=" in line else ""
    if key in VOLATILE:
        continue
    out.append(line.rstrip())
while out and not out[-1]:
    out.pop()
open(dst, "w").write("\n".join(out) + "\n")
print(f"exported {len(out)} lines", file=sys.stderr)
PY

op item get sabnzbd --vault homeops --format json > "$WORK/item.json"
python3 - "$WORK/item.json" "$WORK/clean.ini" "$WORK/item.new.json" "$MODE" <<'PY'
import json, sys, difflib
item_path, ini_path, out_path, mode = sys.argv[1:5]
item = json.load(open(item_path))
new = open(ini_path).read()
cur = next((f.get("value") or "" for f in item.get("fields", [])
            if f.get("label") == "config_seed"), "")

if cur == new:
    print("config_seed already matches the running config - nothing to do")
    sys.exit(3)

diff = list(difflib.unified_diff(cur.splitlines(), new.splitlines(),
                                 "1password", "running", lineterm="", n=1))
# Never print the diff bodies: server credentials live in these lines.
adds = sum(1 for d in diff if d.startswith("+") and not d.startswith("+++"))
dels = sum(1 for d in diff if d.startswith("-") and not d.startswith("---"))
secs = sorted({d.lstrip("+- ").split("=")[0].strip()
               for d in diff
               if d[:1] in "+-" and not d.startswith(("+++", "---")) and "=" in d})
print(f"config_seed would change: +{adds} / -{dels} line(s)")
print("keys touched: " + (", ".join(secs[:25]) or "(section structure only)"))

if mode == "--diff":
    sys.exit(3)

item["fields"] = [f for f in item.get("fields", []) if f.get("label") != "config_seed"]
item["fields"].append({"id": "config_seed", "label": "config_seed",
                       "type": "CONCEALED", "value": new})
json.dump(item, open(out_path, "w"))
PY
rc=$?
[[ $rc -eq 3 ]] && exit 0
[[ $rc -ne 0 ]] && exit $rc

op item edit sabnzbd --vault homeops --template "$WORK/item.new.json" >/dev/null
echo "config_seed updated in 1Password"
