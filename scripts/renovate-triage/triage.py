#!/usr/bin/env python3
"""Renovate PR triage engine for 1activegeek/home-ops.

Classifies open Renovate PRs by type label + CI status and outputs triage.json.
Optionally squash-merges the safe bucket.

Only PRs authored by the Renovate GitHub App's bot user are considered. Labels
are NOT trusted for this: anyone who can open a PR can add a `renovate/*` or
`type/patch` label, and the safe bucket gets merged without human review. Each
PR is re-checked against the REST API (login, account type and user id) right
before it is merged.

No approvals. main requires a PR plus the "Flux Local Success" check with zero
required approvals, so an approval adds nothing -- and an approval issued from
the operator's gh login would be recorded as the human owner reviewing code
nobody reviewed. Merges run as whatever identity gh is authenticated as; use an
agent/bot token (GH_TOKEN) rather than a personal one.

Release-age burn-in is enforced HERE, at merge time, via MIN_PR_AGE_DAYS.
Renovate's own `minimumReleaseAge` (.renovaterc.json5) cannot carry the gate on
its own: most OCI registries (GHCR, quay.io, mcr) expose no per-tag release
timestamp, so that check never resolves for those images. .renovaterc.json5 sets
internalChecksFilter: "none" so the PR is raised anyway, and this script holds it
until the PR itself is MIN_PR_AGE_DAYS old before it lands in the safe bucket.

Usage:
  triage.py                        # report mode, JSON to stdout
  triage.py --out triage.json      # write to file
  triage.py --merge-safe           # merge safe PRs, then verify cluster health
  triage.py --merge-safe --dry-run # print gh commands, don't run (no health check)
  triage.py --merge-safe --skip-health-check  # merge but don't wait for the cluster
  triage.py --verify-health        # just run the cluster health check (no triage/merge)
  triage.py --repo owner/repo      # override repo

Cluster health check (after a real merge, or via --verify-health):
  Merged PRs land on main; Flux reconciles the change onto the cluster. Before
  declaring the run complete we nudge Flux and poll until the GitOps state settles:
  every Flux Kustomization and HelmRelease reports Ready=True, and no pod is stuck
  (CrashLoopBackOff / image-pull errors / Failed). Covers both pod restarts and
  GitOps drift settling. Requires kubectl + flux pointed at the cluster.
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone

REPO = "1activegeek/home-ops"

# The hosted Mend Renovate app (GitHub App id 2740) acts as this bot user.
# `gh pr list` reports it as login "app/renovate" with is_bot=true; the REST API
# as login "renovate[bot]", type "Bot", id 29139614. "[bot]" logins can't be
# registered by people, and the id pins it to this specific app.
RENOVATE_GH_LIST_LOGIN = "app/renovate"
RENOVATE_BOT_LOGIN = "renovate[bot]"
RENOVATE_BOT_USER_ID = 29139614

# Flux git source to nudge after a merge so we don't wait out the poll interval.
FLUX_GIT_SOURCE = "flux-system"
FLUX_GIT_SOURCE_NS = "flux-system"

# Health-check defaults.
HEALTH_TIMEOUT_S = 600   # max wait for the cluster to settle after a merge
HEALTH_POLL_S = 20       # seconds between readiness polls
# Container waiting reasons that mean a pod is wedged, not just starting.
POD_BAD_WAITING = {
    "CrashLoopBackOff",
    "ImagePullBackOff",
    "ErrImagePull",
    "CreateContainerConfigError",
    "CreateContainerError",
    "InvalidImageName",
}

# Burn-in: a safe PR must sit open this many days before auto-merge. See the
# module docstring for why this lives here and not in Renovate's config.
MIN_PR_AGE_DAYS = 3

TYPE_LABELS = {"type/major", "type/minor", "type/patch", "type/digest"}
SAFE_TYPES = {"type/minor", "type/patch", "type/digest"}
PASSING_CONCLUSIONS = {"SUCCESS", "NEUTRAL", "SKIPPED"}
FAILING_CONCLUSIONS = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"}


def gh(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"gh error: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def fetch_prs(repo):
    raw = gh(
        "pr", "list",
        "--repo", repo,
        "--state", "open",
        "--limit", "100",
        "--json", "number,title,labels,author,createdAt,url,mergeable,statusCheckRollup",
    )
    return json.loads(raw)


def is_renovate(pr):
    """True only if the PR author is the Renovate app's bot user (never by label)."""
    author = pr.get("author") or {}
    return bool(author.get("is_bot")) and author.get("login") == RENOVATE_GH_LIST_LOGIN


