#!/usr/bin/env python3
"""Renovate PR triage engine for 1activegeek/home-ops.

Classifies open Renovate PRs by type label + CI status and outputs triage.json.
Optionally approves and squash-merges the safe bucket.

Release-age burn-in is enforced upstream by Renovate via `minimumReleaseAge`
(.renovaterc.json5), which measures age from the datasource's release timestamp
and keeps a PR hidden until it ages past the threshold. So any PR this script
sees has already passed burn-in; it only needs to gate on type + CI status.
PR age is reported for context but is no longer a merge gate.

Usage:
  triage.py                        # report mode, JSON to stdout
  triage.py --out triage.json      # write to file
  triage.py --merge-safe           # approve+merge safe PRs
  triage.py --merge-safe --dry-run # print gh commands, don't run
  triage.py --repo owner/repo      # override repo
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone

REPO = "1activegeek/home-ops"

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
    if pr["author"]["login"] in ("app/renovate", "renovate[bot]", "renovate"):
        return True
    return any(l["name"].startswith("renovate/") for l in pr["labels"])


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
    """PR age in days. Informational only — release-age burn-in is enforced
    upstream by Renovate's minimumReleaseAge, not by this number."""
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
        if ci == "green":
            entry["reason"] = f"{update_type}, all checks green (burn-in passed upstream)"
            return "safe", entry
        entry["reason"] = f"checks {ci}"
        return "waiting", entry

    entry["reason"] = "unknown update type; manual review needed"
    return "review", entry


def run_gh_merge(pr_number, repo, dry_run):
    approve_cmd = ["gh", "pr", "review", str(pr_number), "--approve", "-R", repo]
    merge_cmd = ["gh", "pr", "merge", str(pr_number), "-R", repo, "--squash", "--delete-branch"]
    if dry_run:
        print(f"  [dry-run] {' '.join(approve_cmd)}")
        print(f"  [dry-run] {' '.join(merge_cmd)}")
        return True
    print(f"  Approving PR #{pr_number}...")
    r1 = subprocess.run(approve_cmd, capture_output=True, text=True)
    if r1.returncode != 0:
        print(f"  Approve failed: {r1.stderr.strip()}", file=sys.stderr)
        return False
    print(f"  Merging PR #{pr_number}...")
    r2 = subprocess.run(merge_cmd, capture_output=True, text=True)
    if r2.returncode != 0:
        print(f"  Merge failed: {r2.stderr.strip()}", file=sys.stderr)
        return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--merge-safe", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--out", help="write triage.json to this path (default: stdout)")
    args = parser.parse_args()

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
                if not ok:
                    print(f"  WARNING: failed to merge #{n}, continuing", file=sys.stderr)


if __name__ == "__main__":
    main()
