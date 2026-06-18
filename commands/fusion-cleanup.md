---
description: Remove the git worktrees and throwaway branches created by fusion runs.
argument-hint: "<RUN_ID> | --all"
---

# Fusion cleanup

Remove the scratch worktrees, throwaway `fusion/*` branches, and captured
artifacts from a fusion run.

Target: **$ARGUMENTS** (a run id, `--all` for every fusion run, or `--stale [HRS]`
for only abandoned runs older than HRS).

> Cleanup is normally **automatic**: `/fusion` cleans its own run when it finishes,
> and a SessionStart hook prunes stale leftovers. Use this command for manual
> control (e.g. `--all` to wipe everything, or to clean a kept run).

1. If `$ARGUMENTS` is empty, list existing runs so the user can choose:
   - `git worktree list` (look for paths under the fusion worktree base)
   - `ls .fusion/runs 2>/dev/null`
   - `git for-each-ref --format='%(refname:short)' refs/heads/fusion/`
   Then ask which run id to clean (or `--all`).

2. Run the cleanup script:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fusion-cleanup.sh" $ARGUMENTS
```

3. Confirm what was removed.