def verify_renovate_author(pr_number, repo):
    """Re-check authorship against the REST API immediately before merging."""
    raw = gh("api", f"repos/{repo}/pulls/{pr_number}", "--jq",
             "{login: .user.login, type: .user.type, id: .user.id}")
    user = json.loads(raw)
    return (user.get("login") == RENOVATE_BOT_LOGIN
            and user.get("type") == "Bot"
            and user.get("id") == RENOVATE_BOT_USER_ID)


def extract_type(labels):
    names = {l["name"] for l in labels}
    for t in ("type/major", "type/minor", "type/patch", "type/digest"):
        if t in names:
            return t
    return None


def extract_source(labels):
    for l in labels:
        if l["name"].startswith("renovate/"):
            return l["name"]
    return "renovate/unknown"


def checks_state(rollup):
    """Returns 'green', 'pending', or 'failed' based on statusCheckRollup."""
    if not rollup:
        return "pending"
    conclusions = [c.get("conclusion") for c in rollup]
    statuses = [c.get("status") for c in rollup]
    if any(c in FAILING_CONCLUSIONS for c in conclusions if c):
        return "failed"
    if any(s != "COMPLETED" for s in statuses):
        return "pending"
    return "green"


def pr_age_days(created_at):
    """PR age in days. This is the burn-in clock — see MIN_PR_AGE_DAYS."""
    created = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    return (datetime.now(timezone.utc) - created).days


def bucket_pr(pr):
    labels = pr["labels"]
    update_type = extract_type(labels)
    source = extract_source(labels)
    age = pr_age_days(pr["createdAt"])
    ci = checks_state(pr["statusCheckRollup"])
    mergeable = pr["mergeable"]

    entry = {
        "number": pr["number"],
        "title": pr["title"],
        "url": pr["url"],
        "type": update_type,
        "source": source,
        "age_days": age,
        "checks_state": ci,
        "mergeable": mergeable,
    }

    if ci == "failed" or mergeable == "CONFLICTING":
        reasons = []
        if ci == "failed":
            reasons.append("CI checks failing")
        if mergeable == "CONFLICTING":
            reasons.append("merge conflict")
        entry["reason"] = "; ".join(reasons)
        return "blocked", entry

    if update_type == "type/major":
        entry["reason"] = "major update requires manual review"
        return "review", entry

    if update_type in SAFE_TYPES:
        if ci != "green":
            entry["reason"] = f"checks {ci}"
            return "waiting", entry
        if age < MIN_PR_AGE_DAYS:
            entry["reason"] = (
                f"burn-in: PR is {age}d old, needs {MIN_PR_AGE_DAYS}d"
            )
            return "waiting", entry
        entry["reason"] = (
            f"{update_type}, all checks green, burn-in passed ({age}d old)"
        )
        return "safe", entry

    entry["reason"] = "unknown update type; manual review needed"
    return "review", entry


