#!/usr/bin/env python3
"""Build the SABnzbd configuration seed from the live NZBGet instance.

Reads NZBGet's config over its JSON-RPC API, connectivity-tests every news server
with a real TLS + AUTHINFO handshake, and emits a complete sabnzbd.ini.

Servers that fail authentication are carried over DISABLED with the exact error and
test date recorded in their notes, so nothing is silently dropped and re-enabling a
renewed account is a one-flag change.

Server priority ordering is preserved exactly as NZBGet has it. That ordering is
deliberate - a breadth-first strategy where smaller/bespoke providers are tried
first and the paid account is the fallback - so do not "optimise" it.

Every key emitted here was validated against SABnzbd's own cfg.py; four plausible
but non-existent keys were caught that way during the migration.

  ./scripts/sabnzbd-build-seed.py --out /tmp/sabnzbd.ini.seed
  ./scripts/sabnzbd-build-seed.py --out - --skip-test     # print, no NNTP probing

Credentials come from NZBGet's own config, so this needs no 1Password access.
Pushing the result into 1Password is sabnzbd-apply-config.py's job.
"""
import argparse, concurrent.futures as cf, json, re, socket, ssl, sys, urllib.request
from datetime import date

NZBGET_JSONRPC = "http://atlantis.server.mix.net:10007/jsonrpc"

# Paths as SABnzbd sees them inside the Synology container. /volume1/media is
# mounted at /data/media so these match what the *arr*s see over NFS exactly,
# which is what makes remote path mappings unnecessary.
DOWNLOAD_DIR = "/data/media/downloads/incomplete-sab"   # kept separate from NZBGet's
COMPLETE_DIR = "/data/media/downloads/complete"          # shared; job dirs don't collide
DIRSCAN_DIR = "/data/media/downloads/nzb"
SCRIPT_DIR = "/config/scripts"

MISC = [
    # folders
    ("download_dir", DOWNLOAD_DIR),
    ("complete_dir", COMPLETE_DIR),
    ("dirscan_dir", DIRSCAN_DIR),
    ("script_dir", SCRIPT_DIR),
    ("nzb_backup_dir", ""),
    ("permissions", "0775"),
    # free-space guards (same volume now - local NAS disk)
    ("download_free", "25G"),
    ("complete_free", "25G"),
    ("fulldisk_autoresume", "1"),
    # unpack / par
    ("direct_unpack", "1"),
    ("enable_unrar", "1"),
    ("enable_7zip", "1"),
    ("enable_filejoin", "1"),
    ("enable_tsjoin", "1"),
    ("enable_par_cleanup", "1"),
    ("enable_all_par", "0"),
    ("flat_unpack", "0"),
    ("ignore_samples", "1"),
    ("deobfuscate_final_filenames", "1"),
    ("cleanup_list", "par2, sfv, nfo, txt, srr, srs"),
    # early failure detection - the 27% FAILURE/HEALTH problem in NZBGet's history
    ("fail_hopeless_jobs", "1"),
    ("fast_fail", "1"),
    ("req_completion_rate", "100.2"),
    ("propagation_delay", "15"),
    ("pause_on_pwrar", "2"),
    ("unwanted_extensions", "exe, com, bat, scr, vbs, lnk, pif"),
    ("action_on_unwanted_extensions", "2"),
    ("unwanted_extensions_mode", "0"),
    # dupes (NZBGet DupeCheck = yes)
    ("no_dupes", "1"),
    ("no_smart_dupes", "1"),
    ("dupes_propercheck", "1"),
    # history / perf
    ("history_retention_option", "days-delete"),
    ("history_retention_number", "30"),
    ("cache_limit", "512M"),
    ("bandwidth_max", ""),
    ("bandwidth_perc", "100"),
]


def nzbget_config():
    with urllib.request.urlopen(NZBGET_JSONRPC + "/config", timeout=20) as r:
        return {i["Name"]: i["Value"] for i in json.load(r)["result"]}


def servers_from(kv):
    out = []
    for i in sorted({int(m.group(1)) for k in kv for m in [re.match(r"Server(\d+)\.Name", k)] if m}):
        g = lambda f: kv.get("Server%d.%s" % (i, f), "")
        if not g("Name"):
            continue
        out.append(dict(n=i, name=g("Name"), host=g("Host"), port=int(g("Port")),
                        user=g("Username"), pw=g("Password"), conn=int(g("Connections")),
                        level=int(g("Level")), optional=g("Optional") == "yes",
                        ssl=g("Encryption") == "yes", retention=int(g("Retention") or 0)))
    out.sort(key=lambda s: (s["level"], -s["conn"]))
    return out


