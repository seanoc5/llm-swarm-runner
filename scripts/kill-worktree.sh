#!/usr/bin/env bash
#
# kill-worktree.sh — remove a worker worktree, its branch, and tmux window.
#
# Usage:
#   kill-worktree.sh <issue-number> [project-dir]
#
# Removes the worktree at <derived path>/wt-issue-<N>, deletes the branch
# fix/issue-<N>, and kills the tmux window iss-<N> if any. Idempotent —
# warns about pieces that don't exist but never errors. Use for ABANDON
# verdicts from coordinator triage.
#
# Path derivation honors SWARM_WORKTREE_GROUPING (flat|project, default
# flat). See scripts/_load-env.sh swarm_worktree_dir() for the rule.
#
# WARNING: --force is used. Any uncommitted work in the worktree is lost.
# The script prints how-much-work-will-be-lost before deletion.
set -euo pipefail

ISSUE="${1:?usage: kill-worktree.sh <issue-number> [project-dir]}"
PROJECT_DIR="${2:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Source the env loader to (a) pick up SWARM_WORKTREE_GROUPING from
# <project>/.swarm/.env or sandbox .env.example, and (b) get
# swarm_worktree_dir() to derive WT correctly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

WT="$(swarm_worktree_dir "$PROJECT_DIR" "$ISSUE")"
BRANCH="fix/issue-$ISSUE"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"

cd "$PROJECT_DIR"

echo "=== kill-worktree #$ISSUE ==="
echo "  project:  $PROJECT_DIR"
echo "  worktree: $WT"
echo "  branch:   $BRANCH"
echo "  tmux:     $SESSION_NAME / iss-$ISSUE"
echo

# Show what we're about to discard
if [ -d "$WT" ]; then
    AHEAD="$(git -C "$WT" rev-list --count master..HEAD 2>/dev/null || echo '?')"
    DIRTY="$(git -C "$WT" status --porcelain 2>/dev/null | wc -l)"
    echo "  Worktree state: $AHEAD commit(s) ahead of master, $DIRTY uncommitted change(s)"
    git worktree remove --force "$WT"
    echo "  ✓ removed worktree"
else
    echo "  - worktree dir not present (skipped)"
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git branch -D "$BRANCH"
    echo "  ✓ deleted branch"
else
    echo "  - branch not present (skipped)"
fi

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
        tmux kill-window -t "$SESSION_NAME:iss-$ISSUE"
        echo "  ✓ killed tmux window"
    else
        echo "  - tmux window not present (skipped)"
    fi
else
    echo "  - tmux session not running (skipped window cleanup)"
fi

echo
echo "Done."
