# Git never writes the Vault folder

The Vault folder is kept in sync between devices by iCloud and Syncthing, and git history is only a backup. Any host can add to that history, but git must never write the Vault folder, because a `pull`, `merge`, `checkout`, `stash` or `reset --hard` could overwrite an edit from another device that hasn't arrived yet, and Syncthing would then spread the older version everywhere. Hosts commit by adopting the remote history without touching files (`fetch` then `reset --mixed`) and staging only what changed. Branch work is Landed by applying just that branch's diff, which refuses to run if an affected file changed underneath it. Vault pull requests are never merged in the Forgejo UI. A UI merge would move the history without changing the files, so the next snapshot would silently revert it.

## Considered Options

- **The Workbench is the only host that commits to master.** Rejected because commits really do come from both the Mac and the Workbench.
- **Pull before committing.** Rejected because a pull writes the folder that is being synced.
- **One branch per host.** Rejected because it's a lot of extra ceremony for a backup.

## Consequences

This rule holds only while iCloud, Syncthing and git all share the same data. If the Vault moves to a single sync mechanism, revisit it.
