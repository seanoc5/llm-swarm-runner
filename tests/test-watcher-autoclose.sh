#!/usr/bin/env bash
#
# test-watcher-autoclose.sh — Non-LLM shape test for the WATCHER_AUTOCLOSE
# feature of coordinator-watch.sh (issue #32).
#
# Acceptance from #32:
#   - coordinator-watch.sh invokes kill-finished-workers.sh before coord.wake
#   - WATCHER_AUTOCLOSE env var (default 1) controls the behavior
#   - Outcome arrival + already-merged PR → window auto-killed →
#     next outcome's wake dispatches into the freed slot
#
# Strategy: stub kill-finished-workers.sh + llm-start.sh so we can observe
# whether and in what order they were called per outcome event, without
# touching real tmux/gh/git state. Drop outcome JSONs into a fake worktree
# layout (WORKSPACE/wt-issue-N/.swarm/tasks/done/) the watcher polls.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"

TEST_DIR=$(mktemp -d -t watcher-autoclose-XXXXXX)
cleanup() {
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────── Fixture: project + worktrees ───────────────────────

# coordinator-watch.sh expects WORKSPACE to be the parent of PROJECT_DIR and
# scans WORKSPACE/wt-issue-*/.swarm/tasks/done/. We don't need a real git
# repo — the watcher only cares about the directory layout.
PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR/.swarm"
mkdir -p "$TEST_DIR/wt-issue-42/.swarm/tasks/done"
mkdir -p "$TEST_DIR/wt-issue-43/.swarm/tasks/done"

# ────────────────────── Stubs: kill-finished + llm-start ──────────────────────

# Stub kill-finished-workers.sh: record argv + a timestamp so we can assert
# order vs the coordinator wake. Sleep briefly so timestamps differ.
KILL_LOG="$TEST_DIR/kill.log"
FAKE_KILL="$TEST_DIR/fake-kill-finished-workers.sh"
cat > "$FAKE_KILL" <<EOF
#!/usr/bin/env bash
printf '%s  KILL: %s\n' "\$(date +%s%N)" "\$*" >> "$KILL_LOG"
exit 0
EOF
chmod +x "$FAKE_KILL"

# Stub llm-start.sh: record argv + timestamp.
WAKE_LOG="$TEST_DIR/wake.log"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<EOF
#!/usr/bin/env bash
printf '%s  WAKE: %s\n' "\$(date +%s%N)" "\$*" >> "$WAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LLM_START"

# Helper: start watcher in background with given WATCHER_AUTOCLOSE value.
# Returns PID via global. Uses ONCE=1 so it exits after first wake.
start_watcher() {
    local autoclose="$1" logfile="$2"
    WATCHER_AUTOCLOSE="$autoclose" \
        KILL_FINISHED="$FAKE_KILL" \
        LLM_START="$FAKE_LLM_START" \
        DRY_RUN=0 ONCE=1 POLL_SECS=1 DEBOUNCE_SECS=0 \
        "$WATCH" "$PROJECT_DIR" > "$logfile" 2>&1 &
    WATCH_PID=$!
    # Let the watcher baseline existing outcomes before we drop a new one
    sleep 1.5
}

# Helper: wait for watcher to exit (it should after first wake under ONCE=1)
wait_for_watcher_exit() {
    local i
    for ((i=0; i<20; i++)); do
        if ! kill -0 "$WATCH_PID" 2>/dev/null; then break; fi
        sleep 0.5
    done
    wait "$WATCH_PID" 2>/dev/null || true
    unset WATCH_PID
}

# ============================================================================
heading "Test 1: WATCHER_AUTOCLOSE=1 (default) — kill-finished-workers fires before wake"
# ============================================================================
: > "$KILL_LOG"
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"

start_watcher 1 "$TEST_DIR/watch-1.log"

# Drop a NEW outcome (simulates "worker just finished a task")
echo '{"task_id":"t42","outcome":"ok"}' > "$TEST_DIR/wt-issue-42/.swarm/tasks/done/t42.ok.json"

wait_for_watcher_exit

[ -s "$KILL_LOG" ] || red "kill-finished-workers.sh stub was NOT invoked (autoclose=1 should call it). Watch log:
$(cat "$TEST_DIR/watch-1.log")"
[ -s "$WAKE_LOG" ] || red "llm-start.sh stub was NOT invoked. Watch log:
$(cat "$TEST_DIR/watch-1.log")"
green "both kill-finished-workers.sh and llm-start.sh were invoked"

# Assert order: kill timestamp < wake timestamp
KILL_TS=$(awk 'NR==1 { print $1 }' "$KILL_LOG")
WAKE_TS=$(awk 'NR==1 { print $1 }' "$WAKE_LOG")
[ -n "$KILL_TS" ] && [ -n "$WAKE_TS" ] || red "missing timestamps (kill='$KILL_TS' wake='$WAKE_TS')"
[ "$KILL_TS" -lt "$WAKE_TS" ] \
    || red "kill-finished-workers.sh should run BEFORE coord.wake (kill=$KILL_TS wake=$WAKE_TS)"
green "kill-finished-workers.sh ran BEFORE coord.wake (autoclose then dispatch)"

# Assert the documented argv: --pr-finalized --with-worktree --yes
grep -q -- '--pr-finalized' "$KILL_LOG" \
    || red "expected --pr-finalized in kill stub argv; got: $(cat "$KILL_LOG")"
grep -q -- '--with-worktree' "$KILL_LOG" \
    || red "expected --with-worktree in kill stub argv; got: $(cat "$KILL_LOG")"
grep -q -- '--yes' "$KILL_LOG" \
    || red "expected --yes in kill stub argv; got: $(cat "$KILL_LOG")"
green "kill stub called with --pr-finalized --with-worktree --yes (terminal-PR mode)"

# Assert the events log recorded watch.autoclose
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
[ -f "$EVENTS_LOG" ] || red "events.log not created"
grep -q '^.*watch\.autoclose ' "$EVENTS_LOG" \
    || red "expected 'watch.autoclose' event in events.log; got:
$(cat "$EVENTS_LOG")"
grep -q '^.*coord\.wake ' "$EVENTS_LOG" \
    || red "expected 'coord.wake' event in events.log"
green "events.log recorded watch.autoclose + coord.wake"

# ============================================================================
heading "Test 2: WATCHER_AUTOCLOSE=0 — kill-finished-workers NOT invoked"
# ============================================================================
: > "$KILL_LOG"
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"

start_watcher 0 "$TEST_DIR/watch-2.log"

# Drop a NEW outcome in a different worktree (so it isn't ignored as baseline)
echo '{"task_id":"t43","outcome":"ok"}' > "$TEST_DIR/wt-issue-43/.swarm/tasks/done/t43.ok.json"

wait_for_watcher_exit

[ ! -s "$KILL_LOG" ] || red "kill-finished-workers.sh stub WAS invoked despite autoclose=0:
$(cat "$KILL_LOG")"
[ -s "$WAKE_LOG" ] || red "llm-start.sh stub was NOT invoked. Watch log:
$(cat "$TEST_DIR/watch-2.log")"
green "autoclose=0: kill stub skipped, coord.wake still fired"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
if [ -f "$EVENTS_LOG" ] && grep -q '^.*watch\.autoclose ' "$EVENTS_LOG"; then
    red "watch.autoclose should not appear in events.log when autoclose=0"
fi
green "events.log correctly omits watch.autoclose when WATCHER_AUTOCLOSE=0"

# ============================================================================
heading "Test 3: smooth-flow contract — sequential outcomes each trigger autoclose"
# ============================================================================
# Simulates the issue #32 scenario: outcome arrives → autoclose reaps the
# parked+merged worker → coordinator wakes into a freed slot. With our stubs,
# we verify the watcher calls autoclose+wake per outcome (not just once).
: > "$KILL_LOG"
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-44/.swarm/tasks/done"

# First outcome — watcher with ONCE=1 will exit after the first wake fires.
start_watcher 1 "$TEST_DIR/watch-3a.log"
echo '{"task_id":"t44","outcome":"ok"}' > "$TEST_DIR/wt-issue-44/.swarm/tasks/done/t44.ok.json"
wait_for_watcher_exit

first_kill=$(wc -l < "$KILL_LOG")
first_wake=$(wc -l < "$WAKE_LOG")
[ "$first_kill" -ge 1 ] || red "first outcome: kill not invoked"
[ "$first_wake" -ge 1 ] || red "first outcome: wake not invoked"

# Second outcome in a new worktree — start a fresh watcher run.
mkdir -p "$TEST_DIR/wt-issue-45/.swarm/tasks/done"
start_watcher 1 "$TEST_DIR/watch-3b.log"
echo '{"task_id":"t45","outcome":"ok"}' > "$TEST_DIR/wt-issue-45/.swarm/tasks/done/t45.ok.json"
wait_for_watcher_exit

second_kill=$(wc -l < "$KILL_LOG")
second_wake=$(wc -l < "$WAKE_LOG")
[ "$second_kill" -gt "$first_kill" ] \
    || red "second outcome did not trigger another kill-finished-workers call (kill log lines: $first_kill → $second_kill)"
[ "$second_wake" -gt "$first_wake" ] \
    || red "second outcome did not trigger another coord.wake (wake log lines: $first_wake → $second_wake)"
green "each outcome triggers its own autoclose pass + wake (smooth-flow loop)"

# ============================================================================
heading "Test 4: err outcomes also trigger autoclose"
# ============================================================================
# Per the 2026-05-17 follow-up on issue #32: autoclose must fire on .err.json
# as well, not just .ok.json (covers worker abort, /quit, etc.).
: > "$KILL_LOG"
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-46/.swarm/tasks/done"

start_watcher 1 "$TEST_DIR/watch-4.log"
echo '{"task_id":"t46","outcome":"err","exit_code":1}' \
    > "$TEST_DIR/wt-issue-46/.swarm/tasks/done/t46.err.json"
wait_for_watcher_exit

[ -s "$KILL_LOG" ] \
    || red ".err.json outcome did not trigger autoclose. Watch log:
$(cat "$TEST_DIR/watch-4.log")"
[ -s "$WAKE_LOG" ] || red ".err.json outcome did not trigger coord.wake"
green ".err.json outcomes trigger autoclose + wake (parity with .ok.json)"

# ────────────────────────── Done ──────────────────────────

heading "All watcher-autoclose tests passed"
echo "  WATCHER_AUTOCLOSE=1: kill-finished-workers runs BEFORE coord.wake"
echo "  WATCHER_AUTOCLOSE=0: kill-finished-workers is skipped, wake still fires"
echo "  Argv: --pr-finalized --with-worktree --yes (terminal-PR mode)"
echo "  Events log: watch.autoclose + coord.wake recorded per outcome"
echo "  Smooth-flow: each outcome triggers its own autoclose pass"
echo "  .err.json outcomes also trigger autoclose (parity with .ok.json)"
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
