# Hermes Agent — Carried Patch: Per-User USER.md

`hermes-agent` runs a small **upstream patch that is not in the published image**.
This document explains what it does, how to upgrade the image without breaking it,
and how to remove it once upstream ships the change.

- **Upstream issue:** [NousResearch/hermes-agent#27182](https://github.com/NousResearch/hermes-agent/issues/27182)
- **Upstream PR:** [#27183](https://github.com/NousResearch/hermes-agent/pull/27183) — open, unmerged as of 2026-09-03
- **Manifests:** `kubernetes/apps/ai/hermes-agent/app/`
  (`configmap-memory-patch.yaml`, `helmrelease.yaml`)
- **Pre-merge check:** `task validate:hermes-patch`

## Why the patch exists

Hermes keeps two built-in memory files under its home directory:

| File | Scope | Contents |
|------|-------|----------|
| `MEMORY.md` | global | what the agent has learned |
| `USER.md` | **was** global | who the user is and how they want things done |

Both are injected into every conversation's system prompt. The Mattermost adapter here
runs with `MATTERMOST_ALLOW_ALL_USERS=true`, so every person in the team shares one
`USER.md` — one person's stated preferences end up in everyone else's prompt. That is
preference contamination and a mild privacy leak.

The patch partitions `USER.md` per platform identity:

- identity present → `memories/users/<safe_key>/USER.md`
- no identity (TUI, cron, one-shot) → the original global `memories/USER.md`
- `MEMORY.md` stays global — shared agent knowledge is intentional

`<safe_key>` is `<platform>-<id>` for filesystem-safe identifiers (Mattermost/Slack ids,
numeric Telegram ids). Anything else — emails, unicode handles, hostile values like
`../../etc` — collapses to a stable `h-<sha256[:20]>` digest, so a platform-supplied
identifier can never contribute a raw path component.

Fully backward compatible: the new parameters default to `None`, so every call site
without an identity behaves exactly as before.

## How it is carried

`/opt/hermes` is immutable in the published image, so nothing is rewritten in place:

1. `configmap-memory-patch.yaml` holds the upstream diff (upstream's test file stripped —
   the image ships no test runner).
2. The `patch-memory` initContainer copies the three touched source files
   (`tools/memory_tool.py`, `agent/agent_init.py`, `gateway/slash_commands.py`) out of the
   image onto an `emptyDir`, applies the diff there, then greps the result to catch a
   patch that applied with fuzz but landed in the wrong place.
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

The check below is what keeps the fail-closed design safe. Run it **before** merging any
tag bump.

```sh
# 1. Bump the tag — one edit; the anchor propagates it to all three containers.
$EDITOR kubernetes/apps/ai/hermes-agent/app/helmrelease.yaml

# 2. Dry-run the carried patch against the new image, inside the cluster.
#    Needs a working KUBECONFIG; run from the main checkout, or export one.
task validate:hermes-patch
```

The task spins a throwaway pod on the newly pinned tag, applies the diff to a copy of the
three files, and deletes the pod. Green means the upgrade is safe to merge. It is also
part of `task validate:preflight` and `task validate:all`.

If it fails, the patch no longer matches upstream's code. Either:

```sh
# Regenerate the diff from the PR, drop the tests hunk, re-embed under
# data."27183-per-user-usermd.diff" in configmap-memory-patch.yaml.
gh pr diff 27183 --repo NousResearch/hermes-agent
```

…or, if #27183 has landed upstream, remove the patch entirely (below). Re-run the task
until it is green, then merge.

## Removing the patch once upstream merges

1. Confirm the release actually contains it — `safe_user_key` should exist in
   `tools/memory_tool.py` in the new image.
2. **Compare the merged key scheme against ours.** If upstream changed the path layout or
   the key format (for example dropped the `<platform>-` qualification, or hashed
   differently), the existing per-user directories become orphaned — the data is still
   on the PVC, but the agent will look elsewhere and users appear to have "forgotten".
   Rename the directories under `memories/users/` to the new scheme before cutting over.
3. Delete `configmap-memory-patch.yaml`, its `kustomization.yaml` entry, the
   `patch-memory` initContainer, and the `hermes-patch` / `hermes-patch-src` volumes.
   Keep the anchored `image:` block.
4. Delete `.taskfiles/validate/scripts/validate-hermes-patch.sh` and its
   `validate:hermes-patch` task entries. (The script already self-skips with a green
   result if the ConfigMap is gone, so ordering here is forgiving.)
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