def run_gh_merge(pr_number, repo, dry_run):
    # No `gh pr review --approve`: see the module docstring.
    merge_cmd = ["gh", "pr", "merge", str(pr_number), "-R", repo, "--squash", "--delete-branch"]
    if not verify_renovate_author(pr_number, repo):
        print(f"  REFUSING to merge #{pr_number}: author is not the Renovate bot",
              file=sys.stderr)
        return False
    if dry_run:
        print(f"  [dry-run] {' '.join(merge_cmd)}")
        return True
    print(f"  Merging PR #{pr_number}...")
    r = subprocess.run(merge_cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  Merge failed: {r.stderr.strip()}", file=sys.stderr)
        return False
    return True


# --- cluster health verification -------------------------------------------


def _run(cmd):
    """Run a command, return (returncode, stdout, stderr). Never raises."""
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def _kubectl_json(kind):
    """`kubectl get <kind> -A -o json` → list of items (empty on any error)."""
    rc, out, err = _run(["kubectl", "get", kind, "-A", "-o", "json"])
    if rc != 0:
        print(f"  health: kubectl get {kind} failed: {err.strip()}", file=sys.stderr)
        return None
    try:
        return json.loads(out).get("items", [])
    except json.JSONDecodeError:
        return None


def _ready_condition(item):
    """Return the Ready condition status string ('True'/'False'/'Unknown') or None."""
    for c in item.get("status", {}).get("conditions", []):
        if c.get("type") == "Ready":
            return c.get("status")
    return None


def _flux_not_ready(kind):
    """Names of Flux resources of `kind` (Kustomization/HelmRelease) not Ready=True.

    Suspended resources are skipped — they're intentionally paused. Returns a list
    of 'ns/name (msg)' strings, or None if the cluster couldn't be queried."""
    items = _kubectl_json(kind)
    if items is None:
        return None
    bad = []
    for it in items:
        if it.get("spec", {}).get("suspend"):
            continue
        if _ready_condition(it) == "True":
            continue
        meta = it["metadata"]
        msg = next(
            (c.get("message", "") for c in it.get("status", {}).get("conditions", [])
             if c.get("type") == "Ready"),
            "no Ready condition yet",
        )
        bad.append(f"{meta.get('namespace', '?')}/{meta['name']} ({msg})")
    return bad


def _unhealthy_pods():
    """Names of pods stuck in a bad state. Skips completed pods. None on query error."""
    items = _kubectl_json("pods")
    if items is None:
        return None
    bad = []
    for pod in items:
        status = pod.get("status", {})
        phase = status.get("phase")
        if phase in ("Succeeded",):
            continue
        meta = pod["metadata"]
        ref = f"{meta.get('namespace', '?')}/{meta['name']}"
        if phase == "Failed":
            bad.append(f"{ref} (phase=Failed)")
            continue
        for cs in status.get("containerStatuses", []):
            waiting = (cs.get("state", {}).get("waiting") or {})
            reason = waiting.get("reason")
            if reason in POD_BAD_WAITING:
                bad.append(f"{ref} ({cs.get('name')}: {reason})")
                break
    return bad


def nudge_flux():
    """Best-effort: force Flux to pull the just-merged commit immediately."""
    print("  health: nudging Flux to reconcile the merged commit...", file=sys.stderr)
    rc, _, err = _run([
        "flux", "reconcile", "source", "git", FLUX_GIT_SOURCE,
        "-n", FLUX_GIT_SOURCE_NS,
    ])
    if rc != 0:
        print(f"  health: flux reconcile nudge failed (continuing): {err.strip()}",
              file=sys.stderr)


def verify_cluster_health(timeout_s=HEALTH_TIMEOUT_S, poll_s=HEALTH_POLL_S):
    """Poll until the cluster settles after a merge, or timeout.

    Healthy = every non-suspended Flux Kustomization and HelmRelease is Ready=True
    AND no pod is stuck (CrashLoopBackOff / image-pull error / Failed). Returns a
    result dict; 'healthy' is False on timeout or if the cluster can't be queried."""
    deadline = time.monotonic() + timeout_s
    last = {}
    attempt = 0
    while True:
        attempt += 1
        ks_bad = _flux_not_ready("kustomizations.kustomize.toolkit.fluxcd.io")
        hr_bad = _flux_not_ready("helmreleases.helm.toolkit.fluxcd.io")
        pods_bad = _unhealthy_pods()

        if ks_bad is None or hr_bad is None or pods_bad is None:
            return {
                "healthy": False,
                "error": "could not query cluster (kubectl/flux unavailable?)",
                "checked_at": datetime.now(timezone.utc).isoformat(),
            }

        last = {
            "kustomizations_not_ready": ks_bad,
            "helmreleases_not_ready": hr_bad,
            "unhealthy_pods": pods_bad,
        }
        settled = not (ks_bad or hr_bad or pods_bad)
        remaining = deadline - time.monotonic()

        if settled:
            print(f"  health: cluster settled (poll #{attempt}).", file=sys.stderr)
            return {
                "healthy": True,
                "checked_at": datetime.now(timezone.utc).isoformat(),
                **last,
            }
        if remaining <= 0:
            print(f"  health: TIMED OUT after {timeout_s}s; cluster not settled.",
                  file=sys.stderr)
            for label, items in (
                ("Kustomizations", ks_bad), ("HelmReleases", hr_bad), ("Pods", pods_bad)
            ):
                for x in items:
                    print(f"    not-ready {label[:-1]}: {x}", file=sys.stderr)
            return {
                "healthy": False,
                "error": f"cluster did not settle within {timeout_s}s",
                "checked_at": datetime.now(timezone.utc).isoformat(),
                **last,
            }

        pending = len(ks_bad) + len(hr_bad) + len(pods_bad)
        print(f"  health: {pending} resource(s) not ready, "
              f"{int(remaining)}s left; re-checking in {poll_s}s...", file=sys.stderr)
        time.sleep(min(poll_s, max(1, remaining)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--merge-safe", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--out", help="write triage.json to this path (default: stdout)")
    parser.add_argument("--verify-health", action="store_true",
                        help="only run the cluster health check (skip triage/merge)")
    parser.add_argument("--skip-health-check", action="store_true",
                        help="merge but don't wait for the cluster to settle")
    parser.add_argument("--health-timeout", type=int, default=HEALTH_TIMEOUT_S,
                        help=f"seconds to wait for the cluster to settle (default {HEALTH_TIMEOUT_S})")
    args = parser.parse_args()

    # Standalone health check — no triage, no merge.
    if args.verify_health:
        result = verify_cluster_health(timeout_s=args.health_timeout)
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["healthy"] else 1)

    prs = fetch_prs(args.repo)
    renovate_prs = [p for p in prs if is_renovate(p)]

    buckets = {"safe": [], "waiting": [], "review": [], "blocked": []}
    for pr in renovate_prs:
        bucket, entry = bucket_pr(pr)
        buckets[bucket].append(entry)

    result = {
        "repo": args.repo,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        **buckets,
    }

    out_json = json.dumps(result, indent=2)
    if args.out:
        with open(args.out, "w") as f:
            f.write(out_json)
        print(f"Wrote {args.out}")
    else:
        print(out_json)

    if args.merge_safe:
        safe = buckets["safe"]
        merged_any = False
        if not safe:
            print("\nNo safe PRs to merge.", file=sys.stderr)
        else:
            label = "[dry-run] " if args.dry_run else ""
            print(f"\n{label}Merging {len(safe)} safe PR(s)...", file=sys.stderr)
            for pr in safe:
                n = pr["number"]
                print(f"\n  PR #{n}: {pr['title']}", file=sys.stderr)
                print(f"  Reason: {pr['reason']}", file=sys.stderr)
                ok = run_gh_merge(n, args.repo, args.dry_run)
                if ok and not args.dry_run:
                    merged_any = True
                if not ok:
                    print(f"  WARNING: failed to merge #{n}, continuing", file=sys.stderr)

        # Verify the cluster settles before declaring the run complete.
        # Only after a real merge: dry-runs change nothing, and --skip-health-check
        # opts out explicitly.
        if merged_any and not args.skip_health_check:
            print("\nVerifying cluster health after merge...", file=sys.stderr)
            nudge_flux()
            health = verify_cluster_health(timeout_s=args.health_timeout)
            print(f"\nCluster health: {'OK' if health['healthy'] else 'DEGRADED'}",
                  file=sys.stderr)
            if not health["healthy"]:
                print(json.dumps(health, indent=2), file=sys.stderr)
                # Non-zero exit so the paired completion-notification step can branch
                # on success vs. a cluster that didn't settle.
                sys.exit(1)
        elif merged_any and args.skip_health_check:
            print("\nSkipping cluster health check (--skip-health-check).",
                  file=sys.stderr)


if __name__ == "__main__":
    main()
