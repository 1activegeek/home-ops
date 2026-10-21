# Workbench runbook

The Workbench is the always-on remote Orca server in the `ai` namespace. Orca desktop and mobile apps connect to it as clients, and it is reachable only over the tailnet. The design is in [workbench-plan.md](workbench-plan.md), and the vocabulary is in [CONTEXT.md](../CONTEXT.md).

- **Image:** `ghcr.io/1activegeek/workbench`, built from the `1activegeek/workbench-image` repo. Tags are `<orca-version>.<build>`.
- **Auth mode:** no route and no Service. Clients reach it through its own tailnet node, and the tailnet ACL decides who can connect. Orca pairing adds a revocable token for each client device.

## Daily operation

| Task | How |
|---|---|
| Shell into the Workbench | `tailscale ssh workbench@workbench` from a tailnet device |
| Pair a new client | From a Workbench shell, run `orca-ide serve --mobile-pairing`, or generate a link with the Orca CLI. Never pair through pod logs. |
| Revoke a client | Orca → Settings → Remote Orca Servers → Shared Server Access |
| Log Claude Code in again | Run `claude` in a Workbench shell, then `/login` |
| Resume an interrupted agent | Orca session history → **Copy resume command**, then run it in a Workbench terminal |
| Edit global agent config | Edit `~/.claude/CLAUDE.md` and `~/.claude/settings.json` in place. They live on the home volume, are never overwritten, and take effect without a restart. |
| Emergency credential kill | Revoke the Workbench's 1Password service account. The Mac's account keeps working. |

## Updates and restarts

- Renovate merges Orca and tool bumps into the image repo nightly, and the new image deploys inside the overnight window. Neither has a burn-in period.
- If `orca-ide serve` crashes, the entrypoint restarts it. Running agents survive this, because Orca's terminal host outlives `serve`.
- If the pod restarts, every running agent process dies. Projects, worktrees and tabs come back from the home volume, and conversations continue with `claude --resume`.
- There is no PodDisruptionBudget, so node drains and Talos upgrades move the pod freely.

## Widening access

Every widening is a reviewed PR. Record why it's needed in the PR description.

### Cluster RBAC (`app/rbac.yaml`)

| Tier | Grants | Status |
|---|---|---|
| 0 | Read everything except Secrets, plus `pods/log` | **current** |
| 1 | Add `pods/exec` in named namespaces (a namespaced Role and RoleBinding) | needs a PR |
| 2 | Add `pods/portforward` or Secret read in named namespaces | needs a PR, and isn't recommended |
| — | Cluster writes | **never**. Changes go through git and Flux. |

To read a CRD group that isn't listed yet, add the group to the second rule in `workbench-read`.

### Network egress (`app/ciliumnetworkpolicy.yaml`)

- **A new in-cluster app:** prefer reaching it through its internal route, which is already allowed. Add a `toEndpoints` rule only for apps without a route.
- **A new LAN host:** add a `toCIDR` rule with an explicit port list. Never widen the internet rule's exceptions.
- **Node, Talos and cluster-upgrade access stays Mac-only** ([ADR 0002](adr/0002-infra-sensitive-work-stays-on-the-mac.md)).
- **Tailscale:** the Workbench node never accepts subnet routes. Accepting them would route around this policy.

### SSH

- The Workbench has its own keypair for NAS and gateway SSH; the user's personal keys are never used.
- To grant access to a new host: install the Workbench public key there, add a `Host` block to the entrypoint, and open the port in the egress policy.

## Vault rules

Git never writes the Vault folder ([ADR 0001](adr/0001-git-never-writes-the-vault-folder.md)):
- Commit with `vault-commit`.
- Land branches with `vault-land`.
- Never merge vault PRs in the Forgejo UI.

## Verification log

| Check | Result |
|---|---|
| Pod restart: projects and tabs restored | pending first deploy |
| Pod restart: agents auto-resumed by Orca | pending (expected: manual resume) |
| Egress: internet allowed; LAN admin UIs and other namespaces denied | pending |
| RBAC: Secrets denied, `pods/log` allowed, `exec` denied | pending |
