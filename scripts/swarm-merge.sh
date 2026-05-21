#!/usr/bin/env bash
# swarm-merge.sh — merge a swarm PR and clean up the local mess.
#
# Usage:
#   swarm-merge.sh <issue#>           # resolves PR from issue, merges, cleans
#   swarm-merge.sh <issue#> --no-kill # skip the tmux-kill step
#   swarm-merge.sh --sweep-only       # just run the local-branch sweep
#
# What it does:
#   1. Resolves the PR linked to the issue.
#   2. Verifies the PR is OPEN and MERGEABLE (or already MERGED → just cleans).
#   3. cds to the MAIN worktree of the current repo (not the feature one).
#   4. Runs `gh pr merge --squash --delete-branch`. The local-delete step may
#      fail silently if the branch is checked out in a sibling worktree —
#      that's fine; we sweep it later.
#   5. Waits up to 60s for the watcher to reap the worker's worktree + tmux window.
#   6. If the iss-<N> tmux window is still alive after the grace period, kills it.
#   7. Runs the SAFER local-branch sweep: deletes `fix/issue-N` only when GitHub
#      issue N's state is CLOSED. (Never deletes branches for OPEN issues, so
#      in-flight workers stay safe.)
#   8. Reports final state.
#
# Exits 0 on success, non-zero on bailout.

set -euo pipefail

GRACE_SECONDS=60
NO_KILL=0
SWEEP_ONLY=0
ISSUE=""

# --- arg parsing -----------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --no-kill)    NO_KILL=1 ;;
    --sweep-only) SWEEP_ONLY=1 ;;
    --help|-h)
      sed -n '2,/^# Exits/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag '$arg'" >&2
      exit 2
      ;;
    *)
      [ -z "$ISSUE" ] || { echo "ERROR: multiple issue numbers given" >&2; exit 2; }
      ISSUE="$arg"
      ;;
  esac
done

# --- helpers ---------------------------------------------------------------

# `git worktree list` first row is always the main worktree.
main_worktree() {
  git worktree list --porcelain | awk '/^worktree / { print $2; exit }'
}

# Color helpers; harmless if not a tty.
c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_amber() { printf '\033[33m%s\033[0m' "$1"; }
c_dim()   { printf '\033[2m%s\033[0m' "$1"; }

# --- safer local-branch sweep ---------------------------------------------
#
# For each local `fix/issue-N` branch, look up issue N on GitHub.
# Delete the branch ONLY if the issue state is CLOSED.
# This is safer than the "remote branch absent" heuristic because a
# freshly-provisioned worker that hasn't pushed yet has an OPEN issue and
# no remote branch — we never want to delete those.
run_sweep() {
  echo "[sweep] scanning local fix/issue-* branches…"
  local deleted=0 kept_open=0 skipped=0
  for b in $(git branch --format='%(refname:short)' | grep -E '^fix/issue-[0-9]+' || true); do
    # Branch name may have a suffix (e.g. fix/issue-118-cluster-a); keep the full
    # name for deletion, but extract just the leading issue number for lookup.
    local num
    num=$(echo "$b" | grep -oE '^fix/issue-[0-9]+' | sed 's|^fix/issue-||')
    local state
    state=$(gh issue view "$num" --json state -q .state 2>/dev/null || echo "UNKNOWN")
    case "$state" in
      CLOSED)
        if git branch -D "$b" >/dev/null 2>&1; then
          echo "  $(c_green "✓") $b (issue #$num CLOSED) — deleted"
          deleted=$((deleted+1))
        else
          echo "  $(c_amber "?") $b (issue #$num CLOSED) — could not delete (still checked out?)"
        fi
        ;;
      OPEN)
        echo "  $(c_dim "·") $b (issue #$num OPEN) — keeping (worker may be in flight)"
        kept_open=$((kept_open+1))
        ;;
      *)
        echo "  $(c_dim "·") $b (issue #$num state=$state) — skipping"
        skipped=$((skipped+1))
        ;;
    esac
  done
  echo "[sweep] deleted=$deleted, kept_open=$kept_open, skipped=$skipped"
}

# --- sweep-only mode -------------------------------------------------------

if [ "$SWEEP_ONLY" = 1 ]; then
  cd "$(main_worktree)"
  run_sweep
  exit 0
fi

# --- normal mode: require an issue number ---------------------------------

