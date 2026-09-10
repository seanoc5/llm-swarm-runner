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

# Which delivery path this brief is actually on, as one token. Consumed
# twice — by the PR comment below and by the terminal hint at the bottom
# of this script — so the tmux probing lives in exactly one place while
# the two surfaces stay free to word the verdict differently.
#
# issue #397: the token is the load-bearing half of the PR comment. "A
# brief is queued" is only half an answer; "and nothing is polling it"
# inverts the reader's next move from wait to act, and until now that
# distinction was computed and then printed only to a terminal nobody was
# looking at.
#
#   live-idle        listener window present, pane at a shell → ~2s pickup
#   live-busy:<cmd>  pane inside a live agent process (issue #313 parking)
#   no-listener      session alive, zero iss-* windows → nothing polls
#   no-session       no tmux session at all → nothing polls
listener_state() {
    local session="$1" win="$2"
    [ -n "$session" ] || { echo "no-session"; return; }
    tmux has-session -t "$session" 2>/dev/null || { echo "no-session"; return; }
    local n
    n=$(tmux list-windows -t "$session" -F '#W' 2>/dev/null | grep -c '^iss-' || true)
    [ "$n" -gt 0 ] || { echo "no-listener"; return; }
    # issue #313: "pickup within ~2s" only holds when the listener's own
    # bash loop is in control (headless, or an idle interactive shell —
    # both poll inbox/ directly). An interactive session that finished its
    # task but is still parked INSIDE the live agent process (never ran
    # /quit) is invisible to that loop until the session ends —
    # worker-listener.sh's dispatch_agent is blocked on it. So check this
    # window's actual pane state rather than assuming the fast path.
    local pane_cmd=""
    if [ -n "$win" ]; then
        pane_cmd="$(tmux list-panes -t "$session:$win" -F '#{pane_current_command}' 2>/dev/null | head -1)"
    fi
    # An empty pane_cmd means the window name didn't resolve (non-standard
    # worktree basename) — assume the fast path, matching the terminal
    # hint's long-standing behavior rather than inventing a fifth state.
    case "$pane_cmd" in
        ""|bash|zsh|sh|fish) echo "live-idle" ;;
        *)                   echo "live-busy:$pane_cmd" ;;
    esac
}

# One sentence answering the only question the reader actually has:
# is waiting going to work? Ends in a bolded verdict either way.
delivery_outlook() {
    local state="$1" session="$2" win="$3"
    case "$state" in
        live-idle)
            printf 'listener window `%s` is live and idle in tmux session `%s`, so the brief should be claimed within ~2s and the fix should land as a commit here shortly. **Waiting is the right move.**' \
                "${win:-iss-*}" "$session" ;;
        live-busy:*)
            printf 'window `%s` in tmux session `%s` is inside a live agent process (`%s`). If that session is parked at rest rather than working, the poll loop cannot see this brief until the session ends — a running `coordinator-watch.sh` releases an idle parked session within ~30s (issue #313). **Waiting is usually right, but confirm a new commit before merging.**' \
                "${win:-?}" "$session" "${state#live-busy:}" ;;
        no-listener)
            printf 'tmux session `%s` is alive but has **no `iss-*` listener window** — nothing is polling this brief, so it will not be delivered on its own. **Do not just wait**: start a listener, or treat the queued fix as not in flight and re-file it (step 3 below).' \
                "$session" ;;
        *)
            printf 'there is **no tmux session running for this project** — nothing is polling this brief, so it will not be delivered on its own. **Do not just wait**: start the swarm, or treat the queued fix as not in flight and re-file it (step 3 below).' ;;
    esac
}

# The head of the brief itself, so severity (a review BLOCK vs a nit) is
# judgeable from the PR page instead of requiring a shell on the swarm
# host — the single most useful input to "should I merge past this?".
#
# Fenced with six backticks, with any run of six-or-more in the content
# defanged, so a brief carrying its own code fences cannot break out of
# the block and reflow the rest of the comment. Emits nothing at all when
# suppressed or unreadable; the caller treats empty as "omit the section".
brief_excerpt() {
    local file="$1"
    local max_lines="${SWARM_PR_BRIEF_LINES:-20}"
    [ "${SWARM_PR_BRIEF_EXCERPT:-1}" = "1" ] || return 0
    [ -r "$file" ] || return 0
    local total
    total="$(wc -l < "$file" 2>/dev/null || echo 0)"
    head -n "$max_lines" "$file" 2>/dev/null \
        | cut -c1-200 \
        | sed -e 's/`\{6,\}/[fence]/g'
    if [ "$total" -gt "$max_lines" ]; then
        printf '\n… truncated (%s more lines)\n' "$((total - max_lines))"
    fi
}

