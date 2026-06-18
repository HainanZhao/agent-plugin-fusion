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
WT_BASE="${FUSION_WORKTREE_DIR:-${TMPDIR:-/tmp}/fusion-wt}"
RUNS_DIR="$REPO_ROOT/.fusion/runs"

# Clean a single run id: its worktrees, branches, and artifacts.
clean_run() {
  local runid="$1"
  local filter="refs/heads/fusion/$runid/"
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    local wt
    wt="$(git -C "$REPO_ROOT" worktree list --porcelain \
          | awk -v b="refs/heads/$branch" '
              /^worktree /{p=$2}
              /^branch /{if($2==b) print p}')"
    if [ -n "$wt" ]; then
      git -C "$REPO_ROOT" worktree remove --force "$wt" 2>/dev/null \
        && echo "  removed worktree $wt"
    fi
    git -C "$REPO_ROOT" branch -D "$branch" >/dev/null 2>&1 \
      && echo "  deleted branch $branch"
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "$filter")
  rm -rf "${WT_BASE:?}/$runid" "$RUNS_DIR/$runid"
}

case "$TARGET" in
  --all)
    echo "Cleaning ALL fusion runs…"
    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      wt="$(git -C "$REPO_ROOT" worktree list --porcelain \
            | awk -v b="refs/heads/$branch" '
                /^worktree /{p=$2}
                /^branch /{if($2==b) print p}')"
      [ -n "$wt" ] && git -C "$REPO_ROOT" worktree remove --force "$wt" 2>/dev/null \
        && echo "  removed worktree $wt"
      git -C "$REPO_ROOT" branch -D "$branch" >/dev/null 2>&1 \
        && echo "  deleted branch $branch"
    done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads/fusion/)
    git -C "$REPO_ROOT" worktree prune
    rm -rf "$WT_BASE" "$RUNS_DIR"
    echo "Done."
    ;;

  --stale)
    hours="${2:-${FUSION_STALE_HOURS:-6}}"
    [ -d "$RUNS_DIR" ] || exit 0
    # Run dirs untouched for more than $hours are considered abandoned.
    mapfile -t stale < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d \
                          -mmin "+$((hours * 60))" -printf '%f\n' 2>/dev/null)
    [ "${#stale[@]}" -gt 0 ] || exit 0
    echo "fusion: pruning ${#stale[@]} stale run(s) (>${hours}h old)…" >&2
    for runid in "${stale[@]}"; do
      clean_run "$runid"
    done
    git -C "$REPO_ROOT" worktree prune
    ;;

  *)
    echo "Cleaning fusion run $TARGET…"
    clean_run "$TARGET"
    git -C "$REPO_ROOT" worktree prune
    echo "Done."
    ;;
esac