if [ -z "$ISSUE" ]; then
  echo "ERROR: issue# required (or use --sweep-only)" >&2
  echo "Usage: $0 <issue#> [--no-kill]" >&2
  exit 2
fi

# Sanity: in a git repo?
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repo" >&2; exit 1; }

# cd to main worktree so gh pr merge's local-pull step has the right cwd.
MAIN_WT=$(main_worktree)
cd "$MAIN_WT"
echo "[1/7] working in main worktree: $MAIN_WT"

# Resolve PR from issue.
PR_NUM=$(gh issue view "$ISSUE" --json closedByPullRequestsReferences \
           -q '.closedByPullRequestsReferences[0].number' 2>/dev/null || echo "")
if [ -z "$PR_NUM" ] || [ "$PR_NUM" = "null" ]; then
  echo "ERROR: no linked PR found for issue #$ISSUE" >&2
  exit 1
fi
echo "[2/7] issue #$ISSUE → PR #$PR_NUM"

# Inspect PR state.
PR_JSON=$(gh pr view "$PR_NUM" --json state,mergeable,headRefName,title)
PR_STATE=$(echo "$PR_JSON" | jq -r .state)
PR_MERGEABLE=$(echo "$PR_JSON" | jq -r .mergeable)
PR_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
PR_TITLE=$(echo "$PR_JSON" | jq -r .title)
echo "[3/7] PR #$PR_NUM: state=$PR_STATE mergeable=$PR_MERGEABLE branch=$PR_BRANCH"
echo "       title: $PR_TITLE"

case "$PR_STATE" in
  OPEN)
    if [ "$PR_MERGEABLE" = "CONFLICTING" ]; then
      echo "ERROR: PR #$PR_NUM has merge conflicts. Resolve first." >&2
      echo "       See \$LLM_SWARM_DOCS/VCS/git-github.md for the playbook." >&2
      exit 1
    fi
    echo "[4/7] merging PR #$PR_NUM (squash, delete-branch)…"
    # gh pr merge's local-delete step may fail; tolerate it.
    if ! gh pr merge "$PR_NUM" --squash --delete-branch; then
      echo "       (local-delete step may have failed; that's expected if branch is still checked out in a worktree — sweep will clean it)"
    fi
    ;;
  MERGED)
    echo "[4/7] PR #$PR_NUM already MERGED — proceeding to cleanup"
    ;;
  CLOSED)
    echo "ERROR: PR #$PR_NUM is CLOSED (not merged). Nothing to do." >&2
    exit 1
    ;;
  *)
    echo "ERROR: PR #$PR_NUM in unexpected state: $PR_STATE" >&2
    exit 1
    ;;
esac

# Wait for watcher to reap the worktree + tmux window.
TMUX_WIN="iss-$ISSUE"
WORKTREE_DIR="$(dirname "$MAIN_WT")/wt-issue-$ISSUE"
echo "[5/7] waiting up to ${GRACE_SECONDS}s for watcher reap of $TMUX_WIN + $(basename "$WORKTREE_DIR")…"
elapsed=0
while [ $elapsed -lt $GRACE_SECONDS ]; do
  tmux_alive=0
  wt_alive=0
  tmux list-windows 2>/dev/null | grep -qE ": ${TMUX_WIN}[* -]?\b" && tmux_alive=1
  [ -e "$WORKTREE_DIR/.git" ] && wt_alive=1
  if [ $tmux_alive -eq 0 ] && [ $wt_alive -eq 0 ]; then
    echo "       reaped after ${elapsed}s ✓"
    break
  fi
  sleep 3
  elapsed=$((elapsed+3))
done

# If still alive, manually kill (unless --no-kill).
if [ "$NO_KILL" = 0 ]; then
  if tmux list-windows 2>/dev/null | grep -qE ": ${TMUX_WIN}[* -]?\b"; then
    echo "[6/7] watcher didn't reap; killing tmux window $TMUX_WIN"
    tmux kill-window -t "$TMUX_WIN" 2>/dev/null || true
  fi
  if [ -e "$WORKTREE_DIR/.git" ]; then
    echo "[6/7] watcher didn't reap; removing worktree $WORKTREE_DIR"
    git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
  fi
else
  echo "[6/7] --no-kill set; leaving tmux window / worktree alone"
fi

# Run the safer local-branch sweep.
echo "[7/7] running local-branch sweep…"
run_sweep

echo
echo "$(c_green "Done.") PR #$PR_NUM merged for issue #$ISSUE."