# issue #375: best-effort PR marker so a human merging from GitHub can see
# a follow-up brief is queued for this PR's worker. Mirrors the
# last-comment-wins idiom migration-collision-check.sh uses for
# SWARM_MIGRATION_GATE: state lives in which marker state was posted most
# recently, no comment editing required. Silent no-op on any failure (no
# gh, no remote, branch has no PR, PR not OPEN, or already flagged) — this
# is a signal, never a gate.
notify_pr_pending_brief() {
    local wt="$1" task_id="$2" state="$3" session="$4" win="$5" brief_file="$6"
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

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Assembled line by line rather than as one printf: every static line
    # is single-quoted, so the many `backtick` code spans below stay
    # literal without an escaping thicket. Dynamic lines go through
    # printf with a single-quoted format for the same reason.
    local -a body=()
    body+=('<!-- SWARM_PENDING_BRIEF: queued -->')
    body+=("$(printf ':warning: **Swarm: a follow-up brief is queued for the worker on this PR** (task `%s`, queued %s UTC).' \
        "$task_id" "$ts")")
    body+=('')
    body+=('Merging now may ship without that queued fix.')
    body+=('')
    body+=("$(printf '**Delivery outlook at queue time:** %s' \
        "$(delivery_outlook "$state" "$session" "$win")")")

    local excerpt
    excerpt="$(brief_excerpt "$brief_file")"
    if [ -n "$excerpt" ]; then
        body+=('')
        body+=('<details><summary><b>What was queued</b> (head of the brief — judge severity without leaving this page)</summary>')
        body+=('')
        body+=('``````text')
        body+=("$excerpt")
        body+=('``````')
        body+=('</details>')
    fi

    body+=('')
    body+=('**Next steps — pick one:**')
    body+=('')
    body+=('1. **Wait** — only if the outlook above says a listener is live. A `SWARM_PENDING_BRIEF: cleared` comment is posted here once the worker finishes a task with this PR resolved. Until then this warning stands.')
    body+=("$(printf '2. **Check whether it is still pending** — on the swarm host:\n   ```bash\n   ls -1 %s/.swarm/tasks/{inbox,processing}\n   ```\n   A file in `inbox/` means not yet claimed; in `processing/` means the worker is on it; both empty means it was delivered and this note is stale.' \
        "$wt")")
    body+=("$(printf '3. **Merge anyway.** Nothing re-dispatches the brief for you. If the worktree is later reaped the brief is salvaged and a `SWARM_BRIEF_ORPHANED` comment appears here — but that is a record, not a fix. File a follow-up issue first (`gh issue create`) quoting the excerpt above, so the queued work survives the merge.')")
    body+=("$(printf '4. **Cancel it** if the brief is obsolete:\n   ```bash\n   rm %s/.swarm/tasks/inbox/%s.md\n   ```\n   No effect once the worker has claimed it into `processing/`.' \
        "$wt" "$task_id")")
    body+=('')
    body+=('<sub>scripts/requeue.sh — issue #375 (reap-race signal), #397 (next steps).</sub>')

    local comment
    comment="$(printf '%s\n' "${body[@]}")"
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

# Probed once, rendered twice: as prose in the PR comment (issue #397) and
# as the terminal hint below. The session/window resolution above used to
# sit AFTER the notify call — it moved up so the comment can carry the
# same verdict instead of leaving it in a terminal nobody reads.
LISTENER_STATE="$(listener_state "$SESSION_NAME" "$WIN")"

notify_pr_pending_brief "$WT" "$TASK_ID" "$LISTENER_STATE" \
    "$SESSION_NAME" "$WIN" "$INBOX/$TASK_ID.md"

# Listener-state hint
case "$LISTENER_STATE" in
    live-idle)
        LISTENERS=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -c '^iss-' || true)
        echo "  (tmux session '$SESSION_NAME' has $LISTENERS listener window(s); pickup expected within ~2s"
        echo "   once that pane is idle — headless workers or an idle interactive shell pick up immediately;"
        echo "   an interactive shell mid-command finishes that command first, see issue #43)"
        ;;
    live-busy:*)
        echo "  NOTE: window '$WIN' is running a live agent process (${LISTENER_STATE#live-busy:}) — if it's an interactive"
        echo "        session parked at rest (task finished, but /quit was never run), worker-listener.sh's"
        echo "        own poll loop cannot see this brief until that session ends (issue #313)."
        echo "        A running coordinator-watch.sh sweep (WORKER_AUTO_DELIVER=1, the default) ends an"
        echo "        idle parked session automatically within one scan interval (WORKER_COMPACT_SCAN_SECS,"
        echo "        default 30s) and lets the listener claim this brief normally. If no such watcher is"
        echo "        running for this swarm, attach and release it by hand:"
        echo "          tmux attach -t $SESSION_NAME  (switch to window '$WIN', then run /quit)"
        ;;
    no-listener)
        echo "  WARN: session '$SESSION_NAME' is alive but has no iss-* listener window."
        echo "        Spawn one with:"
        echo "          tmux new-window -d -t $SESSION_NAME -n iss-XXX \\"
        echo "              \"$LLM_SWARM_DIR/sandbox.sh $WT listener\""
        ;;
    *)
        # shellcheck disable=SC2016  # single quotes are literal in the printed output
        echo "  WARN: no tmux session${SESSION_NAME:+ '$SESSION_NAME'} running."
        echo "        Brief is queued but nothing is polling. Start a listener with:"
        echo "          $LLM_SWARM_DIR/sandbox.sh $WT listener"
        ;;
esac
