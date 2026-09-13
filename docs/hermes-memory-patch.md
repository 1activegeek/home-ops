# Hermes Agent — Carried Patch: Per-User USER.md

`hermes-agent` runs a small **upstream patch that is not in the published image**.
This document explains what it does, how to upgrade the image without breaking it,
and how to remove it once upstream ships the change.

- **Upstream issue:** [NousResearch/hermes-agent#27182](https://github.com/NousResearch/hermes-agent/issues/27182)
- **Upstream PR:** [#27183](https://github.com/NousResearch/hermes-agent/pull/27183) — open, unmerged as of 2026-09-13
- **Manifests:** `kubernetes/apps/ai/hermes-agent/app/`
  (`patches/27183-per-user-usermd.diff`, `kustomization.yaml`, `helmrelease.yaml`)
- **Tooling:** `scripts/hermes-patch/` — `verify.sh`, `regen.sh`, `smoke_test.py`
- **Pre-merge check:** `task validate:hermes-patch`, and automatically in CI via
  `.github/workflows/hermes-patch.yaml`

## Why the patch exists

Hermes keeps two built-in memory files under its home directory:

| File | Scope | Contents |
|------|-------|----------|
| `MEMORY.md` | global | what the agent has learned |
| `USER.md` | **was** global | who the user is and how they want things done |

Both are injected into every conversation's system prompt. Without the patch every
person on a platform shares one `USER.md` — one person's stated preferences end up in
everyone else's prompt. That is preference contamination and a mild privacy leak.

It was written when the Mattermost adapter ran with `MATTERMOST_ALLOW_ALL_USERS=true`
and anyone in the team could reach the bot. Mattermost is decommissioned and Matrix
access is allowlisted to one user, so the patch currently guards nothing in practice —
it is what makes widening `MATRIX_ALLOWED_USERS` safe, and stays for that reason.

The patch partitions `USER.md` per platform identity:

- identity present → `memories/users/<safe_key>/USER.md`
- no identity (TUI, cron, one-shot) → the original global `memories/USER.md`
- `MEMORY.md` stays global — shared agent knowledge is intentional

`<safe_key>` is `<platform>-<id>` for filesystem-safe identifiers (Slack ids, numeric
Telegram ids). Anything else — emails, Matrix MXIDs, unicode handles, hostile values like
`../../etc` — collapses to a stable `h-<sha256[:20]>` digest, so a platform-supplied
identifier can never contribute a raw path component.

**One deliberate deviation from the upstream PR:** `safe_user_key` normalizes
`platform` through `.value` before using it. `agent_init` passes a plain string
(`"matrix"`) while the gateway passes a `Platform` enum, and `str(Platform.MATRIX)` is
`"Platform.MATRIX"` — without the normalization the live agent and the `/memory`
approval path derive *different* keys for the same person and their `USER.md` silently
forks in two. `smoke_test.py` asserts the two agree.

Fully backward compatible: the new parameters default to `None`, so every call site
without an identity behaves exactly as before.

## How it is carried

`/opt/hermes` is immutable in the published image, so nothing is rewritten in place:

1. `patches/27183-per-user-usermd.diff` holds the upstream diff (upstream's test file
   stripped — the image ships no test runner). It is a real file, rendered into the
   `hermes-memory-patch` ConfigMap by the `configMapGenerator` in `kustomization.yaml`,
   so it can be regenerated, reviewed and CI-tested as a diff rather than hand-maintained
   inside a YAML literal block.
2. The `patch-memory` initContainer copies the four touched source files
   (`tools/memory_tool_store.py`, `tools/memory_tool.py`, `agent/agent_init.py`,
   `gateway/slash_commands.py`) out of the image onto an `emptyDir`, applies the diff
   there, then greps the result to catch a patch that applied with fuzz but landed in the
   wrong place.
3. The patched copies are mounted back over their original paths in the `gateway` and
   `dashboard` containers via `subPath`.

Nothing is written to the image or to the data PVC. All three containers share one
anchored `image:` block (`&image` / `*image`) so a tag bump cannot half-apply — copying
source out of one release and running it under another would be silently wrong.

**The initContainer fails closed.** If the patch stops applying, the pod does not start.
Because the Deployment strategy is `Recreate`, that means an outage rather than a
silently-unpatched agent that quietly re-merges everyone's memory. That trade is
deliberate: the failure is loud, predictable, and entirely under our control, because it
can only happen on a tag bump we make.

## Upgrading the image

**This is gated in CI.** `.github/workflows/hermes-patch.yaml` runs the verification on
every PR touching `kubernetes/apps/ai/hermes-agent/**`, so a Renovate bump that breaks
the patch turns the check red instead of the pod. That also keeps it out of
`scripts/renovate-triage/triage.py --merge-safe`, which only auto-merges PRs whose checks
are green — which is precisely what went wrong on 2026-09-13 (below).

The same script backs `task validate:hermes-patch`, part of `task validate:preflight`
and `task validate:all`. It uses docker when a daemon is up (what CI does) and a
throwaway pod in the cluster otherwise.

```sh
# 1. Bump the tag — one edit; the anchor propagates it to all three containers.
$EDITOR kubernetes/apps/ai/hermes-agent/app/helmrelease.yaml

# 2. Apply + behaviour-test the carried patch against the new image.
task validate:hermes-patch            # or: scripts/hermes-patch/verify.sh
```

Verification runs the initContainer's *own* script, extracted from `helmrelease.yaml`
rather than copied, so the check and the deployment can never drift. It then mounts the
patched files the way the Deployment does and runs `scripts/hermes-patch/smoke_test.py`
against them: partitioned vs global paths, `Platform` enum/string agreement, `MEMORY.md`
staying global, and path-traversal resistance. Static greps only prove the patch landed;
the smoke test proves it still *means* the same thing.

### When the check goes red

The diff is generated against one release's source, so an upstream refactor breaks it.
Forward-port it with a real 3-way merge rather than re-deriving it by hand:

```sh
# base = <old-tag> sources, ours = base + current diff, theirs = <new-tag> sources
scripts/hermes-patch/regen.sh v2026.9.11 v2026.10.02

# If it reports a conflict, resolve the markers in the work dir it names, then:
scripts/hermes-patch/regen.sh --emit <work-dir>

# Always finish here — a clean merge is not proof the patch is still correct.
scripts/hermes-patch/verify.sh
```

If `regen.sh` reports that a targeted file **no longer exists**, upstream moved the code
and no merge can find its new home — port it by hand (the script leaves the extracted
sources for you) and update the file list in the initContainer's copy commands, its
post-apply greps, and the `hermes-patch` mounts in `helmrelease.yaml`.

If #27183 has landed upstream, remove the patch entirely (below) instead.

### Prior art: the 2026-09-13 outage

Renovate PR #580 bumped `v2026.8.31 ➔ v2026.9.11` and was swept into a batch merge by
the triage script. That release split `MemoryStore` out of `tools/memory_tool.py` into
the new `tools/memory_tool_store.py` and reworked the imports; every hunk failed, the
initContainer hard-failed as designed, and hermes-agent sat in `Init:CrashLoopBackOff`
for about four hours. The check to prevent it already existed as
`task validate:hermes-patch` — but it needed cluster access, so it had never run in CI,
and nothing forced anyone to run it locally. Hence the docker backend and the workflow.

## Removing the patch once upstream merges

1. Confirm the release actually contains it — `safe_user_key` should exist in
   `tools/memory_tool_store.py` in the new image.
2. **Compare the merged key scheme against ours.** If upstream changed the path layout or
   the key format (for example dropped the `<platform>-` qualification, or hashed
   differently), the existing per-user directories become orphaned — the data is still
   on the PVC, but the agent will look elsewhere and users appear to have "forgotten".
   Rename the directories under `memories/users/` to the new scheme before cutting over.
3. Delete the `patches/` directory, the `configMapGenerator` block in
   `kustomization.yaml`, the `patch-memory` initContainer, and the `hermes-patch` /
   `hermes-patch-src` volumes and their mounts. Keep the anchored `image:` block.
4. Delete `scripts/hermes-patch/`, `.taskfiles/validate/scripts/validate-hermes-patch.sh`
   and its `validate:hermes-patch` task entries, and
   `.github/workflows/hermes-patch.yaml`. (`verify.sh` already self-skips with a green
   result once `patches/` is gone, so ordering here is forgiving.)
5. Delete this document.

## What survives an upgrade

Everything stateful. `HERMES_HOME` is the Longhorn PVC, and an image bump only replaces
the code in `/opt/hermes`:

- `memories/` — `MEMORY.md` and every per-user `users/<safe_key>/USER.md`
- `auth.json` — the interactively-obtained provider credential (not re-authed on upgrade)
- `config.yaml`, `SOUL.md`, `cron/`, profiles, skills, caches

The PVC is on the `longhorn` storage class, which is in the `default` recurring-job
group: 6-hourly snapshots (retain 8), daily backups (retain 7), weekly (retain 4).
See `docs/longhorn-backup-restore.md`.

Two things worth knowing:

- **Per-user files start empty.** The pre-existing global `USER.md` is no longer injected
  for identified users, so each person's profile re-accumulates from scratch. It holds
  one trivial entry today, so there is nothing worth migrating.
- **Rolling back the patch is non-destructive.** Without it the agent falls back to the
  global `USER.md`; the per-user directories stay on disk, just unread, and are picked up
  again if the patch returns.

The genuine upgrade risk is not data loss — it is a `config.yaml` on the PVC drifting
behind new upstream defaults. That is unrelated to this patch.

## Verifying after deploy

```sh
# The initContainer's confirmation line
kubectl -n ai logs deploy/hermes-agent -c patch-memory

# Per-user partitions appear after each user's first remembered preference
kubectl -n ai exec deploy/hermes-agent -c gateway -- ls /opt/data/memories/users
```
