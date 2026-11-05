#!/usr/bin/env bash
#
# test-watcher-split-mode.sh — issue #765 (ADR 0006): COORD_MODE=split.
#
# Part 1 drives scripts/coord-work-run.sh directly: runs.log line, single-flight
# lock, and the lock being released by a timed-out or killed run.
# Part 2 runs the REAL coordinator-watch.sh in split mode with a stub work-run
# command and checks: an urgent item starts a run at once, a batched item waits
# for the window, a trigger during a run starts nothing and the exit recheck
# picks the item up, and no typed text (tmux send-keys / paste / load-buffer,
# llm-start.sh) reaches any pane.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
RUN="$SCRIPT_DIR/../scripts/coord-work-run.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"
[ -x "$RUN" ] || red "coord-work-run.sh not executable: $RUN"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this test"
command -v flock >/dev/null 2>&1 || red "flock not found"

TEST_DIR=$(mktemp -d -t watcher-split-XXXXXX)
SESSION_NAME="test-split-$$"
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

# wait_for <secs> <cmd...>: poll a command every 0.2 s until it succeeds.
wait_for() {
    local secs="$1" i; shift
    for ((i = 0; i < secs * 5; i++)); do
        "$@" && return 0
        sleep 0.2
    done
    return 1
}

# ── Part 1: the run wrapper ─────────────────────────────────────────────────
logs_have() { grep -q "$1" "$P1"/.swarm/work-run/*.log 2>/dev/null; }
heading "coord-work-run.sh"
P1="$TEST_DIR/wrap"


mkdir -p "$P1/.swarm"
RUNS_LOG="$P1/.swarm/work-run/runs.log"

# 1a. A normal run: log file with the output, one usage line from stream-json.
COORD_WORK_RUN_CMD='echo "hello $1"; echo "{\"type\":\"result\",\"total_cost_usd\":0.25,\"usage\":{\"input_tokens\":7,\"output_tokens\":9,\"cache_read_input_tokens\":11}}"' \
    "$RUN" "$P1" "the-prompt" >/dev/null || red "1a: wrapper failed"
[ "$(wc -l < "$RUNS_LOG")" = 1 ] || red "1a: expected 1 runs.log line, got $(wc -l < "$RUNS_LOG")"
grep -q 'status=ok cost_usd=0.25 in=7 out=9 cache_read=11' "$RUNS_LOG" || red "1a: usage line wrong: $(cat "$RUNS_LOG")"
LOGF="$P1/.swarm/work-run/$(sed -E 's/.* log=//' "$RUNS_LOG")"
grep -q 'hello the-prompt' "$LOGF" || red "1a: run output not teed to its log"
[ -s "$P1/.swarm/work-run/last-start" ] || red "1a: last-start not stamped"
green "1a: run logged with usage line and output"

# 1b. Single flight: a second start while one runs exits 75 and starts nothing.
COORD_WORK_RUN_CMD='echo first-started; sleep 4' "$RUN" "$P1" p >/dev/null &
FIRST=$!
wait_for 5 logs_have first-started || red "1b: first run never started"
rc=0
COORD_WORK_RUN_CMD='echo SECOND-RAN' "$RUN" "$P1" p >/dev/null 2>&1 || rc=$?
[ "$rc" = 75 ] || red "1b: second start should exit 75, got $rc"
! grep -q SECOND-RAN "$P1"/.swarm/work-run/*.log || red "1b: second run executed"
wait "$FIRST" || true
green "1b: second start exits 75 and runs nothing"

# 1c. Timeout: exit 124, logged as timeout, lock free again even though the
# command left an orphan behind.
rc=0
TO_PIDS="$TEST_DIR/to-pids"
COORD_WORK_RUN_TIMEOUT_SECS=2 TO_PIDS="$TO_PIDS" COORD_WORK_RUN_CMD='sleep 7 & echo "$!" > "$TO_PIDS"; sleep 7' "$RUN" "$P1" p >/dev/null 2>&1 || rc=$?
[ "$rc" = 124 ] || red "1c: expected exit 124, got $rc"
tail -n 1 "$RUNS_LOG" | grep -q 'exit=124 status=timeout' || red "1c: timeout not logged: $(tail -n 1 "$RUNS_LOG")"
read -r TOPID < "$TO_PIDS"
! kill -0 "$TOPID" 2>/dev/null || red "1c: the timed-out run left a process behind"
[ -s "$P1/.swarm/work-run/retry-from" ] || red "1c: failed run did not leave retry-from"
rc=0
COORD_WORK_RUN_CMD='echo after-timeout' "$RUN" "$P1" p >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || red "1c: lock not released after a timeout (rc=$rc)"
[ ! -e "$P1/.swarm/work-run/retry-from" ] || red "1c: an ok run did not clear retry-from"
green "1c: timed-out run is logged and releases the lock"

# 1e. claude -p can report a failed run in its result line and still exit 0.
COORD_WORK_RUN_CMD='echo "{\"type\":\"result\",\"is_error\":true,\"total_cost_usd\":0.5}"' "$RUN" "$P1" p >/dev/null 2>&1 || true
tail -n 1 "$RUNS_LOG" | grep -q 'exit=0 status=error' || red "1e: is_error result not logged as error: $(tail -n 1 "$RUNS_LOG")"
[ -s "$P1/.swarm/work-run/retry-from" ] || red "1e: error result did not leave retry-from"
COORD_WORK_RUN_CMD='echo fine' "$RUN" "$P1" p >/dev/null 2>&1
[ ! -e "$P1/.swarm/work-run/retry-from" ] || red "1e: ok run did not clear retry-from"
green "1e: is_error result with exit 0 counts as a failed run"

# 1d. Killed (TERM to the wrapper): exit 143, logged as killed, lock free, and
# the command AND the process it started are really gone (not merely detached).
KPIDS="$TEST_DIR/kill-pids"
: > "$KPIDS"
KILL_PIDS="$KPIDS" COORD_WORK_RUN_CMD='sleep 30 & echo "$! $$" > "$KILL_PIDS"; echo killme-started; wait' \
    "$RUN" "$P1" p >/dev/null 2>&1 &
KPID=$!
wait_for 5 logs_have killme-started || red "1d: run never started"
read -r GRANDCHILD CMDPID < "$KPIDS"
kill -0 "$GRANDCHILD" 2>/dev/null || red "1d: test setup: grandchild not running"
kill -TERM "$KPID"
rc=0; wait "$KPID" || rc=$?
[ "$rc" = 143 ] || red "1d: expected exit 143, got $rc"
grep -q 'exit=143 status=killed' "$RUNS_LOG" || red "1d: kill not logged"
gone() { ! kill -0 "$GRANDCHILD" 2>/dev/null && ! kill -0 "$CMDPID" 2>/dev/null; }
wait_for 3 gone || red "1d: the killed run's processes are still alive (lock freed while the work continues)"
rc=0
COORD_WORK_RUN_CMD='echo after-kill' "$RUN" "$P1" p >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || red "1d: lock not released after a kill (rc=$rc)"
green "1d: killed run is logged, its processes are gone, the lock is free"

# ── Part 2: the watcher in split mode ───────────────────────────────────────
heading "coordinator-watch.sh COORD_MODE=split"

PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR/.swarm"
INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
RUN_DIR="$PROJECT_DIR/.swarm/work-run"

WAKE_LOG="$TEST_DIR/wake.log"
: > "$WAKE_LOG"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<EOF
#!/usr/bin/env bash
printf 'WAKE: %s\n' "\$*" >> "$WAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LLM_START"

# A tmux shim that records anything typed into a pane, then runs real tmux.
REAL_TMUX="$(command -v tmux)"
SHIM_DIR="$TEST_DIR/shim"
TYPED_LOG="$TEST_DIR/typed.log"
: > "$TYPED_LOG"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in
        send-keys|paste-buffer|load-buffer|set-buffer) printf 'TYPED: %s\n' "\$*" >> "$TYPED_LOG"; break ;;
    esac
done
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$SHIM_DIR/tmux"

tmux new-session -d -s "$SESSION_NAME" -n coordinator 2>/dev/null

# The stub "work run": archives what is in the inbox (a coordinator's triage),
# records start and end, and runs for the number of seconds in STUB_SECS_FILE.
STUB_RUNS="$TEST_DIR/stub-runs.log"
STUB_SECS_FILE="$TEST_DIR/stub-secs"
FAIL_FILE="$TEST_DIR/stub-fail"
FAIL_ALWAYS="$TEST_DIR/stub-fail-always"
STUB="$TEST_DIR/stub.sh"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "start \$(date +%s)" >> "$STUB_RUNS"
mkdir -p "$INBOX_DIR/processed"
if [ -e "$FAIL_FILE" ]; then [ -e "$FAIL_ALWAYS" ] || rm -f "$FAIL_FILE"; exit 1; fi
mv "$INBOX_DIR"/*.md "$INBOX_DIR/processed/" 2>/dev/null || true
sleep "\$(cat "$STUB_SECS_FILE")"
echo "end \$(date +%s)" >> "$STUB_RUNS"
EOF
chmod +x "$STUB"

# start_watcher <batch-secs>
start_watcher() {
    local batch="$1"
    # The mode lives only in the project's .swarm/.env (#767); the caller's env is ignored.
    printf 'COORD_MODE=%s\n' "${WATCH_MODE:-split}" > "$PROJECT_DIR/.swarm/.env"
    PATH="$SHIM_DIR:$PATH" \
        LLM_START="$FAKE_LLM_START" \
        COORD_WORK_RUN_CMD="bash $STUB" \
        COORD_WORK_RUN="${WORK_RUN_OVERRIDE:-$RUN}" \
        COORD_INBOX_BATCH_SECS="$batch" \
        COORD_SPLIT_TICK_SECS="${SPLIT_TICK:-1}" \
        COORD_WORK_RUN_RETRY_SECS=3 COORD_WORK_RUN_MAX_RETRIES=2 \
        SESSION_NAME="$SESSION_NAME" \
        WORKSPACE="$TEST_DIR" \
        WATCHER_AUTOCLOSE=0 WATCH_OUTBOX=0 WATCH_PR_POLL_SECS=0 \
        WATCH_ORPHAN_SWEEP_SECS=0 WATCH_BG_VIOLATION_SWEEP_SECS=0 \
        WATCH_ACTIVITY_POLL_SECS=0 WATCH_WORKTREE_SWEEP_SECS=0 \
        WATCH_PENDING_BRIEF_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 \
        AUTO_COMPACT=1 WORKER_AUTO_COMPACT=0 WORKER_AUTO_DELIVER=0 \
        WATCHER_STALE_CHECK=0 STALL_WAKE_SECS=0 \
        WATCHER_QUIET=1 DRY_RUN=0 ONCE=0 POLL_SECS=1 \
        ${WATCH_PREFIX:-} "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch.out" 2>&1 &
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
    : > "$STUB_RUNS"
    rm -f "$FAIL_FILE" "$FAIL_ALWAYS"
    rm -rf "$INBOX_DIR" "$RUN_DIR" "$PROJECT_DIR/.swarm/work-run.lock" \
           "$PROJECT_DIR/.swarm/coord-wake-last"
    rm -f "$EVENTS_LOG"
    mkdir -p "$INBOX_DIR" "$RUN_DIR"
}
# seed_last_start <secs-ago>: pretend a run started that long ago.
seed_last_start() { echo $(( $(date +%s) - $1 )) > "$RUN_DIR/last-start"; }
# drop <kind> <n>: an item as an outside producer would write it.
drop() {
    local f="$INBOX_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$1-$$-$2.md"
    echo "item $1 $2" > "$f.tmp" && mv "$f.tmp" "$f"
    # Optional <age-secs>: back-date the item so it is clearly older than the run
    # that the watcher starts for it (a run stamps its start minus one second).
    [ -z "${3:-}" ] || touch -d "$3 seconds ago" "$f"
}
runs_started() { grep -c '^start' "$STUB_RUNS" || true; }
runs_ended()   { grep -c '^end' "$STUB_RUNS" || true; }
started_ge() { [ "$(runs_started)" -ge "$1" ]; }
ended_ge() { [ "$(runs_ended)" -ge "$1" ]; }

# 2a. Urgent item: a run starts at once, although the batch window (600 s)
# has not elapsed.
reset_state; echo 1 > "$STUB_SECS_FILE"; seed_last_start 5
start_watcher 600
drop sidelined_worker 1
wait_for 8 started_ge 1 || red "2a: urgent item did not start a run"
[ "$(runs_started)" = 1 ] || red "2a: expected exactly 1 run, got $(runs_started)"
wait_for 6 ended_ge 1 || red "2a: run did not finish"
# The exit path (subshell after the wrapper returns) must itself have run: it
# logs the exit and does the recheck. The 1 s tick loop cannot fake this event.
wait_for 5 grep -q 'coord.workrun.exit .*rc=0' "$EVENTS_LOG" || red "2a: no coord.workrun.exit event after a successful run (exit subshell died?)"
green "2a: urgent item starts a run at once"

# 2b. Batched item: no run until the window (8 s after the last start) passes.
stop_watcher; reset_state; echo 1 > "$STUB_SECS_FILE"; seed_last_start 0
start_watcher 8
drop idle_capacity 2
sleep 4
[ "$(runs_started)" = 0 ] || red "2b: batched item started a run inside the window"
wait_for 10 started_ge 1 || red "2b: batched item never started a run after the window"
wait_for 6 ended_ge 1 || red "2b: run did not finish"
green "2b: batched item waits for the window, then runs"

# 2c. A trigger during a run starts nothing; the exit recheck picks it up.
stop_watcher; reset_state; echo 5 > "$STUB_SECS_FILE"; seed_last_start 5
SPLIT_TICK=30 start_watcher 600     # slow tick loop: only the exit recheck can start run 2
drop sidelined_worker 3
wait_for 8 started_ge 1 || red "2c: first run did not start"
sleep 1
drop sidelined_worker 4          # arrives mid-run, after the stub triaged
sleep 2
[ "$(runs_started)" = 1 ] || red "2c: a second run started while the first was going"
[ "$(runs_ended)" = 0 ] || red "2c: first run ended earlier than expected"
wait_for 12 started_ge 2 || red "2c: the item that arrived mid-run was dropped (no recheck run)"
grep -q 'coord.workrun.busy' "$EVENTS_LOG" || red "2c: busy trigger not logged"
grep -q 'coord.workrun.start trigger=exit_recheck' "$EVENTS_LOG" || red "2c: the second run was not started by the exit recheck"
wait_for 10 ended_ge 2 || red "2c: second run did not finish"
sleep 3
[ "$(runs_started)" = 2 ] || red "2c: expected exactly 2 runs in total, got $(runs_started)"
green "2c: mid-run trigger starts nothing; exit recheck runs the item once"

# 2e. A run that crashes before handling the inbox is retried after the
# back-off (its last-start already counts the items as announced).
stop_watcher; reset_state; echo 1 > "$STUB_SECS_FILE"; seed_last_start 5
touch "$FAIL_FILE"                # first run fails, later ones succeed
seed_last_start 20
start_watcher 600
drop sidelined_worker 5 3
wait_for 8 started_ge 1 || red "2e: run did not start"
sleep 1
[ "$(runs_started)" = 1 ] || red "2e: retried before the back-off"
wait_for 10 started_ge 2 || red "2e: the failed run's item was never retried"
wait_for 6 ended_ge 1 || red "2e: retry run did not finish"
sleep 4
[ "$(runs_started)" = 2 ] || red "2e: expected 2 runs, got $(runs_started)"
[ ! -e "$RUN_DIR/retry-from" ] || red "2e: retry-from not cleared after the ok run"
green "2e: failed run is retried once after the back-off"

# 2e2. Issue #774: the item that triggered a run lands in the run's own start
# second (NOT back-dated, unlike 2e). A run that fails must not see it as
# unannounced again and relaunch at once: the back-off applies.
stop_watcher; reset_state; echo 1 > "$STUB_SECS_FILE"
touch "$FAIL_FILE"                # first run fails, later ones succeed
seed_last_start 20
start_watcher 600
drop sidelined_worker 11          # no age: same second as the run's start
wait_for 8 started_ge 1 || red "2e2: run did not start"
wait_for 5 grep -q 'coord.workrun.exit .*rc=1' "$EVENTS_LOG" || red "2e2: failed run's exit not logged"
sleep 1                           # exit recheck and several 1 s ticks, all inside the 3 s back-off
[ "$(runs_started)" = 1 ] || red "2e2: same-second item skipped the back-off ($(runs_started) runs)"
wait_for 10 started_ge 2 || red "2e2: the failed run's item was never retried"
wait_for 6 ended_ge 1 || red "2e2: retry run did not finish"
sleep 4
[ "$(runs_started)" = 2 ] || red "2e2: expected 2 runs, got $(runs_started)"
green "2e2: an item in the run's start second gets the back-off, not an instant relaunch"

# 2f. A run that always fails stops being retried after the cap.
stop_watcher; reset_state; echo 1 > "$STUB_SECS_FILE"; seed_last_start 5
touch "$FAIL_FILE" "$FAIL_ALWAYS"
seed_last_start 20
start_watcher 600
drop sidelined_worker 6 3
wait_for 25 started_ge 3 || red "2f: expected the first run plus 2 retries, got $(runs_started)"
sleep 8
[ "$(runs_started)" = 3 ] || red "2f: retries did not stop at the cap: $(runs_started) runs"
grep -q 'coord.workrun.gave_up' "$EVENTS_LOG" || red "2f: giving up not logged"
green "2f: always-failing run is retried at most COORD_WORK_RUN_MAX_RETRIES times"

# 2g. A wrapper that dies before stamping a run (here: exits 1 at once) must
# not be relaunched in a loop: the watcher applies the same back-off and cap.
DEAD_WRAPPER="$TEST_DIR/dead-wrapper.sh"
printf '#!/usr/bin/env bash\necho dead >&2\nexit 1\n' > "$DEAD_WRAPPER"; chmod +x "$DEAD_WRAPPER"
stop_watcher; reset_state; echo 1 > "$STUB_SECS_FILE"; seed_last_start 20
WORK_RUN_OVERRIDE="$DEAD_WRAPPER" start_watcher 600
drop sidelined_worker 7 3
sleep 14
n_starts="$(grep -c 'coord.workrun.start' "$EVENTS_LOG" || true)"
[ "$n_starts" = 3 ] || red "2g: a dead wrapper was started $n_starts times (want 1 + 2 retries)"
grep -q 'wrapper_did_not_start' "$EVENTS_LOG" || red "2g: dead wrapper not logged"
grep -q 'coord.workrun.gave_up' "$EVENTS_LOG" || red "2g: giving up not logged"
green "2g: a wrapper that dies before running is backed off and capped, not looped"

# 2h. Stopping the watcher mid-run must not let the exit recheck start a new run.
stop_watcher; reset_state; echo 4 > "$STUB_SECS_FILE"; seed_last_start 5
start_watcher 600
drop sidelined_worker 8
wait_for 8 started_ge 1 || red "2h: run did not start"
sleep 1
drop sidelined_worker 9          # would be picked up by the exit recheck
stop_watcher
wait_for 8 ended_ge 1 || red "2h: run did not finish after the watcher stopped"
sleep 3
[ "$(runs_started)" = 1 ] || red "2h: a run was started on behalf of a stopped watcher"
green "2h: no run is started after the watcher has stopped"

# 2i. A hard kill of the watcher's whole process group (what the watcher's own
# staleness self-restart does) must not strand the run: the run keeps its lock
# (no second run starts) and, if it dies too, the items are retried.
stop_watcher; reset_state; echo 6 > "$STUB_SECS_FILE"; seed_last_start 5
WATCH_PREFIX=setsid start_watcher 600; unset WATCH_PREFIX
drop sidelined_worker 10
wait_for 8 started_ge 1 || red "2i: run did not start"
kill -KILL -- "-$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true; unset WATCH_PID
sleep 1
[ -s "$RUN_DIR/retry-from" ] || red "2i: no retry marker while the run is in flight"
RUNNING=$(( $(runs_started) - $(runs_ended) ))
[ "$RUNNING" = 1 ] || red "2i: the run did not survive the watcher's group kill"
wait_for 10 ended_ge 1 || red "2i: the surviving run never finished"
[ "$(runs_started)" = 1 ] || red "2i: a second run started"
no_retry_marker() { [ ! -e "$RUN_DIR/retry-from" ]; }
wait_for 5 no_retry_marker || red "2i: an ok run left the retry marker"
green "2i: a watcher group kill leaves the run, its lock and its retry marker intact"

# 2j. (#767) The split loop is always started and reads the mode from .swarm/.env
# on every tick. A watcher started resident: the loop does nothing and logs
# nothing (no work-run events, no split timer line, no output), and flipping the
# file to split starts runs without restarting the watcher.
stop_watcher; reset_state; echo 1 > "$STUB_SECS_FILE"; seed_last_start 5
WATCH_MODE=resident start_watcher 600
sleep 4   # several 1 s ticks
[ "$(runs_started)" = 0 ] || red "2j: resident watcher started a work run"
! grep -qE 'coord\.workrun|coord_mode=split|split_mode' "$EVENTS_LOG" 2>/dev/null || red "2j: resident watcher logged split events: $(grep -E 'coord\.workrun|coord_mode=split|split_mode' "$EVENTS_LOG" | head -3)"
! grep -qE 'command not found|ERROR:|WARN:|coord_mode=split|split_mode|workrun' "$TEST_DIR/watch.out" || red "2j: resident watcher printed errors or split output: $(grep -E 'command not found|ERROR:|WARN:|coord_mode=split|split_mode|workrun' "$TEST_DIR/watch.out" | head -3)"
kill -0 "$WATCH_PID" 2>/dev/null || red "2j: watcher died"
printf 'COORD_MODE=split\n' > "$PROJECT_DIR/.swarm/.env"
drop sidelined_worker 20
wait_for 8 started_ge 1 || red "2j: flipping .swarm/.env to split did not start a run (watcher not restarted)"
green "2j: resident loop is silent; a flip to split takes effect without a watcher restart"

# 2d. Nothing was typed anywhere, in any case above (split mode, AUTO_COMPACT=1
# set on purpose), and the old doorbell was never invoked.
[ ! -s "$TYPED_LOG" ] || red "2d: text was typed into a pane: $(head -3 "$TYPED_LOG")"
[ ! -s "$WAKE_LOG" ] || red "2d: llm-start.sh doorbell ran in split mode: $(head -3 "$WAKE_LOG")"
! grep -q 'coord.wake ' "$EVENTS_LOG" || red "2d: a typed coord.wake was logged"
green "2d: no typed text reached any pane; llm-start.sh never called"

stop_watcher
echo
green "all split-mode tests passed"
