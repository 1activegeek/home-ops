# Workbench build plan

The Workbench is an always-on remote Orca server in the `ai` namespace. It is the main place agent work happens, and Orca desktop and mobile apps connect to it as clients. It replaces agentbox. Terms are defined in [CONTEXT.md](../CONTEXT.md), and the reasoning behind the decisions is in [ADR 0001](adr/0001-git-never-writes-the-vault-folder.md), [ADR 0002](adr/0002-infra-sensitive-work-stays-on-the-mac.md) and [ADR 0003](adr/0003-workbench-replaces-agentbox.md).

## Decisions

### Image
- A public image, `ghcr.io/1activegeek/workbench:<orca-version>-<build>`, built from the Orca Linux `.deb` in the `1activegeek/workbench-image` repo.
- It contains Claude Code, `op`, `kubectl`, `flux`, `gh`, `agent-git`, a Linux port of `claude-sa`, and Chromium with Playwright MCP. Xvfb is installed only as the fallback dependency for Orca's Electron runtime. There is no Obsidian app and no desktop environment.
- **Nothing personal goes into the image.** CI fails the build if it finds personal identifiers or 1Password references. Personal configuration is copied onto the home volume on first boot.

### Updates
- Renovate bumps Orca and the image's tools, grouped into one PR per night. These PRs auto-merge with no burn-in, inside a nightly window, in both the image repo and home-ops.
- The home-ops Renovate rule overrides the normal weekly schedule and the 3-day burn-in. `scripts/renovate-triage` skips these PRs.

### Runtime
- Process tree: tini → `orca-ide serve --supervise --port 6768 --no-pairing`.
- A liveness probe on the serve port. No PodDisruptionBudget and no node pinning. Strategy is Recreate.
- Resources: requests 2 CPU / 4 Gi, limits 8 CPU / 12 Gi. An alert fires when memory stays above 80%.
- `DO_NOT_TRACK=1`. The Orca relay and push notifications are not used.
- A pod restart kills running agents. Projects and tabs are restored from the home volume, and conversations continue with `claude --resume`.

### Access
- Tailscale runs inside the pod in userspace mode, as `tag:workbench`, with Tailscale SSH enabled. It **never accepts subnet routes.**
- The ACL allows only the user's devices, on the serve port and SSH.
- Pairing is done from a Workbench shell, so pairing links never appear in pod logs.
- There is no Kubernetes Service and no HTTPRoute.

### Storage
- **Home volume** on `longhorn` (backed up). It holds Claude and Orca state and the Workbench's CLAUDE.md and settings, edited live. Baseline config is seeded only when a file is missing.
- **Working copies** on a `longhorn-nobackup` volume. They are disposable, because their contents are pushed to a remote.
- **Synced shares** mounted read-write over NFS: the Vault and the shared documents.

### Secrets
- A dedicated 1Password service account on the homeops vault, so the Workbench can be revoked without affecting the Mac.
- Credentials are mounted as tmpfs files and are never put in environment variables. This covers the service-account token, the agent git SSH keys and tokens, and the Workbench SSH keypair used for the NAS and the network gateway.
- `claude-sa` keeps its interface: unlock with the user's approval, then `run`, `read` and `status`. Claude deny rules cover the token path.
- Claude Code authenticates with an interactive `/login` that persists on the home volume.

### Git
- Agents commit as the agent account through `agent-git`, to branches and PRs only.
- A ruleset on `main` requires a PR and blocks force-push. The owner and Renovate can bypass it.

### Vault
Git never writes the Vault folder (ADR 0001).
- All hosts commit with `vault-commit`: fetch, `reset --mixed` onto the remote, stage only what changed, commit, push, and retry if the push is rejected.
- Branches are Landed with `vault-land`, which applies the branch's diff with a 3-way apply and refuses if an affected file changed underneath it.
- Vault PRs are never merged in the Forgejo UI.
- Claude deny rules block `pull`, `merge`, `checkout`, `stash` and `reset --hard` in the Vault.
- The Mac keeps its periodic snapshot, which runs through `vault-commit`. The Workbench commits only after agent tasks.

### Cluster and network
- A read-only ClusterRole over every resource except Secrets, plus `pods/log`. No `exec` and no `port-forward`. The service-account token is mounted only for this role.
- Cilium egress allows:
  - the internet,
  - the kube-apiserver and kube-dns,
  - Forgejo and the internal gateway,
  - the NAS on NFS, the DSM API and SSH,
  - the network controller API and SSH to the gateway.
- Everything else on the LAN is denied.
- Widening any of this follows `docs/workbench.md`.

### Mac-only
- Node, Talos and cluster-upgrade work.
- Claude in Chrome.
- The Workbench never connects into the Mac (ADR 0002).

## Units

| # | Unit | Depends on | Done when |
|---|---|---|---|
| U0 | GitHub ruleset on `main` (the user applies it) | none | The ruleset is active |
| U1 | Move `longhorn-nobackup` into `longhorn-system` | none | Merged, and Flux is Ready |
| U2 | `workbench-image` repo, CI, personal-data check, Renovate | none | The image is published, and a smoke test shows `orca-ide serve` binding |
| U3 | 1Password items for the Workbench | the user's service account and Tailscale key | `task validate:secrets` passes |
| U4 | `ai/workbench` app and `docs/workbench.md` | U1, U2, U3 | Merged, the pod is Running, the policy is enforced |
| U5 | `vault-commit` / `vault-land` and the deny rules | none | Tested against a scratch clone, never the live Vault |
| U6 | Remove agentbox | U4 has run for about a week | A draft PR exists |

Steps that need the user after deploy:
- Install the Workbench public key on the NAS and the gateway.
- Claude `/login` and Orca pairing.
- Switch the Mac's snapshot to `vault-commit`.
- Run the restart and resume test, and record the result in `docs/workbench.md`.
