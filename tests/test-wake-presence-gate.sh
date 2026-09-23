#!/usr/bin/env bash
#
# test-wake-presence-gate.sh — Tests for coordinator-watch.sh's
# human-presence doorbell gate (issue #459) and the debounce-skip re-ring
# (issue #456).
#
# Strategy: same shape as test-coordinator-inbox.sh — run the REAL
# coordinator-watch.sh as a subprocess with LLM_START stubbed to a recorder
# and a REAL tmux session standing in for the coordinator pane. On top of
# that, HOME is pointed at a fixture tree so the presence detector reads
# transcripts this test writes rather than the developer's own.
#
# The fixture detail that matters, and the reason this feature is not a
# one-line mtime check: a doorbell the watcher pasted is recorded in the
# session transcript with origin {kind: human} and promptSource "typed" —
# indistinguishable in shape from the operator typing it. Test 2 is the
# regression guard for that: a swarm whose only recent "typed" turns are the
# watcher's own nudges must keep ringing, or an unattended swarm goes
# permanently silent.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"
command -v jq   >/dev/null 2>&1 || { yellow "jq not found — presence gate is inert without it; skipping"; exit 0; }

TEST_DIR=$(mktemp -d -t wake-presence-XXXXXX)
SESSION_NAME="test-wake-presence-$$"
cleanup() {
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
    [ -n "${WATCH_PID:-}" ] && wait "$WATCH_PID" 2>/dev/null || true
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR/.swarm"
INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"

# Fixture HOME — the presence detector derives a transcript dir from the
# working dir with the CLI's own slug convention (path, "/" → "-").
FAKE_HOME="$TEST_DIR/home"
TRANSCRIPT_DIR="$FAKE_HOME/.claude/projects/$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
mkdir -p "$TRANSCRIPT_DIR"

NUDGE_PREFIX='Inbox: 1 item(s) in .swarm/coord-inbox/'

# write_typed_turn <file> <iso-timestamp> <text>
# One transcript line in the shape Claude Code actually writes for a
# submitted prompt — including origin/promptSource, which a pasted doorbell
# carries identically to a hand-typed one.
write_typed_turn() {
    local file="$1" ts="$2" text="$3"
    jq -cn --arg ts "$ts" --arg text "$text" \
        '{type:"user", timestamp:$ts, promptSource:"typed",
          origin:{kind:"human"}, userType:"external",
          message:{role:"user", content:$text}}' >> "$file"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

WAKE_LOG="$TEST_DIR/wake.log"
: > "$WAKE_LOG"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<EOF
#!/usr/bin/env bash
printf '%s  WAKE: %s\n' "\$(date +%s%N)" "\$*" >> "$WAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LLM_START"

tmux new-session -d -s "$SESSION_NAME" -n coordinator 2>/dev/null
tmux send-keys -t "$SESSION_NAME:coordinator" "clear; echo 'some idle prompt >'" Enter
sleep 0.3

start_watcher() {
    local logfile="$1"
    HOME="$FAKE_HOME" \
    LLM_START="$FAKE_LLM_START" \
        SESSION_NAME="$SESSION_NAME" \
        WORKSPACE="$TEST_DIR" \
        WATCHER_AUTOCLOSE=0 \
        WATCH_OUTBOX=0 \
        WATCH_PR_POLL_SECS=0 \
        WATCH_ORPHAN_SWEEP_SECS=0 \
        WATCH_BG_VIOLATION_SWEEP_SECS=0 \
        WATCH_CHECK_ON_DONE=0 \
        WATCH_ACTIVITY_POLL_SECS=0 \
        COORD_WAKE_RETRY_SECS=0 \
        COORD_WAKE_BUSY_RETRY_SECS="${COORD_WAKE_BUSY_RETRY_SECS:-1}" \
        COORD_WAKE_BUSY_CEILING_SECS="${COORD_WAKE_BUSY_CEILING_SECS:-900}" \
        COORD_HUMAN_IDLE_SECS="${COORD_HUMAN_IDLE_SECS:-600}" \
        WORKER_HUMAN_IDLE_SECS="${WORKER_HUMAN_IDLE_SECS:-0}" \
        DEBOUNCE_SECS="${DEBOUNCE_SECS:-0}" \
        WATCHER_QUIET=1 \
        DRY_RUN=0 ONCE=0 POLL_SECS=1 \
        "$WATCH" "$PROJECT_DIR" > "$logfile" 2>&1 &
    WATCH_PID=$!
    sleep 1.5
}

stop_watcher() {
    [ -n "${WATCH_PID:-}" ] || return 0
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    unset WATCH_PID
}

reset_state() {
    : > "$WAKE_LOG"
    rm -f "$EVENTS_LOG"
    rm -rf "$INBOX_DIR"
    rm -f "$PROJECT_DIR/.swarm/coord-wake-busy-pending" "$PROJECT_DIR/.swarm/coord-wake-last"
    rm -f "$TRANSCRIPT_DIR"/*.jsonl
}

inbox_count() {
    find "$INBOX_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}
wake_count() { grep -c 'WAKE:' "$WAKE_LOG" 2>/dev/null || true; }

poll_until() {
    local tries="$1" delay="$2"; shift 2
    local i
    for ((i = 0; i < tries; i++)); do
        if "$@"; then return 0; fi
        sleep "$delay"
    done
    return 1
}

# ============================================================================
heading "Test 1: operator present — doorbell is held, payload still lands"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-901/.swarm/tasks/done"
reset_state
write_typed_turn "$TRANSCRIPT_DIR/session-a.jsonl" "$(now_iso)" \
    "file followups 1202, 1201, 1196 — and refresh me on where 1190 landed"

COORD_HUMAN_IDLE_SECS=600 DEBOUNCE_SECS=0 start_watcher "$TEST_DIR/watch-1.log"
echo '{"task_id":"t901","outcome":"ok"}' > "$TEST_DIR/wt-issue-901/.swarm/tasks/done/t901-901.ok.json"

poll_until 20 0.5 bash -c "grep -q 'coord.wake.defer .*reason=human_present' '$EVENTS_LOG'" \
    || red "expected the doorbell to be held with reason=human_present. events:
$(cat "$EVENTS_LOG" 2>/dev/null)
watch log:
$(cat "$TEST_DIR/watch-1.log")"
green "doorbell held while the operator was present (coord.wake.defer reason=human_present)"

[ "$(wake_count)" = "0" ] || red "no paste should have reached the pane while a human was present; got: $(cat "$WAKE_LOG")"
green "nothing was pasted into the operator's session"

[ "$(inbox_count)" = "1" ] || red "inbox payload must be written regardless of the hold; got $(inbox_count) file(s)"
grep -q 'coord.inbox.write ' "$EVENTS_LOG" || red "expected coord.inbox.write even while held"
green "payload still landed in coord-inbox/ — only the nudge waits, nothing is lost"
stop_watcher

# ============================================================================
heading "Test 2: the watcher's OWN nudge must not read as an operator"
# ============================================================================
# The regression guard for the whole feature: pasted doorbells appear in the
# transcript as typed human turns, so a naive detector sees itself, holds
# forever, and mutes an unattended swarm permanently.
mkdir -p "$TEST_DIR/wt-issue-902/.swarm/tasks/done"
reset_state
write_typed_turn "$TRANSCRIPT_DIR/session-b.jsonl" "$(now_iso)" \
    "$NUDGE_PREFIX — read and triage them (see prompts/coordinator.md \"Inbox\")."

COORD_HUMAN_IDLE_SECS=600 DEBOUNCE_SECS=0 start_watcher "$TEST_DIR/watch-2.log"
echo '{"task_id":"t902","outcome":"ok"}' > "$TEST_DIR/wt-issue-902/.swarm/tasks/done/t902-902.ok.json"

poll_until 20 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "an unattended swarm whose only typed turns are the watcher's own nudges MUST keep ringing. events:
$(cat "$EVENTS_LOG" 2>/dev/null)
watch log:
$(cat "$TEST_DIR/watch-2.log")"
green "watcher's own nudge excluded — unattended swarm still rings"

grep -q 'coord.wake.defer .*reason=human_present' "$EVENTS_LOG" \
    && red "the watcher's own paste was misread as an operator — this is the mute-the-swarm bug"
green "no human_present hold was raised by the watcher's own paste"
stop_watcher

# ============================================================================
heading "Test 3: held doorbell delivers once the operator's window expires"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-903/.swarm/tasks/done"
reset_state
write_typed_turn "$TRANSCRIPT_DIR/session-c.jsonl" "$(now_iso)" \
    "go with all three as suggested (yes)"

COORD_HUMAN_IDLE_SECS=4 COORD_WAKE_BUSY_RETRY_SECS=1 DEBOUNCE_SECS=0 \
    start_watcher "$TEST_DIR/watch-3.log"
echo '{"task_id":"t903","outcome":"ok"}' > "$TEST_DIR/wt-issue-903/.swarm/tasks/done/t903-903.ok.json"

poll_until 20 0.5 bash -c "grep -q 'coord.wake.defer .*reason=human_present' '$EVENTS_LOG'" \
    || red "expected an initial human_present hold. events:
$(cat "$EVENTS_LOG" 2>/dev/null)"

poll_until 30 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "held doorbell never delivered after the operator's window expired. events:
$(cat "$EVENTS_LOG" 2>/dev/null)
watch log:
$(cat "$TEST_DIR/watch-3.log")"
green "held doorbell delivered once the operator idled past COORD_HUMAN_IDLE_SECS"

grep -q 'coord.wake.deferred_delivered .*trigger=human_present' "$EVENTS_LOG" \
    || red "expected coord.wake.deferred_delivered trigger=human_present; got:
$(cat "$EVENTS_LOG")"
grep -q 'coord.wake.defer_ceiling' "$EVENTS_LOG" \
    && red "a human_present hold must never hit a ceiling — it waits the operator out"
green "delivery recorded as a human_present hand-off, with no ceiling override"
stop_watcher

# ============================================================================
heading "Test 4 (issue #456): a debounce-skipped doorbell is re-rung, not dropped"
# ============================================================================
# Pre-#456 the second outcome's doorbell was dropped outright: its payload
# sat in the inbox with no wake attached until some unrelated later event —
# measured at ~11h in the 2026-09-22 SAMlytics incident.
mkdir -p "$TEST_DIR/wt-issue-904/.swarm/tasks/done" "$TEST_DIR/wt-issue-905/.swarm/tasks/done"
reset_state

COORD_HUMAN_IDLE_SECS=0 DEBOUNCE_SECS=5 COORD_WAKE_BUSY_RETRY_SECS=1 \
    start_watcher "$TEST_DIR/watch-4.log"
echo '{"task_id":"t904","outcome":"ok"}' > "$TEST_DIR/wt-issue-904/.swarm/tasks/done/t904-904.ok.json"
poll_until 20 0.5 bash -c "[ \"\$(grep -c 'WAKE:' '$WAKE_LOG')\" -ge 1 ]" \
    || red "first outcome never rang. watch log:
$(cat "$TEST_DIR/watch-4.log")"
# Second outcome lands well inside the debounce window.
echo '{"task_id":"t905","outcome":"ok"}' > "$TEST_DIR/wt-issue-905/.swarm/tasks/done/t905-905.ok.json"

poll_until 20 0.5 bash -c "grep -q 'coord.wake.defer .*reason=debounce' '$EVENTS_LOG'" \
    || red "expected the second doorbell to be HELD for debounce, not skipped. events:
$(cat "$EVENTS_LOG" 2>/dev/null)"
green "debounced doorbell recorded as a hold (coord.wake.defer reason=debounce)"

poll_until 40 0.5 bash -c "[ \"\$(grep -c 'WAKE:' '$WAKE_LOG')\" -ge 2 ]" \
    || red "the debounce-held doorbell never rang — this is issue #456's 11h-silence bug. events:
$(cat "$EVENTS_LOG" 2>/dev/null)
wake log:
$(cat "$WAKE_LOG")"
green "second doorbell rang once the debounce window passed"

[ "$(inbox_count)" = "2" ] || red "expected 2 inbox payloads (one per outcome); got $(inbox_count)"
green "both payloads present — coalescing applies to nudges, never to inbox writes"
stop_watcher

# ============================================================================
heading "Test 5: COORD_HUMAN_IDLE_SECS=0 restores pre-#459 behavior"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-906/.swarm/tasks/done"
reset_state
write_typed_turn "$TRANSCRIPT_DIR/session-d.jsonl" "$(now_iso)" \
    "I am very much here, typing right now"

COORD_HUMAN_IDLE_SECS=0 WORKER_HUMAN_IDLE_SECS=0 DEBOUNCE_SECS=0 \
    start_watcher "$TEST_DIR/watch-5.log"
echo '{"task_id":"t906","outcome":"ok"}' > "$TEST_DIR/wt-issue-906/.swarm/tasks/done/t906-906.ok.json"

poll_until 20 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "with the gate disabled the doorbell must paste immediately. watch log:
$(cat "$TEST_DIR/watch-5.log")"
grep -q 'reason=human_present' "$EVENTS_LOG" \
    && red "gate disabled but a human_present hold still fired"
green "COORD_HUMAN_IDLE_SECS=0 is a clean rollback to pre-#459 behavior"
stop_watcher

printf '\n\033[1;32mAll wake-presence-gate tests passed.\033[0m\n'