def categories_from(kv):
    out = []
    for i in range(1, 30):
        if kv.get("Category%d.Name" % i):
            out.append(dict(name=kv["Category%d.Name" % i],
                            aliases=kv.get("Category%d.Aliases" % i, "")))
    return out


def probe(s):
    """TLS connect + AUTHINFO against the server's configured endpoint."""
    try:
        raw = socket.create_connection((s["host"], s["port"]), timeout=15)
        if s["ssl"]:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            raw = ctx.wrap_socket(raw, server_hostname=s["host"])
        f = raw.makefile("rwb")
        rd = lambda: f.readline().decode("utf-8", "replace").strip()
        if not rd().startswith("20"):
            raw.close(); return "GREET_FAIL"
        f.write(("AUTHINFO USER %s\r\n" % s["user"]).encode()); f.flush()
        r = rd()
        if r.startswith("381"):
            f.write(("AUTHINFO PASS %s\r\n" % s["pw"]).encode()); f.flush()
            r = rd()
        raw.close()
        return "OK" if r.startswith("281") else "AUTH_FAIL: " + r[:60]
    except ssl.SSLError as e:
        return "TLS_ERROR: " + str(e)[:60]
    except socket.timeout:
        return "TIMEOUT"
    except Exception as e:
        return "%s: %s" % (type(e).__name__, str(e)[:60])


def key_for(s):
    return "%s-%d" % (re.sub(r"[^A-Za-z0-9._-]+", "-", s["name"]).strip("-").lower(), s["n"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="output path, or - for stdout")
    ap.add_argument("--skip-test", action="store_true", help="don't probe servers; enable all")
    args = ap.parse_args()

    kv = nzbget_config()
    servers, cats = servers_from(kv), categories_from(kv)

    if args.skip_test:
        results = {s["n"]: "OK" for s in servers}
    else:
        print("probing %d news servers..." % len(servers), file=sys.stderr)
        with cf.ThreadPoolExecutor(12) as ex:
            results = dict(zip([s["n"] for s in servers], ex.map(probe, servers)))

    L = ["__version__ = 19", "__encoding__ = utf-8", "[misc]"]
    L += ["%s = %s" % kvp for kvp in MISC]
    L += ["", "[servers]"]
    today = date.today().isoformat()
    for s in servers:
        res = results[s["n"]]
        ok = res == "OK"
        L += ["[[%s]]" % key_for(s),
              "displayname = %s" % s["name"],
              "host = %s" % s["host"],
              "port = %d" % s["port"],
              "username = %s" % s["user"],
              "password = %s" % s["pw"],
              "connections = %d" % s["conn"],
              "ssl = %d" % (1 if s["ssl"] else 0),
              "ssl_verify = 2",
              "ssl_ciphers = ",
              "priority = %d" % s["level"],
              "retention = %d" % s["retention"],
              "timeout = 60",
              "enable = %d" % (1 if ok else 0),
              "optional = %d" % (1 if s["optional"] else 0),
              "required = 0",
              "expire_date = ", "quota = ", "usage_at_start = 0",
              "notes = %s" % ("migrated from NZBGet %s" % today if ok
                              else "DISABLED %s: %s" % (today, res)),
              ""]
    L += ["[categories]", "[[*]]", "order = 0", "pp = 3", "script = None",
          "dir = ", "newzbin = ", "priority = 0", ""]
    for i, c in enumerate(cats, start=1):
        L += ["[[%s]]" % c["name"], "order = %d" % i, "pp = 3", "script = None",
              "dir = %s" % c["name"], "newzbin = %s" % c["aliases"], "priority = 0", ""]

    text = "\n".join(L) + "\n"
    if args.out == "-":
        sys.stdout.write(text)
    else:
        open(args.out, "w").write(text)

    enabled = sum(1 for r in results.values() if r == "OK")
    print("seed: %d bytes | servers %d (%d enabled, %d disabled) | categories %d + catch-all"
          % (len(text), len(servers), enabled, len(servers) - enabled, len(cats)), file=sys.stderr)
    for s in servers:
        if results[s["n"]] != "OK":
            print("  DISABLED  %-26s %s" % (s["name"], results[s["n"]]), file=sys.stderr)


main()
