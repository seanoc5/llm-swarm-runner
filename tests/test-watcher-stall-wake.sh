#!/usr/bin/env bash
#
# test-watcher-stall-wake.sh — Tests for coordinator-watch.sh's stall
# heartbeat (issue #366 Part A): STALL_WAKE_SECS, the SWARM_PARKED_FILE park
# switch, and reuse of the existing coord-inbox/busy-pane/debounce machinery
# for a wake with no triggering worker event at all.
#
# Strategy: same technique as test-coordinator-inbox.sh — run the REAL
# coordinator-watch.sh as a subprocess with LLM_START stubbed to a fake
# script that records every invocation, and a REAL tmux session standing in
# for the coordinator pane so coordinator_pane_busy() sees genuine
# capture-pane content. PROJECT_DIR is deliberately NOT a git repo
# (own_worktree_dirs_for_scan's fail-open raw-glob fallback), matching
# test-coordinator-inbox.sh's non-activity-poll cases.
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

TEST_DIR=$(mktemp -d -t watcher-stall-wake-XXXXXX)
SESSION_NAME="test-stall-wake-$$"
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

set_pane_idle() {
    tmux send-keys -t "$SESSION_NAME:coordinator" "clear; echo 'some idle prompt >'" Enter
}
set_pane_busy() {
    tmux send-keys -t "$SESSION_NAME:coordinator" "clear; echo '✻ Considering… (esc to interrupt)'" Enter
}
set_pane_idle
sleep 0.3

# start_watcher <stall-wake-secs> <logfile>
#
# ONCE=0 throughout — every test here needs the watcher to survive past its
# first wake. Every other timer/sweep disabled so only the stall loop (and
# the outcome/outbox backend it shares wake machinery with) can produce a
# WAKE_LOG line.
start_watcher() {
    local stall_secs="$1" logfile="$2"
    LLM_START="$FAKE_LLM_START" \
        SESSION_NAME="$SESSION_NAME" \
        WORKSPACE="$TEST_DIR" \
        WATCHER_AUTOCLOSE=0 \
        WATCH_OUTBOX=0 \
        WATCH_PR_POLL_SECS=0 \
        WATCH_ORPHAN_SWEEP_SECS=0 \
        WATCH_BG_VIOLATION_SWEEP_SECS=0 \
        WATCH_ACTIVITY_POLL_SECS=0 \
        WATCH_WORKTREE_SWEEP_SECS=0 \
        WATCH_PENDING_BRIEF_SWEEP_SECS=0 \
        WATCH_CHECK_ON_DONE=0 \
        AUTO_COMPACT=0 \
        WORKER_AUTO_COMPACT=0 \
        WORKER_AUTO_DELIVER=0 \
        WATCHER_STALE_CHECK=0 \
        COORD_WAKE_RETRY_SECS=0 \
        COORD_WAKE_BUSY_RETRY_SECS="${COORD_WAKE_BUSY_RETRY_SECS:-1}" \
        COORD_WAKE_BUSY_CEILING_SECS="${COORD_WAKE_BUSY_CEILING_SECS:-900}" \
        DEBOUNCE_SECS="${DEBOUNCE_SECS:-0}" \
        STALL_WAKE_SECS="$stall_secs" \
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
    # issue #456: the debounce clock (also stall_wake_pass's "quiet since"
    # clock, issue #366) is a FILE under .swarm/ that survives a watcher
    # restart deliberately — remove it between tests so one test's ringing
    # doesn't leak into the next test's baseline.
    rm -f "$PROJECT_DIR/.swarm/coord-wake-last" "$PROJECT_DIR/.swarm/coord-wake-busy-pending"
    rm -f "$PROJECT_DIR/.swarm/parked"
}

wake_count() {
    grep -c 'WAKE:' "$WAKE_LOG" 2>/dev/null || true
}

# poll_until <max-tries> <sleep-between> <check-command...>
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
heading "Test 1: STALL_WAKE_SECS=0 (default) — no stall loop, no behavior change"
# ============================================================================
reset_state
set_pane_idle
sleep 0.3

start_watcher 0 "$TEST_DIR/watch-1.log"
sleep 3

grep -q 'stall_wake_secs=' "$EVENTS_LOG" 2>/dev/null \
    && red "STALL_WAKE_SECS=0 must not start the stall loop at all: $(cat "$EVENTS_LOG")"
grep -q 'trigger=stall' "$EVENTS_LOG" 2>/dev/null \
    && red "STALL_WAKE_SECS=0 must never produce a stall event: $(cat "$EVENTS_LOG")"
[ "$(wake_count)" = "0" ] || red "STALL_WAKE_SECS=0 must never paste a doorbell; wake.log: $(cat "$WAKE_LOG")"
stop_watcher
green "STALL_WAKE_SECS=0 is a true no-op (issue #366 default)"

# ============================================================================
heading "Test 2: opted in, fully idle swarm, no worker events ever — a stall wake eventually fires"
# ============================================================================
reset_state
set_pane_idle
sleep 0.3

start_watcher 4 "$TEST_DIR/watch-2.log"

