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
# before the worker drains its inbox — or even mid-task, since the reap's
# --pr-finalized/--merged-only modes bypass the "listener parked" check —
# the brief is NOT lost: kill-worktree.sh salvages any unprocessed
# inbox/processing/outbox files into <project>/.swarm/salvaged/iss-<N>/
# before removing the worktree (issue #317). Check there — and re-dispatch
# if the work is still relevant — if a queued follow-up seems to have
# vanished.
#
# issue #375: salvage preserves the brief, but not the PR the brief was
# meant to fix — nothing tells a human merging from GitHub that a queued
# fix (a review BLOCK, a privacy caveat, ...) hasn't reached the worker
# yet, so the PR can merge past it. If the target worktree's checked-out
# branch has an OPEN PR, this drops a `<!-- SWARM_PENDING_BRIEF: queued -->`
# marker comment on it. Best-effort (no gh, no network, or a lookup
# failure never blocks the requeue) and idempotent (skipped if the latest
# SWARM_PENDING_BRIEF comment already says "queued" — see
# notify_pr_pending_brief below). worker-listener.sh posts the matching
# `SWARM_PENDING_BRIEF: cleared` comment once the task that drains this
# brief finishes with a PR resolved in its status file.
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

# issue #375: best-effort PR marker so a human merging from GitHub can see
# a follow-up brief is queued for this PR's worker. Mirrors the
# last-comment-wins idiom migration-collision-check.sh uses for
# SWARM_MIGRATION_GATE: state lives in which marker state was posted most
# recently, no comment editing required. Silent no-op on any failure (no
# gh, no remote, branch has no PR, PR not OPEN, or already flagged) — this
# is a signal, never a gate.
notify_pr_pending_brief() {
    local wt="$1" task_id="$2"
    command -v gh >/dev/null 2>&1 || return 0
    local branch
    branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 0
    [ -n "$branch" ] || return 0
    local json pr_num pr_state
    json="$(gh pr view "$branch" --json number,state -q '"\(.number)\t\(.state)"' 2>/dev/null)" || return 0
    [ -n "$json" ] || return 0
    IFS=$'\t' read -r pr_num pr_state <<< "$json"
    [ "$pr_state" = "OPEN" ] || return 0

    # Anchored to the HTML-comment marker line itself (start of line,
    # `-->` close required) — the comment's own body text explains the
    # OTHER marker state in prose ("...wait for a SWARM_PENDING_BRIEF:
    # cleared follow-up comment...") which a bare substring match would
    # also catch, corrupting "last state" detection.
    local last
    last="$(gh pr view "$pr_num" --json comments \
        -q '[.comments[] | select(.body | test("SWARM_PENDING_BRIEF:"))] | last | .body // empty' 2>/dev/null \
        | grep -oE '^<!-- SWARM_PENDING_BRIEF: (queued|cleared) -->$' \
        | sed -E 's/^<!-- SWARM_PENDING_BRIEF: (queued|cleared) -->$/\1/' || true)"
    [ "$last" = "queued" ] && return 0

    local ts comment
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    comment="$(printf '<!-- SWARM_PENDING_BRIEF: queued -->\n:warning: **Swarm: a follow-up brief is queued for this PR'"'"'s worker** (task `%s`, queued %s UTC).\n\nMerging now may ship without this queued fix. This note goes stale once the worker'"'"'s next commit lands — check the PR'"'"'s commit timeline against the queued time above, or wait for a `SWARM_PENDING_BRIEF: cleared` follow-up comment, before treating this as still true.\n\n<sub>scripts/requeue.sh — issue #375 (reap-race signal).</sub>\n' \
        "$task_id" "$ts")"
    gh pr comment "$pr_num" --body "$comment" >/dev/null 2>&1 || true
}

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

notify_pr_pending_brief "$WT" "$TASK_ID"

# Resolve the main repo via git so the session-name guess is robust to
# unusual layouts (worktrees not parented under the project dir).
MAIN_REPO=""
if GIT_COMMON_DIR=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    MAIN_REPO="$(dirname "$GIT_COMMON_DIR")"
fi
SESSION_NAME=""
[ -n "$MAIN_REPO" ] && SESSION_NAME="llm-$(basename "$MAIN_REPO")"

# Window name for THIS worktree, when it follows the wt-issue-<N> convention
# (used below to check the specific pane's state, not just whether some
# iss-* window exists).
WT_BASENAME="$(basename "$WT")"
WIN=""
case "$WT_BASENAME" in
    wt-issue-[0-9]*) WIN="iss-${WT_BASENAME#wt-issue-}" ;;
esac

# Listener-state hint
if [ -n "$SESSION_NAME" ] && tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    LISTENERS=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -c '^iss-' || true)
    if [ "$LISTENERS" -gt 0 ]; then
        # issue #313: "pickup within ~2s" only holds when the listener's own
        # bash loop is in control (headless, or an idle interactive shell —
        # both poll inbox/ directly). An interactive session that finished
        # its task but is still parked INSIDE the live agent process (never
        # ran /quit) is invisible to that loop until the session ends —
        # worker-listener.sh's dispatch_agent is blocked on it. Check this
        # window's actual pane state instead of assuming the fast path.
        PANE_CMD=""
        if [ -n "$WIN" ]; then
            PANE_CMD="$(tmux list-panes -t "$SESSION_NAME:$WIN" -F '#{pane_current_command}' 2>/dev/null | head -1)"
        fi
        case "$PANE_CMD" in
            ""|bash|zsh|sh|fish)
                echo "  (tmux session '$SESSION_NAME' has $LISTENERS listener window(s); pickup expected within ~2s"
                echo "   once that pane is idle — headless workers or an idle interactive shell pick up immediately;"
                echo "   an interactive shell mid-command finishes that command first, see issue #43)"
                ;;
            *)
                echo "  NOTE: window '$WIN' is running a live agent process ($PANE_CMD) — if it's an interactive"
                echo "        session parked at rest (task finished, but /quit was never run), worker-listener.sh's"
                echo "        own poll loop cannot see this brief until that session ends (issue #313)."
                echo "        A running coordinator-watch.sh sweep (WORKER_AUTO_DELIVER=1, the default) ends an"
                echo "        idle parked session automatically within one scan interval (WORKER_COMPACT_SCAN_SECS,"
                echo "        default 30s) and lets the listener claim this brief normally. If no such watcher is"
                echo "        running for this swarm, attach and release it by hand:"
                echo "          tmux attach -t $SESSION_NAME  (switch to window '$WIN', then run /quit)"
                ;;
        esac
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
