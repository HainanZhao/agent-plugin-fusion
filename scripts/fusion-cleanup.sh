#!/usr/bin/env bash
#
# fusion-cleanup.sh — Remove the worktrees and throwaway branches created by a
# fusion run (or all of them).
#
# Usage:
#   fusion-cleanup.sh <RUNID>   # clean one run
#   fusion-cleanup.sh --all     # clean every fusion/* worktree and branch
#
set -uo pipefail

die() { printf 'fusion-cleanup: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository."
WT_BASE="${FUSION_WORKTREE_DIR:-${TMPDIR:-/tmp}/fusion-wt}"

TARGET="${1:-}"
[ -n "$TARGET" ] || die "usage: fusion-cleanup.sh <RUNID|--all>"

# Pick the branch filter.
if [ "$TARGET" = "--all" ]; then
  filter="refs/heads/fusion/"
  echo "Cleaning ALL fusion runs…"
else
  filter="refs/heads/fusion/$TARGET/"
  echo "Cleaning fusion run $TARGET…"
fi

# Remove worktrees whose branch matches, then delete the branches.
while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  # Find the worktree path bound to this branch, if any.
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

git -C "$REPO_ROOT" worktree prune

# Remove the scratch worktree base + run artifacts.
if [ "$TARGET" = "--all" ]; then
  rm -rf "$WT_BASE" "$REPO_ROOT/.fusion/runs"
else
  rm -rf "${WT_BASE:?}/$TARGET" "$REPO_ROOT/.fusion/runs/$TARGET"
fi

echo "Done."
