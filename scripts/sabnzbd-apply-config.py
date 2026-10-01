#!/usr/bin/env python3
"""Apply the SABnzbd configuration seed to the running instance over its API.

SABnzbd runs on the Synology, so there is no init container to render its config and
no cluster filesystem to write into. Instead the whole configuration is pushed over
the HTTP API, which needs no SSH and no .env file.

The seed is the source of truth and lives encrypted in 1Password
(vault homeops, item sabnzbd, field config_seed). This script never prints it, and
never prints server credentials or the API key.

  # build a fresh seed from NZBGet and store it, then apply it
  op-session exec python3 scripts/sabnzbd-apply-config.py --build --push --apply

  # apply what is already in 1Password
  op-session exec python3 scripts/sabnzbd-apply-config.py --apply

  # read back what SABnzbd actually has, no writes
  op-session exec python3 scripts/sabnzbd-apply-config.py --verify

Requires an active op-session. --apply additionally needs SABnzbd reachable.
"""
import argparse, json, os, re, subprocess, sys, tempfile, urllib.parse, urllib.request

SAB_URL = os.environ.get("SAB_URL", "http://atlantis.server.mix.net:10008")
OP_ITEM = "sabnzbd"
OP_VAULT = "homeops"
SEED_FIELD = "config_seed"

SERVER_FIELDS = {"displayname", "host", "port", "username", "password", "connections",
                 "ssl", "ssl_verify", "ssl_ciphers", "priority", "retention", "timeout",
                 "enable", "optional", "required", "expire_date", "quota",
                 "usage_at_start", "notes"}
CAT_FIELDS = {"order", "pp", "script", "dir", "newzbin", "priority"}
# Managed by the container's environment, not by the seed.
MISC_SKIP = {"api_key", "nzb_key", "host_whitelist", "host", "port", "inet_exposure"}


def op(*args, stdin=None):
    r = subprocess.run(["op", *args], capture_output=True, text=True, input=stdin)
    if r.returncode:
        sys.exit("op failed: " + (r.stderr.strip()[:300] or "unknown"))
    return r.stdout


def seed_from_1password():
    raw = op("item", "get", OP_ITEM, "--vault", OP_VAULT, "--format", "json")
    item = json.loads(raw)
    for f in item.get("fields", []):
        if f.get("label") == SEED_FIELD and f.get("value"):
            return f["value"]
    sys.exit("1Password item %r has no populated %r field - run with --build --push"
             % (OP_ITEM, SEED_FIELD))


def push_seed(text):
    raw = op("item", "get", OP_ITEM, "--vault", OP_VAULT, "--format", "json")
    item = json.loads(raw)
    item["fields"] = [f for f in item.get("fields", []) if f.get("label") != SEED_FIELD]
    item["fields"].append({"id": SEED_FIELD, "label": SEED_FIELD,
                           "type": "CONCEALED", "value": text})
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(item, fh)
        path = fh.name
    try:
        op("item", "edit", OP_ITEM, "--vault", OP_VAULT, "--template", path)
    finally:
        os.unlink(path)
    print("pushed config_seed to 1Password (%d bytes)" % len(text))


def build_seed():
    out = os.path.join(tempfile.gettempdir(), "sabnzbd.ini.seed")
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run([sys.executable, os.path.join(here, "sabnzbd-build-seed.py"),
                        "--out", out], text=True)
    if r.returncode:
        sys.exit("seed build failed")
    text = open(out).read()
    os.unlink(out)
    return text


def parse(seed):
    """Split the seed ini into misc dict, servers dict, categories dict."""
    misc, servers, cats = {}, {}, {}
    sec, sub = None, None
    for line in seed.splitlines():
        t = line.strip()
        if not t or t.startswith("#") or t.startswith("__"):
            continue
        if t.startswith("[[") and t.endswith("]]"):
            sub = t[2:-2]
            (servers if sec == "servers" else cats).setdefault(sub, {})
            continue
        if t.startswith("[") and t.endswith("]"):
            sec, sub = t[1:-1], None
            continue
        if "=" not in t:
            continue
        k, v = (x.strip() for x in t.split("=", 1))
        if sec == "misc" and sub is None:
            misc[k] = v
        elif sec == "servers" and sub:
            servers[sub][k] = v
        elif sec == "categories" and sub:
            cats[sub][k] = v
    return misc, servers, cats


def api_key():
    return op("read", "op://%s/%s/api_key" % (OP_VAULT, OP_ITEM)).strip()


def call(key, **params):
    params.update(apikey=key, output="json")
    url = SAB_URL + "/api?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=60) as r:
        body = r.read().decode()
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return {"status": False, "error": body[:200]}