poll_until 20 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "opted-in stall heartbeat never fired for a fully idle swarm. watch log:
$(cat "$TEST_DIR/watch-2.log")
events.log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
stop_watcher

grep -q 'coord.wake .*trigger=stall' "$EVENTS_LOG" \
    || red "expected coord.wake trigger=stall in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'Quiet-period check-in' "$WAKE_LOG" \
    || grep -rl 'Quiet-period check-in' "$INBOX_DIR"/*.md >/dev/null 2>&1 \
    || red "expected the quiet-period check-in prompt to reach either the nudge or a coord-inbox file"
green "a fully idle swarm with zero worker events eventually gets a stall wake (issue #366 Part A)"

# ============================================================================
heading "Test 3: a real outcome wake resets the stall timer"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-950/.swarm/tasks/done"
reset_state
set_pane_idle
sleep 0.3

# 6s heartbeat. An outcome lands almost immediately after boot, so a
# non-reset implementation (or one that measured quiet time from watcher
# start instead of from wake_clock_get) would still fire its first tick at
# ~boot+6s; a correct reset pushes the earliest possible stall fire out to
# ~outcome_wake+6s instead. We assert no SECOND wake shows up by boot+~7s
# (comfortably past the first would-be tick, comfortably before the
# reset-respecting one) and that one eventually does land later.
start_watcher 6 "$TEST_DIR/watch-3.log"
echo '{"task_id":"t950","outcome":"ok"}' > "$TEST_DIR/wt-issue-950/.swarm/tasks/done/t950-950.ok.json"

poll_until 10 0.3 bash -c "[ \"\$(grep -c 'WAKE:' '$WAKE_LOG')\" = '1' ]" \
    || red "setup: the outcome's own wake never landed. watch log:
$(cat "$TEST_DIR/watch-3.log")"

# By now ~1.5-2s have elapsed since boot (start_watcher's own settle sleep)
# plus this poll's own wait — comfortably short of the 6s heartbeat. Confirm
# the count is still exactly 1 for a few more seconds spanning what would
# have been an unreset first tick.
sleep 4
[ "$(wake_count)" = "1" ] || red "a stall wake fired before a full STALL_WAKE_SECS had passed since the outcome's own wake — the reset did not take effect. wake.log:
$(cat "$WAKE_LOG")"
green "no stall wake fires within STALL_WAKE_SECS of a real outcome wake (timer was reset)"

poll_until 20 0.5 bash -c "[ \"\$(grep -c 'WAKE:' '$WAKE_LOG')\" -ge '2' ]" \
    || red "stall wake never fired even after a full quiet STALL_WAKE_SECS window post-outcome. wake.log:
$(cat "$WAKE_LOG")
events.log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
stop_watcher
grep -q 'coord.wake .*trigger=stall' "$EVENTS_LOG" \
    || red "expected a trigger=stall coord.wake once the reset quiet window elapsed"
green "a stall wake fires once a full STALL_WAKE_SECS has passed since the last real wake"

# ============================================================================
heading "Test 4: the park switch (.swarm/parked) suppresses stall wakes, even past the threshold"
# ============================================================================
reset_state
set_pane_idle
sleep 0.3
touch "$PROJECT_DIR/.swarm/parked"

start_watcher 2 "$TEST_DIR/watch-4.log"
sleep 6

[ "$(wake_count)" = "0" ] || red "SWARM_PARKED_FILE must suppress every stall wake; wake.log: $(cat "$WAKE_LOG")"
grep -q 'trigger=stall' "$EVENTS_LOG" 2>/dev/null \
    && red "SWARM_PARKED_FILE must suppress stall_wake_pass entirely — no stall.check/coord.wake event expected: $(cat "$EVENTS_LOG")"
stop_watcher
green "the .swarm/parked marker suppresses stall wakes even well past STALL_WAKE_SECS"

# ============================================================================
heading "Test 5: busy pane — a stall wake defers through the SAME hold gate as every other wake path"
# ============================================================================
reset_state
set_pane_busy
sleep 0.3

start_watcher 2 "$TEST_DIR/watch-5.log"

poll_until 20 0.5 bash -c "grep -q 'coord.wake.defer .*reason=pane_busy.*trigger=stall' '$EVENTS_LOG' 2>/dev/null" \
    || red "busy pane never deferred the stall wake via the shared hold gate. watch log:
$(cat "$TEST_DIR/watch-5.log")
events.log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
[ "$(wake_count)" = "0" ] || red "busy pane must NOT have pasted a stall doorbell yet; wake.log: $(cat "$WAKE_LOG")"
green "busy pane: stall wake deferred (coord.wake.defer reason=pane_busy trigger=stall), nothing pasted yet"

set_pane_idle
poll_until 20 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "busy-deferred stall wake never delivered once the pane went idle. watch log:
$(cat "$TEST_DIR/watch-5.log")
events.log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
stop_watcher
green "a busy-deferred stall wake is delivered once the pane goes idle, via coord_wake_hold_retry_pass"

echo ""
green "All assertions passed (test-watcher-stall-wake.sh)"
