#!/usr/bin/env bash
#
# test-coordinator-inbox.sh — Tests for coordinator-watch.sh's durable
# coordinator inbox + wake-only-when-idle busy-pane doorbell deferral
# (issue #430).
#
# Strategy: run the REAL coordinator-watch.sh as a subprocess (same
# technique as test-watcher-autoclose.sh / test-watcher-activity-poll.sh)
# with LLM_START stubbed to a fake script that records every invocation,
# and a REAL tmux session standing in for the coordinator pane so
# coordinator_pane_busy() sees genuine capture-pane content — same
# technique test-coordinator-auto-compact.sh uses for the identical
# busy/idle distinction (send-keys literal busy-pattern text, "clear;
# echo ..." for idle). Outcome JSONs are dropped into a flat WORKSPACE/
# wt-issue-N/.swarm/tasks/done/ layout; PROJECT_DIR is deliberately NOT a
# git repo (own_worktree_dirs_for_scan's fail-open raw-glob fallback,
# same as test-watcher-autoclose.sh) except for the activity-poll test,
# which needs a real repo the way test-watcher-activity-poll.sh does.
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

TEST_DIR=$(mktemp -d -t coord-inbox-XXXXXX)
SESSION_NAME="test-coord-inbox-$$"
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

# start_watcher <extra env assignments as a single string> <logfile>
#
# ONCE=0 throughout — every test here needs the watcher to survive past its
# first wake (to observe a busy-defer's later retry, a burst's debounce, or
# an activity-poll tick), unlike the ONCE=1 shape test-watcher-autoclose.sh
# uses for its single-wake cases.
start_watcher() {
    local logfile="$1"
    LLM_START="$FAKE_LLM_START" \
        SESSION_NAME="$SESSION_NAME" \
        WORKSPACE="$TEST_DIR" \
        WATCHER_AUTOCLOSE=0 \
        WATCH_OUTBOX=0 \
        WATCH_PR_POLL_SECS=0 \
        WATCH_ORPHAN_SWEEP_SECS=0 \
        WATCH_BG_VIOLATION_SWEEP_SECS=0 \
        WATCH_CHECK_ON_DONE=0 \
        WATCH_ACTIVITY_POLL_SECS="${WATCH_ACTIVITY_POLL_SECS:-0}" \
        COORD_WAKE_RETRY_SECS=0 \
        COORD_WAKE_BUSY_RETRY_SECS="${COORD_WAKE_BUSY_RETRY_SECS:-30}" \
        COORD_WAKE_BUSY_CEILING_SECS="${COORD_WAKE_BUSY_CEILING_SECS:-900}" \
        DEBOUNCE_SECS="${DEBOUNCE_SECS:-0}" \
        WATCHER_QUIET=1 \
        DRY_RUN=0 ONCE=0 POLL_SECS=1 \
        "$WATCH" "$PROJECT_DIR" > "$logfile" 2>&1 &
    WATCH_PID=$!
    # Let the watcher baseline existing outcomes before we drop a new one
    # (mirrors test-watcher-autoclose.sh's start_watcher).
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
}