def apply_all(seed):
    key = api_key()
    ver = call(key, mode="version").get("version")
    if not ver:
        sys.exit("SABnzbd at %s did not answer mode=version - is it running?" % SAB_URL)
    print("SABnzbd %s at %s" % (ver, SAB_URL))

    misc, servers, cats = parse(seed)
    fails = []

    # [misc] - one call per key: set_config needs section + keyword + value
    n = 0
    for k, v in misc.items():
        if k in MISC_SKIP:
            continue
        r = call(key, mode="set_config", section="misc", keyword=k, value=v)
        if r.get("status") is False or r.get("error"):
            fails.append("misc.%s: %s" % (k, r.get("error")))
        else:
            n += 1
    print("misc: %d key(s) applied" % n)

    # [servers] - keyword is the server name; unknown fields are ignored by SAB
    for name, fields in servers.items():
        p = {k: v for k, v in fields.items() if k in SERVER_FIELDS}
        r = call(key, mode="set_config", section="servers", keyword=name, **p)
        state = "enabled" if fields.get("enable") == "1" else "DISABLED"
        if r.get("status") is False or r.get("error"):
            fails.append("server %s: %s" % (name, r.get("error")))
        else:
            print("  server %-28s %-8s pri=%s conn=%s" % (fields.get("displayname", name),
                  state, fields.get("priority"), fields.get("connections")))

    # [categories]
    for name, fields in cats.items():
        if name == "*":
            continue
        p = {k: v for k, v in fields.items() if k in CAT_FIELDS}
        r = call(key, mode="set_config", section="categories", keyword=name, **p)
        if r.get("status") is False or r.get("error"):
            fails.append("category %s: %s" % (name, r.get("error")))
    print("categories: %d applied" % max(0, len(cats) - 1))

    if fails:
        print("\n%d failure(s):" % len(fails))
        for f in fails:
            print("  " + f)
        return 1
    print("\nall settings applied cleanly")
    return 0


def verify():
    key = api_key()
    cfg = call(key, mode="get_config").get("config")
    if not cfg:
        sys.exit("could not read config from %s" % SAB_URL)
    m = cfg["misc"]
    print("SABnzbd %s" % call(key, mode="version").get("version"))
    print("\n-- folders & guards --")
    for k in ("download_dir", "complete_dir", "dirscan_dir", "script_dir",
              "download_free", "complete_free", "permissions"):
        print("  %-28s = %s" % (k, m.get(k)))
    print("\n-- processing & failure detection --")
    for k in ("direct_unpack", "fail_hopeless_jobs", "fast_fail", "req_completion_rate",
              "propagation_delay", "pause_on_pwrar", "action_on_unwanted_extensions",
              "unwanted_extensions", "cleanup_list", "no_dupes", "cache_limit",
              "history_retention_option", "history_retention_number"):
        print("  %-28s = %s" % (k, m.get(k)))
    srv = cfg["servers"]
    print("\n-- servers: %d total, %d enabled --" % (len(srv), sum(1 for s in srv if s["enable"])))
    for s in sorted(srv, key=lambda x: (x["priority"], -int(x["connections"]))):
        print("  pri=%s %s conn=%-3s %-26s %s:%s" % (s["priority"], "ON " if s["enable"] else "off",
              s["connections"], s["displayname"][:26], s["host"], s["port"]))
    print("\n-- categories --")
    for c in cfg["categories"]:
        print("  %-12s -> %s" % (c["name"], c["dir"]))
    q = call(key, mode="queue")["queue"]
    print("\nqueue: paused=%s  free(download_dir)=%s GB  free(complete_dir)=%s GB"
          % (q.get("paused"), q.get("diskspace1"), q.get("diskspace2")))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true", help="rebuild the seed from NZBGet")
    ap.add_argument("--push", action="store_true", help="store the seed in 1Password")
    ap.add_argument("--apply", action="store_true", help="push the seed into SABnzbd")
    ap.add_argument("--verify", action="store_true", help="read back SABnzbd's live config")
    a = ap.parse_args()
    if not any((a.build, a.push, a.apply, a.verify)):
        ap.error("nothing to do - pass at least one of --build/--push/--apply/--verify")

    seed = build_seed() if a.build else None
    if a.push:
        if seed is None:
            ap.error("--push needs --build")
        push_seed(seed)
    rc = 0
    if a.apply:
        rc |= apply_all(seed if seed is not None else seed_from_1password())
    if a.verify:
        rc |= verify()
    sys.exit(rc)


main()
