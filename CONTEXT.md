# Home Ops

A GitOps-managed home lab cluster and the AI agents that work on it and alongside it.

## Language

### Agent work

**Workbench**:
The always-on remote Orca server in the cluster where most agent work lives; it keeps sessions running while no client is connected.
_Avoid_: agentbox, remote box, dev pod

**Client**:
An Orca desktop or mobile app paired to the Workbench; it holds no work of its own for remote workspaces.
_Avoid_: frontend, viewer

**Mac**:
The user's local machine, which is also a host for sensitive agent work that must not run on the Workbench.
_Avoid_: desktop (ambiguous with the Orca desktop Client), local

**Agent account**:
The non-human identity (jarvis) that agents commit, push and open PRs under, never the user's own account.
_Avoid_: bot, service user

**Credential gate**:
The approval step an agent session must pass before it can read secrets from the homeops vault.
_Avoid_: unlock, op access

### Storage

**Working copy**:
A git checkout or worktree on the Workbench; disposable, because anything worth keeping is pushed to a remote.
_Avoid_: project storage, repo backup

**Vault**:
The lifeOS knowledge base: Obsidian-format markdown that agents treat as plain files; Obsidian is only one viewer of it, not its interface.
_Avoid_: Obsidian (the app), notes repo

**Vault history**:
The git record of the Vault, kept outside the Vault folder and pushed to Forgejo; a backup that any host may add to, never the means by which devices stay in sync.
_Avoid_: vault backup, obsidian-git, vault sync

**Land**:
To apply a branch's changes onto the live Vault folder, refusing if any affected file changed since the branch began.
_Avoid_: merge, pull (both imply git writing the Vault folder freely)

**Synced share**:
A folder replicated between iCloud (via the Mac) and the NAS by Syncthing, which the Workbench reads and writes in place over NFS.
_Avoid_: NFS share, iCloud folder