inbox_count() {
    find "$INBOX_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}

wake_count() {
    grep -c 'WAKE:' "$WAKE_LOG" 2>/dev/null || true
}

# poll_until <max-tries> <sleep-between> <check-command...>
# Retries a condition rather than a single fixed sleep — this daemon's
# poll loop (POLL_SECS=1) and timer loop (2s tick) both introduce real
# scheduling slack that a single sleep would either under- or over-shoot.
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
heading "Test 1: idle pane — outcome wake pastes immediately with the one-line inbox nudge"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-901/.swarm/tasks/done"
reset_state
set_pane_idle
sleep 0.3

COORD_WAKE_BUSY_RETRY_SECS=30 DEBOUNCE_SECS=0 start_watcher "$TEST_DIR/watch-1.log"
echo '{"task_id":"t901","outcome":"ok"}' > "$TEST_DIR/wt-issue-901/.swarm/tasks/done/t901-901.ok.json"

poll_until 20 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "idle-pane outcome never produced a wake. watch log:
$(cat "$TEST_DIR/watch-1.log")"
stop_watcher

grep -q 'Inbox: 1 item(s)' "$WAKE_LOG" \
    || red "expected the one-line inbox nudge (Inbox: 1 item(s)...) in the wake payload; got: $(cat "$WAKE_LOG")"
green "idle pane: doorbell fired immediately with the generic one-line inbox nudge"

[ "$(inbox_count)" = "1" ] || red "expected exactly 1 coord-inbox/*.md file after one outcome; got $(inbox_count)"
green "coord-inbox holds exactly one payload file for the one outcome"

grep -q 'coord.inbox.write .*issue=901' "$EVENTS_LOG" || red "expected coord.inbox.write for issue=901 in events.log"
grep -q 'coord.wake .*issue=901' "$EVENTS_LOG" || red "expected coord.wake for issue=901 in events.log"
grep -q 'coord.wake.defer ' "$EVENTS_LOG" && red "did not expect a coord.wake.defer event on an idle pane: $(cat "$EVENTS_LOG")"
green "events.log: coord.inbox.write + coord.wake, no defer, for the idle-pane case"

# ============================================================================
heading "Test 2: busy pane — doorbell defers, then delivers once the pane goes idle"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-902/.swarm/tasks/done"
reset_state
set_pane_busy
sleep 0.3

COORD_WAKE_BUSY_RETRY_SECS=1 COORD_WAKE_BUSY_CEILING_SECS=100 DEBOUNCE_SECS=0 start_watcher "$TEST_DIR/watch-2.log"
echo '{"task_id":"t902","outcome":"ok"}' > "$TEST_DIR/wt-issue-902/.swarm/tasks/done/t902-902.ok.json"

poll_until 10 0.3 bash -c "grep -q 'coord.wake.defer ' '$EVENTS_LOG' 2>/dev/null" \
    || red "busy pane never logged coord.wake.defer. watch log:
$(cat "$TEST_DIR/watch-2.log")"
[ "$(wake_count)" = "0" ] || red "busy pane must NOT have pasted a doorbell yet; wake.log: $(cat "$WAKE_LOG")"
green "busy pane: doorbell deferred (coord.wake.defer reason=pane_busy), nothing pasted yet"

[ "$(inbox_count)" = "1" ] || red "expected the inbox write to have happened despite the deferred doorbell; got $(inbox_count)"
green "coord-inbox payload landed even though the doorbell itself was deferred (issue #430's submit_failed fix)"

set_pane_idle
poll_until 20 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "busy-deferred wake never delivered after the pane went idle. watch log:
$(cat "$TEST_DIR/watch-2.log")
events.log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
stop_watcher

grep -q 'Inbox: 1 item(s)' "$WAKE_LOG" || red "expected the inbox nudge in the delivered busy-deferred wake; got: $(cat "$WAKE_LOG")"
grep -q 'coord.wake.deferred_delivered .*trigger=pane_busy' "$EVENTS_LOG" \
    || red "expected coord.wake.deferred_delivered trigger=pane_busy in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "busy-deferred wake delivered once the pane went idle (coord.wake.deferred_delivered trigger=pane_busy)"

# ============================================================================
heading "Test 3: busy pane past the ceiling — delivered anyway"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-903/.swarm/tasks/done"
reset_state
set_pane_busy
sleep 0.3

COORD_WAKE_BUSY_RETRY_SECS=1 COORD_WAKE_BUSY_CEILING_SECS=2 DEBOUNCE_SECS=0 start_watcher "$TEST_DIR/watch-3.log"
echo '{"task_id":"t903","outcome":"ok"}' > "$TEST_DIR/wt-issue-903/.swarm/tasks/done/t903-903.ok.json"

# Pane stays busy throughout — never called set_pane_idle here — so any
# delivery MUST come from the ceiling forcing it through, not the pane
# clearing on its own.
poll_until 30 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "busy-past-ceiling wake never delivered. watch log:
$(cat "$TEST_DIR/watch-3.log")
events.log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
stop_watcher

grep -q 'coord.wake.defer_ceiling' "$EVENTS_LOG" \
    || red "expected coord.wake.defer_ceiling in events.log once the ceiling fired; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "a wake stuck busy past COORD_WAKE_BUSY_CEILING_SECS is delivered anyway (coord.wake.defer_ceiling), still busy"

# ============================================================================
heading "Test 4: a burst of 3 outcomes inside the debounce window — one nudge, three inbox files"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-904/.swarm/tasks/done"
mkdir -p "$TEST_DIR/wt-issue-905/.swarm/tasks/done"
mkdir -p "$TEST_DIR/wt-issue-906/.swarm/tasks/done"
reset_state
set_pane_idle
sleep 0.3

COORD_WAKE_BUSY_RETRY_SECS=30 DEBOUNCE_SECS=30 start_watcher "$TEST_DIR/watch-4.log"
echo '{"task_id":"t904","outcome":"ok"}' > "$TEST_DIR/wt-issue-904/.swarm/tasks/done/t904-904.ok.json"
sleep 1.2
echo '{"task_id":"t905","outcome":"ok"}' > "$TEST_DIR/wt-issue-905/.swarm/tasks/done/t905-905.ok.json"
sleep 1.2
echo '{"task_id":"t906","outcome":"ok"}' > "$TEST_DIR/wt-issue-906/.swarm/tasks/done/t906-906.ok.json"

poll_until 20 0.5 bash -c "grep -q 'WAKE:' '$WAKE_LOG'" \
    || red "burst never produced even the one expected wake. watch log:
$(cat "$TEST_DIR/watch-4.log")"
# Give the two debounced-skip outcomes time to be observed and inbox-written
# before asserting the final counts.
sleep 2
stop_watcher

[ "$(wake_count)" = "1" ] || red "expected exactly ONE doorbell nudge for a burst inside the debounce window; got $(wake_count). wake.log:
$(cat "$WAKE_LOG")"
green "burst of 3 outcomes inside DEBOUNCE_SECS produced exactly one doorbell nudge"

[ "$(inbox_count)" = "3" ] || red "expected 3 coord-inbox/*.md files (one per outcome, unconditional on debounce); got $(inbox_count)"
green "burst of 3 outcomes produced 3 coord-inbox files despite the coalesced doorbell"

SKIP_COUNT=$(grep -c 'coord.wake.skip .*reason=debounce' "$EVENTS_LOG" 2>/dev/null || true)
[ "$SKIP_COUNT" = "2" ] || red "expected 2 debounce-skip events (outcomes 2 and 3); got $SKIP_COUNT. events.log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "events.log records the 2 coalesced outcomes as coord.wake.skip reason=debounce"

# ============================================================================
heading "Test 5: a busy-pending marker left over from an earlier defer does not cause a duplicate doorbell (self-review finding)"
# ============================================================================
# Race this guards against: outcome A busy-marks a pending doorbell; before
# coord_wake_busy_retry_pass's next tick, the pane goes idle AND outcome B
# arrives, pasting its OWN nudge directly (the idle/else branch in
# on_outcome). If that branch doesn't also clear the busy-pending marker,
# the next retry tick still finds it, sees the (now idle) pane, and
# delivers a SECOND, redundant nudge for a wake that already landed.
mkdir -p "$TEST_DIR/wt-issue-907/.swarm/tasks/done"
mkdir -p "$TEST_DIR/wt-issue-908/.swarm/tasks/done"
reset_state
set_pane_busy
sleep 0.3

COORD_WAKE_BUSY_RETRY_SECS=5 COORD_WAKE_BUSY_CEILING_SECS=900 DEBOUNCE_SECS=0 start_watcher "$TEST_DIR/watch-5.log"
echo '{"task_id":"t907","outcome":"ok"}' > "$TEST_DIR/wt-issue-907/.swarm/tasks/done/t907-907.ok.json"
poll_until 10 0.3 bash -c "grep -q 'coord.wake.defer ' '$EVENTS_LOG' 2>/dev/null" \
    || red "setup: busy-defer for outcome 907 never landed. watch log:
$(cat "$TEST_DIR/watch-5.log")"

# Pane goes idle and a second outcome lands immediately, well BEFORE the 5s
# busy-retry tick — it must paste its own nudge directly (idle branch) and
# clear the stale busy-pending marker from outcome 907 in the same step.
set_pane_idle
echo '{"task_id":"t908","outcome":"ok"}' > "$TEST_DIR/wt-issue-908/.swarm/tasks/done/t908-908.ok.json"
poll_until 10 0.3 bash -c "[ \"\$(grep -c 'WAKE:' '$WAKE_LOG')\" = '1' ]" \
    || red "outcome 908's direct idle-path wake never landed. wake.log:
$(cat "$WAKE_LOG")"

# Wait past the busy-retry tick (5s, started when the watcher booted —
# comfortably after outcome 908's near-immediate direct delivery above)
# plus margin — if the marker wasn't cleared, this is when the redundant
# second nudge would show up.
sleep 6
stop_watcher

[ "$(wake_count)" = "1" ] || red "expected exactly ONE doorbell nudge total — a stale busy-pending marker produced a duplicate. wake.log:
$(cat "$WAKE_LOG")"
green "a busy-pending marker cleared by a later direct (idle-path) wake does not cause a duplicate doorbell"

# ============================================================================
heading "Test 6: activity-poll finding — inbox-only, no doorbell at all"
# ============================================================================
reset_state
PROJECT_DIR_ACTIVITY="$TEST_DIR/activity-project"
mkdir -p "$PROJECT_DIR_ACTIVITY/.swarm"
git -C "$PROJECT_DIR_ACTIVITY" init -q
git -C "$PROJECT_DIR_ACTIVITY" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
INBOX_DIR_ACTIVITY="$PROJECT_DIR_ACTIVITY/.swarm/coord-inbox"
EVENTS_LOG_ACTIVITY="$PROJECT_DIR_ACTIVITY/.swarm/events.log"

PR_FIXTURE="$TEST_DIR/gh-pr-merged.tsv"
ISSUE_FIXTURE="$TEST_DIR/gh-issue-closed.tsv"
printf '9001\tActivity-poll probe\tfix/issue-9001\n' > "$PR_FIXTURE"
: > "$ISSUE_FIXTURE"
mkdir -p "$TEST_DIR/bin"
FAKE_GH="$TEST_DIR/bin/gh"
cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then cat "$PR_FIXTURE"; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then cat "$ISSUE_FIXTURE"; exit 0; fi
exit 0
EOF
chmod +x "$FAKE_GH"
export PATH="$TEST_DIR/bin:$PATH"

LLM_START="$FAKE_LLM_START" \
    SESSION_NAME="$SESSION_NAME" \
    WORKSPACE="$TEST_DIR" \
    WATCHER_AUTOCLOSE=0 \
    WATCH_OUTBOX=0 \
    WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 \
    WATCH_BG_VIOLATION_SWEEP_SECS=0 \
    WATCH_CHECK_ON_DONE=0 \
    WATCH_ACTIVITY_POLL_SECS=1 \
    COORD_WAKE_RETRY_SECS=0 \
    COORD_WAKE_BUSY_RETRY_SECS=30 \
    DEBOUNCE_SECS=0 \
    WATCHER_QUIET=1 \
    DRY_RUN=0 ONCE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR_ACTIVITY" > "$TEST_DIR/watch-5.log" 2>&1 &
WATCH_PID=$!

poll_until 20 0.5 bash -c "find '$INBOX_DIR_ACTIVITY' -maxdepth 1 -name '*.md' -type f 2>/dev/null | grep -q ." \
    || red "activity-poll finding never landed in coord-inbox. watch log:
$(cat "$TEST_DIR/watch-5.log")"
sleep 2
stop_watcher

grep -q 'WAKE:' "$WAKE_LOG" && red "activity-poll finding must NEVER call llm-start.sh (inbox-only, issue #430): $(cat "$WAKE_LOG")"
green "activity-poll finding produced no llm-start.sh call at all"

ACTIVITY_FILES=$(find "$INBOX_DIR_ACTIVITY" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
[ "$ACTIVITY_FILES" -ge 1 ] || red "expected at least one coord-inbox file for the activity-poll finding; got $ACTIVITY_FILES"
grep -rl 'PR #9001 merged' "$INBOX_DIR_ACTIVITY"/*.md >/dev/null 2>&1 \
    || red "expected the activity-poll inbox file to name the merged PR"
green "activity-poll finding landed in coord-inbox naming the merged PR"

grep -q 'coord.inbox.write .*trigger=activity_poll' "$EVENTS_LOG_ACTIVITY" \
    || red "expected coord.inbox.write trigger=activity_poll in events.log"
grep -q 'coord.wake ' "$EVENTS_LOG_ACTIVITY" 2>/dev/null && red "did not expect any coord.wake event for an activity-poll finding: $(cat "$EVENTS_LOG_ACTIVITY")"
green "events.log: coord.inbox.write trigger=activity_poll present, no coord.wake at all"

echo ""
green "All assertions passed (test-coordinator-inbox.sh)"
