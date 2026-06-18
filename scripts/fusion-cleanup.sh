#!/usr/bin/env bash
#
# fusion-cleanup.sh — Remove the worktrees and throwaway branches created by
# fusion runs.
#
# Usage:
#   fusion-cleanup.sh <RUNID>        # clean one run
#   fusion-cleanup.sh --all          # clean every fusion/* worktree and branch
#   fusion-cleanup.sh --stale [HRS]  # clean only runs older than HRS (default
#                                    #   $FUSION_STALE_HOURS or 6). Silent + exit
#                                    #   0 when nothing applies — safe for hooks.
#
# Layout-agnostic: worktree directories are located via git's own worktree
# records (`git worktree remove` deletes the directory), so this works no matter
# where fusion-run.sh placed them.
#
set -uo pipefail

die() { printf 'fusion-cleanup: %s\n' "$*" >&2; exit 1; }

TARGET="${1:-}"
[ -n "$TARGET" ] || die "usage: fusion-cleanup.sh <RUNID|--all|--stale [HRS]>"

# --stale must never break a session: if we're not in a repo / have no runs,
# just succeed quietly.
QUIET=0
[ "$TARGET" = "--stale" ] && QUIET=1

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  [ "$QUIET" = 1 ] && exit 0
  die "not inside a git repository."
}
RUNS_DIR="$REPO_ROOT/.fusion/runs"

# Remove the worktree bound to a branch (if any) and delete the branch.
remove_branch_worktree() {
  local branch="$1" wt
  wt="$(git -C "$REPO_ROOT" worktree list --porcelain \
        | awk -v b="refs/heads/$branch" '
            /^worktree /{p=substr($0,10)}
            /^branch /{if($2==b) print p}')"
  if [ -n "$wt" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$wt" 2>/dev/null \
      && echo "  removed worktree $wt"
  fi
  git -C "$REPO_ROOT" branch -D "$branch" >/dev/null 2>&1 \
    && echo "  deleted branch $branch"
}

# Clean every branch matching a ref prefix, then prune.
clean_filter() {
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    remove_branch_worktree "$branch"
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "$1")
  git -C "$REPO_ROOT" worktree prune
}

# Clean a single run id: its worktrees, branches, and artifacts.
clean_run() {
  clean_filter "refs/heads/fusion/$1/"
  rm -rf "$RUNS_DIR/$1"
}

case "$TARGET" in
  --all)
    echo "Cleaning ALL fusion runs…"
    clean_filter "refs/heads/fusion/"
    rm -rf "$RUNS_DIR"
    echo "Done."
    ;;

  --stale)
    hours="${2:-${FUSION_STALE_HOURS:-6}}"
    [ -d "$RUNS_DIR" ] || exit 0
    # Run dirs untouched for more than $hours are considered abandoned. Avoid
    # `mapfile` (bash 4) and `find -printf` (GNU-only) so this works on macOS
    # too; -mmin/-maxdepth are supported by both BSD and GNU find.
    found=0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if [ "$found" -eq 0 ]; then
        echo "fusion: pruning stale run(s) (>${hours}h old)…" >&2
        found=1
      fi
      clean_run "${d##*/}"
    done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d \
                  -mmin "+$((hours * 60))" 2>/dev/null)
    ;;

  *)
    echo "Cleaning fusion run $TARGET…"
    clean_run "$TARGET"
    echo "Done."
    ;;
esac
