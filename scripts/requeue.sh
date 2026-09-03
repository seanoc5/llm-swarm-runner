#!/usr/bin/env bash
#
# requeue.sh — drop a follow-up task brief into a worker's v2 inbox.
#
# Usage:
#   requeue.sh <wt-path|issue-N> <brief-file>     # brief read from file
#   requeue.sh <wt-path|issue-N> -                # brief read from stdin
#   echo "..." | requeue.sh <wt-path|issue-N> -
#
# Wraps the atomic mktemp+mv pattern so the listener never sees a
# half-written brief. Generates a timestamped task id from the wall clock.
#
# If the first arg is purely numeric, it's treated as an issue number and
# resolved via swarm_worktree_dir() (honors SWARM_WORKTREE_GROUPING in
# <PWD>/.swarm/.env — flat: ../wt-issue-<N>, project: ../<project>-worktrees/
# wt-issue-<N>). Otherwise it's a path.
#
# After dropping the brief, prints a hint about whether the listener tmux
# window exists — so you don't sit waiting for a brief that nothing is
# polling.
#
# If the worktree gets reaped (kill-finished-workers.sh --with-worktree)
# before the worker drains its inbox, the brief is NOT lost: kill-worktree.sh
# salvages any unprocessed inbox/outbox *.md into
# <project>/.swarm/salvaged/iss-<N>/ before removing the worktree (issue
# #317). Check there — and re-dispatch if the work is still relevant — if a
# queued follow-up seems to have vanished.
set -euo pipefail

# Self-locate so the printed help text references the actual install path,
# not a hardcoded one. Override LLM_SWARM_DIR for non-standard installs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"

TARGET="${1:?usage: requeue.sh <wt-path|issue-N> <brief-file|->}"
SOURCE="${2:?usage: requeue.sh <wt-path|issue-N> <brief-file|->}"

# Resolve target → absolute worktree dir + (optional) issue hint for filename
ISSUE_HINT=""
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    # shellcheck source=_load-env.sh
    . "$SCRIPT_DIR/_load-env.sh" "$PWD"
    WT="$(swarm_worktree_dir "$PWD" "$TARGET")"
    ISSUE_HINT="-$TARGET"
else
    WT="$TARGET"
fi
[ -d "$WT" ] || { echo "ERROR: worktree not found: $WT" >&2; exit 1; }
WT="$(cd "$WT" && pwd)"

INBOX="$WT/.swarm/tasks/inbox"
mkdir -p "$INBOX"

TASK_ID="$(date +%Y%m%d-%H%M%S)${ISSUE_HINT}"
TMP="$(mktemp -p "$INBOX" .tmp.XXXXXX.md)"

# Read brief
if [ "$SOURCE" = "-" ]; then
    cat > "$TMP"
else
    [ -f "$SOURCE" ] || { echo "ERROR: brief file not found: $SOURCE" >&2; rm -f "$TMP"; exit 1; }
    cat "$SOURCE" > "$TMP"
fi

# Atomic claim into the inbox
mv "$TMP" "$INBOX/$TASK_ID.md"
echo "✓ requeued: $INBOX/$TASK_ID.md"

# Resolve the main repo via git so the session-name guess is robust to
# unusual layouts (worktrees not parented under the project dir).
MAIN_REPO=""
if GIT_COMMON_DIR=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    MAIN_REPO="$(dirname "$GIT_COMMON_DIR")"
fi
SESSION_NAME=""
[ -n "$MAIN_REPO" ] && SESSION_NAME="llm-$(basename "$MAIN_REPO")"

# Listener-state hint
if [ -n "$SESSION_NAME" ] && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    LISTENERS=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -c '^iss-' || true)
    if [ "$LISTENERS" -gt 0 ]; then
        echo "  (tmux session '$SESSION_NAME' has $LISTENERS listener window(s); pickup expected within ~2s"
        echo "   once that pane is idle — headless workers or an idle interactive shell pick up immediately;"
        echo "   an interactive shell mid-command finishes that command first, see issue #43)"
    else
        echo "  WARN: session '$SESSION_NAME' is alive but has no iss-* listener window."
        echo "        Spawn one with:"
        echo "          tmux new-window -d -t $SESSION_NAME -n iss-XXX \\"
        echo "              \"$LLM_SWARM_DIR/sandbox.sh $WT listener\""
    fi
else
    # shellcheck disable=SC2016  # single quotes are literal in the printed output
    echo "  WARN: no tmux session${SESSION_NAME:+ '$SESSION_NAME'} running."
    echo "        Brief is queued but nothing is polling. Start a listener with:"
    echo "          $LLM_SWARM_DIR/sandbox.sh $WT listener"
fi
