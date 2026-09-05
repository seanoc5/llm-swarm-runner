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

# Tests 10-12 below build their fixture worktrees directly in the flat
# layout (<git-fixture>/wt-issue-N) and exercise the REAL kill-worktree.sh
# against them — pin the grouping so it resolves the same path regardless
# of the shipped .env.example default (project, since issue #271) or an
# operator's project-grouped shell env.
export SWARM_WORKTREE_GROUPING=flat

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
# Prints the real script's "Done. Closed N window(s)." summary — the watcher
# parses it for the killed=N count and suppresses the watch.autoclose event
# on killed=0 passes (see make_kill_stub / Test 1b).
KILL_LOG="$TEST_DIR/kill.log"
FAKE_KILL="$TEST_DIR/fake-kill-finished-workers.sh"
make_kill_stub() {
    local summary="$1"
    cat > "$FAKE_KILL" <<EOF
#!/usr/bin/env bash
printf '%s  KILL: %s\n' "\$(date +%s%N)" "\$*" >> "$KILL_LOG"
echo "$summary"
exit 0
EOF
    chmod +x "$FAKE_KILL"
}
make_kill_stub "Done. Closed 1 window(s)."

# Stub reap-orphan-worktrees.sh: issue #225's orphan_sweep_pass invokes this
# (via $REAP_ORPHAN) on WATCH_ORPHAN_SWEEP_SECS to clear window-less
# worktrees kill-finished-workers.sh can never reach. Prints the real
# script's "Done. Reaped N worktree(s) ..." summary — orphan_sweep_pass
# parses it for the reaped=N count, same technique used for KILL_LOG above.
REAP_ORPHAN_LOG="$TEST_DIR/reap-orphan.log"
FAKE_REAP_ORPHAN="$TEST_DIR/fake-reap-orphan-worktrees.sh"
make_reap_orphan_stub() {
    local summary="$1"
    cat > "$FAKE_REAP_ORPHAN" <<EOF
#!/usr/bin/env bash
printf '%s  REAP: %s\n' "\$(date +%s%N)" "\$*" >> "$REAP_ORPHAN_LOG"
echo "$summary"
exit 0
EOF
    chmod +x "$FAKE_REAP_ORPHAN"
}
make_reap_orphan_stub "Done. Reaped 0 worktree(s) (skipped 0 of 0 scanned)."

# Stub llm-start.sh: record argv + timestamp.
WAKE_LOG="$TEST_DIR/wake.log"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<EOF
#!/usr/bin/env bash
printf '%s  WAKE: %s\n' "\$(date +%s%N)" "\$*" >> "$WAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LLM_START"

# Stub gh: pr_poll_pass's only gh call is `gh pr list --state all --limit 500
# --json headRefName,state,number --jq '...'`, which (via --jq) already
# returns tab-separated "branch\tstate\tnumber" lines — so the stub just
# cats a fixture file tests populate before triggering a poll tick.
#
# Also handles `gh pr view <branch> --json state -q .state` (issue #181's
# pr_state_for_worktree, called from maybe_run_check) by looking the branch
# up in the same fixture file — keeps both call sites consistent off one
# piece of test state.
GH_PR_LIST_FILE="$TEST_DIR/gh-pr-list.tsv"
: > "$GH_PR_LIST_FILE"
mkdir -p "$TEST_DIR/bin"
FAKE_GH="$TEST_DIR/bin/gh"
cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
    cat "$GH_PR_LIST_FILE"
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    branch="\$3"
    awk -F'\t' -v b="\$branch" '\$1 == b { print \$2; found=1 } END { exit found ? 0 : 1 }' "$GH_PR_LIST_FILE"
    exit \$?
fi
exit 0
EOF
chmod +x "$FAKE_GH"

# Stub tmux: issue #225's has_live_window() calls `tmux list-windows -t
# $SESSION_NAME -F '#W'` to decide whether kill-finished-workers.sh could
# possibly reap a terminal-PR worktree (it only ever sees LIVE windows).
# TMUX_WINDOWS_FILE starts empty — the default "no live windows" state,
# matching this sandbox's real tmux (no server running) — so by default
# every worktree looks window-less/orphaned to pr_poll_pass. Tests that
# exercise the REAP path populate it with "iss-N" for their issue first;
# the new orphan-path tests (17+) rely on the empty default.
# has-session always fails (exit 1) — mirrors "no live coordinator session"
# so maybe_auto_compact's coordinator_pane_state() stays "absent", same as
# the pre-#225 behavior with no tmux stub at all.
TMUX_WINDOWS_FILE="$TEST_DIR/tmux-windows.txt"
: > "$TMUX_WINDOWS_FILE"
FAKE_TMUX="$TEST_DIR/bin/tmux"
cat > "$FAKE_TMUX" <<EOF
#!/usr/bin/env bash
case "\$1" in
    list-windows) cat "$TMUX_WINDOWS_FILE" ;;
    has-session)  exit 1 ;;
    *)            exit 0 ;;
esac
EOF
chmod +x "$FAKE_TMUX"

export PATH="$TEST_DIR/bin:$PATH"

# Helper: start watcher in background with given WATCHER_AUTOCLOSE value.
# Returns PID via global. Uses ONCE=1 so it exits after first wake.
#
# WATCH_PR_POLL_SECS / WATCH_ORPHAN_SWEEP_SECS / WATCH_CHECK_ON_DONE default
# to 0 here (feature off) so tests 1-4 — which predate issues #119/#225 —
# stay hermetic and don't spin up the new background timer loop. Tests
# targeting #119/#225 export these (and ONCE=0, since the pr-poll/orphan-
# sweep/check-on-done triggers aren't tied to on_outcome's ONCE=1 exit) as a
# prefix before calling start_watcher. REAP_ORPHAN always defaults to the
# stub (never the real script) so a test that forgets to override it can't
# accidentally shell out to the genuine reap-orphan-worktrees.sh.
start_watcher() {
    local autoclose="$1" logfile="$2"
    WATCHER_AUTOCLOSE="$autoclose" \
        WATCHER_AUTOCLOSE_MODE="${WATCHER_AUTOCLOSE_MODE:-}" \
        KILL_FINISHED="$FAKE_KILL" \
        REAP_ORPHAN="${REAP_ORPHAN:-$FAKE_REAP_ORPHAN}" \
        LLM_START="$FAKE_LLM_START" \
        WORKSPACE="$TEST_DIR" \
        WATCH_PR_POLL_SECS="${WATCH_PR_POLL_SECS:-0}" \
        WATCH_ORPHAN_SWEEP_SECS="${WATCH_ORPHAN_SWEEP_SECS:-0}" \
        WATCH_CHECK_ON_DONE="${WATCH_CHECK_ON_DONE:-0}" \
        CHECK_RUNNER="${CHECK_RUNNER:-}" \
        DRY_RUN=0 ONCE="${ONCE:-1}" POLL_SECS=1 DEBOUNCE_SECS=0 \
        "$WATCH" "$PROJECT_DIR" > "$logfile" 2>&1 &
    WATCH_PID=$!
    # Let the watcher baseline existing outcomes before we drop a new one
    sleep 1.5
}

# Helper: stop a background (ONCE=0) watcher started via start_watcher.
stop_watcher() {
    [ -n "${WATCH_PID:-}" ] || return 0
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    unset WATCH_PID
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

# Assert the documented default argv (issue #237: WATCHER_AUTOCLOSE_MODE
# defaults to "merged" -> --merged-only, not --pr-finalized).
grep -q -- '--merged-only' "$KILL_LOG" \
    || red "expected --merged-only in kill stub argv (default WATCHER_AUTOCLOSE_MODE=merged); got: $(cat "$KILL_LOG")"
grep -q -- '--pr-finalized' "$KILL_LOG" \
    && red "did not expect --pr-finalized in kill stub argv under default WATCHER_AUTOCLOSE_MODE=merged; got: $(cat "$KILL_LOG")"
grep -q -- '--with-worktree' "$KILL_LOG" \
    || red "expected --with-worktree in kill stub argv; got: $(cat "$KILL_LOG")"
grep -q -- '--yes' "$KILL_LOG" \
    || red "expected --yes in kill stub argv; got: $(cat "$KILL_LOG")"
green "kill stub called with --merged-only --with-worktree --yes (default merged mode)"

# Assert the events log recorded watch.autoclose with the parsed kill count
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
[ -f "$EVENTS_LOG" ] || red "events.log not created"
grep -q '^.*watch\.autoclose .*killed=1' "$EVENTS_LOG" \
    || red "expected 'watch.autoclose ... killed=1' event in events.log; got:
$(cat "$EVENTS_LOG")"
grep -q '^.*coord\.wake ' "$EVENTS_LOG" \
    || red "expected 'coord.wake' event in events.log"
green "events.log recorded watch.autoclose killed=1 + coord.wake"

# ============================================================================
heading "Test 1b: no-op reap pass — watch.autoclose event suppressed (killed=0)"
# ============================================================================
: > "$KILL_LOG"
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
make_kill_stub "Nothing to kill given current filters."

start_watcher 1 "$TEST_DIR/watch-1b.log"
echo '{"task_id":"t42b","outcome":"ok"}' > "$TEST_DIR/wt-issue-42/.swarm/tasks/done/t42b.ok.json"
wait_for_watcher_exit

[ -s "$KILL_LOG" ] || red "kill stub was NOT invoked on the no-op pass. Watch log:
$(cat "$TEST_DIR/watch-1b.log")"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
if [ -f "$EVENTS_LOG" ] && grep -q '^.*watch\.autoclose ' "$EVENTS_LOG"; then
    red "watch.autoclose should be suppressed when the reaper killed nothing; got:
$(cat "$EVENTS_LOG")"
fi
grep -q '^.*coord\.wake ' "$EVENTS_LOG" 2>/dev/null \
    || red "expected 'coord.wake' event on the no-op pass"
green "killed=0 pass: reaper still ran, watch.autoclose suppressed, coord.wake intact"

# Restore the killing stub for the remaining tests.
make_kill_stub "Done. Closed 1 window(s)."

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

# ============================================================================
heading "Test 5: pr-poll backstop reaps a merged PR with NO outcome.json ever arriving (issue #119)"
# ============================================================================
# The bug: on_outcome only fires from a NEW outcome.json write, but
# outcome.json is written once (usually right after the PR opens) — a PR
# merging later (parked interactive worker, or the user batch-merging while
# away) never produces a second one, so the reap pass never re-runs. This
# drives the fix directly: no outcome.json is EVER dropped in this test, so
# any reap must come from the independent WATCH_PR_POLL_SECS timer.
: > "$KILL_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-50/.swarm/tasks/done"
printf 'fix/issue-50\tMERGED\t101\n' > "$GH_PR_LIST_FILE"
# issue #225: a live iss-50 window is what makes this reapable via
# kill-finished-workers.sh in the first place — without it, has_live_window
# would (correctly) route this into the orphan_no_window path instead.
echo "iss-50" > "$TMUX_WINDOWS_FILE"

ONCE=0 WATCH_PR_POLL_SECS=2 start_watcher 1 "$TEST_DIR/watch-5.log"
sleep 5
stop_watcher

[ -s "$KILL_LOG" ] || red "pr-poll backstop did not invoke kill-finished-workers.sh for a merged PR with no outcome.json. Watch log:
$(cat "$TEST_DIR/watch-5.log")"
green "pr-poll backstop reaped a merged-PR worktree without any outcome.json ever arriving"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
grep -q 'watch\.pr_poll ' "$EVENTS_LOG" 2>/dev/null \
    || red "expected 'watch.pr_poll' event in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'trigger=pr_poll' "$EVENTS_LOG" \
    || red "expected watch.autoclose trigger=pr_poll in events.log"
green "events.log records watch.pr_poll + watch.autoclose(trigger=pr_poll) — additive to the outcome trigger"

# ============================================================================
heading "Test 6: check-on-done runs the resolved check once a status file signals ready-for-review"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-60/.swarm/tasks/status"
mkdir -p "$TEST_DIR/wt-issue-60/.swarm/tasks/done"
echo 'echo ok' > "$TEST_DIR/wt-issue-60/.swarm/check.sh"

CHECK_RUNNER_LOG="$TEST_DIR/check-runner.log"
: > "$CHECK_RUNNER_LOG"
FAKE_CHECK_RUNNER="$TEST_DIR/fake-check-runner.sh"
cat > "$FAKE_CHECK_RUNNER" <<EOF
#!/usr/bin/env bash
printf 'RAN: %s :: %s\n' "\$1" "\$2" >> "$CHECK_RUNNER_LOG"
exit 0
EOF
chmod +x "$FAKE_CHECK_RUNNER"

rm -f "$PROJECT_DIR/.swarm/events.log"
echo '{"task_id":"t60","state":"ready-for-review","pr":77,"ts":"2026-07-19T00:00:00Z"}' \
    > "$TEST_DIR/wt-issue-60/.swarm/tasks/status/t60.json"

ONCE=0 WATCH_CHECK_ON_DONE=1 CHECK_RUNNER="$FAKE_CHECK_RUNNER" \
    start_watcher 0 "$TEST_DIR/watch-6.log"
sleep 4
stop_watcher

[ -s "$CHECK_RUNNER_LOG" ] || red "check-on-done did not invoke CHECK_RUNNER for a ready-for-review status file. Watch log:
$(cat "$TEST_DIR/watch-6.log")"
grep -q "wt-issue-60" "$CHECK_RUNNER_LOG" \
    || red "CHECK_RUNNER invoked with unexpected worktree arg: $(cat "$CHECK_RUNNER_LOG")"
grep -q "check.sh" "$CHECK_RUNNER_LOG" \
    || red "expected the standing .swarm/check.sh to resolve as the check command: $(cat "$CHECK_RUNNER_LOG")"
green "check-on-done resolved the standing .swarm/check.sh and ran it via CHECK_RUNNER"

CHECK_JSON="$TEST_DIR/wt-issue-60/.swarm/tasks/status/t60.check.json"
[ -f "$CHECK_JSON" ] || red "expected $CHECK_JSON to be written"
grep -q '"state":"pass"' "$CHECK_JSON" || red "expected check.json state=pass; got: $(cat "$CHECK_JSON")"
green "check.json recorded state=pass"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
grep -q 'watch\.check_on_done' "$EVENTS_LOG" \
    || red "expected watch.check_on_done event in events.log"
green "events.log records watch.check_on_done"

# ============================================================================
heading "Test 7: status-file signal + PR-open backstop both firing → exactly ONE check run"
# ============================================================================
# The atomic-claim requirement: both done-signals can fire in the same
# poll window (2s status-file scan and the WATCH_PR_POLL_SECS gh-poll can
# land close together). maybe_run_check must converge both callers on the
# same claim key (re-derived from the worktree's own status file) so only
# one of them wins the mkdir claim.
: > "$CHECK_RUNNER_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-70/.swarm/tasks/status"
mkdir -p "$TEST_DIR/wt-issue-70/.swarm/tasks/done"
echo 'echo ok' > "$TEST_DIR/wt-issue-70/.swarm/check.sh"
echo '{"task_id":"t70","state":"ready-for-review","pr":88,"ts":"2026-07-19T00:00:00Z"}' \
    > "$TEST_DIR/wt-issue-70/.swarm/tasks/status/t70.json"
printf 'fix/issue-70\tOPEN\t88\n' > "$GH_PR_LIST_FILE"

ONCE=0 WATCH_PR_POLL_SECS=2 WATCH_CHECK_ON_DONE=1 CHECK_RUNNER="$FAKE_CHECK_RUNNER" \
    start_watcher 0 "$TEST_DIR/watch-7.log"
sleep 6
stop_watcher

RUNS=$(grep -c "wt-issue-70" "$CHECK_RUNNER_LOG" || true)
[ "$RUNS" -eq 1 ] \
    || red "expected exactly 1 check run for issue #70 (status-file + PR-open both fired); got $RUNS. Log:
$(cat "$CHECK_RUNNER_LOG")"
green "status-file signal and PR-open backstop converge on one claim key — exactly one check run, no double-fire"

# ============================================================================
heading "Test 8: pane echo (issue #38) — default (WATCHER_QUIET unset) echoes formatted event lines"
# ============================================================================
: > "$KILL_LOG"
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-80/.swarm/tasks/done"

start_watcher 1 "$TEST_DIR/watch-8.log"
echo '{"task_id":"t80","outcome":"ok"}' > "$TEST_DIR/wt-issue-80/.swarm/tasks/done/t80.ok.json"
wait_for_watcher_exit

grep -q '^\[watch\] .* worker\.finish' "$TEST_DIR/watch-8.log" \
    || red "expected a [watch] ... worker.finish line in watcher stdout; got:
$(cat "$TEST_DIR/watch-8.log")"
grep -q '^\[watch\] .* coord\.wake ' "$TEST_DIR/watch-8.log" \
    || red "expected a [watch] ... coord.wake line in watcher stdout"
green "default pane echo formats worker.finish + coord.wake to stdout"

sleep 0.5
if pgrep -f "tail -n 1 -F.*${PROJECT_DIR}/.swarm/events.log" >/dev/null 2>&1; then
    red "pane-echo tail process leaked after watcher exit"
fi
green "pane-echo tail process does not leak after watcher exit"

# ============================================================================
heading "Test 9: WATCHER_QUIET=1 suppresses the pane echo entirely"
# ============================================================================
: > "$KILL_LOG"
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-81/.swarm/tasks/done"

WATCHER_QUIET=1 start_watcher 1 "$TEST_DIR/watch-9.log"
echo '{"task_id":"t81","outcome":"ok"}' > "$TEST_DIR/wt-issue-81/.swarm/tasks/done/t81.ok.json"
wait_for_watcher_exit

if grep -q '^\[watch\]' "$TEST_DIR/watch-9.log"; then
    red "WATCHER_QUIET=1 should suppress all [watch]-formatted lines; got:
$(cat "$TEST_DIR/watch-9.log")"
fi
green "WATCHER_QUIET=1 produces zero [watch] lines (events.log still records everything)"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
grep -q '^.*worker\.finish ' "$EVENTS_LOG" \
    || red "events.log should still record worker.finish even when pane echo is quiet"
green "events.log unaffected by WATCHER_QUIET"

# ============================================================================
heading "Test 10-12: kill-worktree.sh's reap-side check-claim guard (issue #181)"
# ============================================================================
# These exercise the REAL kill-worktree.sh (not the FAKE_KILL stub used
# above) against a real git repo + worktree — it's the actual place that
# does `git worktree remove --force`, so it's the actual place the #181
# race (reap yanking a worktree out from under a running check-on-done)
# has to be fixed.
KILL_WT_SCRIPT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
[ -x "$KILL_WT_SCRIPT" ] || red "kill-worktree.sh not executable: $KILL_WT_SCRIPT"

GIT_FIXTURE="$TEST_DIR/git-fixture"
GIT_PROJECT="$GIT_FIXTURE/proj"
mkdir -p "$GIT_PROJECT"
git init -q "$GIT_PROJECT"
git -C "$GIT_PROJECT" config user.email test@example.com
git -C "$GIT_PROJECT" config user.name "Test"
echo hello > "$GIT_PROJECT/README.md"
git -C "$GIT_PROJECT" add README.md
git -C "$GIT_PROJECT" commit -q -m init
DEFAULT_BRANCH="$(git -C "$GIT_PROJECT" symbolic-ref --quiet --short HEAD)"

# --- Test 10: an active (fresh) check-claim defers removal -----------------
git -C "$GIT_PROJECT" worktree add -q -b fix/issue-90 "$GIT_FIXTURE/wt-issue-90" "$DEFAULT_BRANCH"
CLAIM_90="$GIT_FIXTURE/wt-issue-90/.swarm/tasks/status/t90.check-claim"
mkdir -p "$CLAIM_90"

set +e
"$KILL_WT_SCRIPT" 90 "$GIT_PROJECT" > "$TEST_DIR/kill-wt-defer.log" 2>&1
KW_RC=$?
set -e

[ -d "$GIT_FIXTURE/wt-issue-90" ] \
    || red "worktree #90 was removed despite an active check-claim (the #181 race). Output:
$(cat "$TEST_DIR/kill-wt-defer.log")"
[ "$KW_RC" -ne 0 ] \
    || red "kill-worktree.sh exited 0 while deferring — callers can't tell defer from success"
green "kill-worktree.sh deferred removal while a check-claim was active (worktree preserved, exit $KW_RC)"

# --- Test 11: releasing the claim lets the retry succeed --------------------
rmdir "$CLAIM_90"
"$KILL_WT_SCRIPT" 90 "$GIT_PROJECT" > "$TEST_DIR/kill-wt-proceed.log" 2>&1

[ ! -d "$GIT_FIXTURE/wt-issue-90" ] \
    || red "worktree #90 still present after the check-claim was released. Output:
$(cat "$TEST_DIR/kill-wt-proceed.log")"
green "kill-worktree.sh removed the worktree once the check-claim was released (retry-next-pass works)"

# --- Test 12: a stale (crashed-check) claim does not block reaping forever --
git -C "$GIT_PROJECT" worktree add -q -b fix/issue-91 "$GIT_FIXTURE/wt-issue-91" "$DEFAULT_BRANCH"
STALE_CLAIM="$GIT_FIXTURE/wt-issue-91/.swarm/tasks/status/t91.check-claim"
mkdir -p "$STALE_CLAIM"
touch -d '@1000000000' "$STALE_CLAIM" 2>/dev/null || touch -t 200109090100 "$STALE_CLAIM"

CHECK_CLAIM_STALE_SECS=5 "$KILL_WT_SCRIPT" 91 "$GIT_PROJECT" > "$TEST_DIR/kill-wt-stale.log" 2>&1

[ ! -d "$GIT_FIXTURE/wt-issue-91" ] \
    || red "a stale check-claim (age >> TTL) still blocked removal — a crashed check would wedge the worktree forever. Output:
$(cat "$TEST_DIR/kill-wt-stale.log")"
green "a stale check-claim (past CHECK_CLAIM_STALE_SECS) does not block reaping — crashed checks can't wedge a worktree"

# ============================================================================
heading "Test 13: check-on-done skips spawning a check once the PR is already MERGED (issue #181)"
# ============================================================================
# The merge already validated the work — running the check now (and holding
# the reap-blocking claim while it runs) would be pure waste. This is the
# other half of the #181 fix: the check-side skip that complements
# kill-worktree.sh's reap-side defer above.
: > "$CHECK_RUNNER_LOG"
: > "$KILL_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-95/.swarm/tasks/status"
mkdir -p "$TEST_DIR/wt-issue-95/.swarm/tasks/done"
echo 'echo ok' > "$TEST_DIR/wt-issue-95/.swarm/check.sh"
echo '{"task_id":"t95","state":"ready-for-review","pr":99,"ts":"2026-07-20T00:00:00Z"}' \
    > "$TEST_DIR/wt-issue-95/.swarm/tasks/status/t95.json"
printf 'fix/issue-95\tMERGED\t99\n' > "$GH_PR_LIST_FILE"
echo "iss-95" > "$TMUX_WINDOWS_FILE"   # issue #225 — see Test 5's comment

ONCE=0 WATCH_PR_POLL_SECS=2 WATCH_CHECK_ON_DONE=1 CHECK_RUNNER="$FAKE_CHECK_RUNNER" \
    start_watcher 1 "$TEST_DIR/watch-13.log"
sleep 5
stop_watcher

if grep -q "wt-issue-95" "$CHECK_RUNNER_LOG"; then
    red "check-on-done spawned a check for a worktree whose PR is already MERGED (should skip — the merge already validated the work). Log:
$(cat "$CHECK_RUNNER_LOG")"
fi
green "check-on-done did not spawn a check for an already-MERGED PR"

CHECK_JSON_95="$TEST_DIR/wt-issue-95/.swarm/tasks/status/t95.check.json"
[ -f "$CHECK_JSON_95" ] || red "expected $CHECK_JSON_95 to be written even when the check is skipped"
grep -q '"state":"skipped"' "$CHECK_JSON_95" \
    || red "expected check.json state=skipped for a terminal-PR skip; got: $(cat "$CHECK_JSON_95")"
green "check.json recorded state=skipped with the pr_terminal reason"

[ -s "$KILL_LOG" ] || red "reap did not fire for the merged PR despite the check being skipped"
green "reap still proceeds normally when the check is skipped for a terminal PR"

# ============================================================================
heading "Test 14: check-claim is released on completion and does not cause a re-run (issue #181)"
# ============================================================================
# The reap-side guard (Tests 10-12) treats claim-dir existence as "in
# flight" — so the claim MUST be released once the check actually finishes,
# or a completed check would wedge its own worktree forever. But since the
# claim is also part of the double-run guard, releasing it must not let a
# later poll tick re-claim and re-run an already-resolved task (that's what
# the *.check.json terminal-state check inside maybe_run_check now exists
# for — see coordinator-watch.sh).
: > "$CHECK_RUNNER_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-96/.swarm/tasks/status"
mkdir -p "$TEST_DIR/wt-issue-96/.swarm/tasks/done"
echo 'echo ok' > "$TEST_DIR/wt-issue-96/.swarm/check.sh"
echo '{"task_id":"t96","state":"ready-for-review","pr":96,"ts":"2026-07-20T00:00:00Z"}' \
    > "$TEST_DIR/wt-issue-96/.swarm/tasks/status/t96.json"
printf 'fix/issue-96\tOPEN\t96\n' > "$GH_PR_LIST_FILE"

ONCE=0 WATCH_CHECK_ON_DONE=1 CHECK_RUNNER="$FAKE_CHECK_RUNNER" \
    start_watcher 0 "$TEST_DIR/watch-14.log"
sleep 5
stop_watcher

RUNS=$(grep -c "wt-issue-96" "$CHECK_RUNNER_LOG" || true)
[ "$RUNS" -eq 1 ] \
    || red "expected exactly 1 check run for issue #96 across multiple 2s poll ticks (claim release must not cause a re-run); got $RUNS. Log:
$(cat "$CHECK_RUNNER_LOG")"
green "check ran exactly once across multiple poll ticks despite the claim being released after completion"

if [ -d "$TEST_DIR/wt-issue-96/.swarm/tasks/status/t96.check-claim" ]; then
    red "check-claim dir still present after the check completed — a reap pass would be blocked forever"
fi
green "check-claim released promptly after completion (reap is free to proceed)"

# ============================================================================
heading "Test 15: pr-poll ignores a terminal PR that predates the freshly provisioned worktree (issue #185)"
# ============================================================================
# The bug: gh pr list/view returns a branch's most recent PR in ANY state.
# A recycled branch name whose PREVIOUS PR is MERGED/CLOSED makes a
# brand-new worktree on that branch look "finalized" 3s after provisioning
# — the fresh worker gets reaped before it does anything. GH_PR_LIST_FILE
# now carries a 4th column (createdAt); an old CLOSED PR with a createdAt
# far in the past must NOT trigger a reap for a worktree that (by
# definition, in this test) was just created.
#
# issue #237: exercised via CLOSED-state PRs specifically to drive the
# predates-worktree logic, which is orthogonal to WATCHER_AUTOCLOSE_MODE —
# so this test pins WATCHER_AUTOCLOSE_MODE=finalized (the pre-#237 default)
# to keep testing that logic on its own. The new default (mode=merged)
# leaving CLOSED-without-merge alone regardless of predates is covered
# separately below.
: > "$KILL_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-100/.swarm/tasks/done"
printf 'fix/issue-100\tCLOSED\t101\t2020-01-01T00:00:00Z\n' > "$GH_PR_LIST_FILE"
: > "$TMUX_WINDOWS_FILE"   # irrelevant here — stale-PR check short-circuits before has_live_window

ONCE=0 WATCH_PR_POLL_SECS=2 WATCHER_AUTOCLOSE_MODE=finalized start_watcher 1 "$TEST_DIR/watch-15.log"
sleep 5
stop_watcher

[ ! -s "$KILL_LOG" ] \
    || red "reap fired for a freshly provisioned worktree whose only terminal PR predates it (the #185 bug). Kill log:
$(cat "$KILL_LOG")"
green "a stale terminal PR (predates the worktree) did NOT trigger a reap"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
grep -q 'reason=stale_pr_ignored' "$EVENTS_LOG" 2>/dev/null \
    || red "expected watch.pr_poll reason=stale_pr_ignored in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "events.log recorded the stale-PR-ignored reason"

# Positive control: a terminal PR created AFTER the worktree still reaps
# normally — the fix must not over-suppress genuine terminal PRs.
: > "$KILL_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-102/.swarm/tasks/done"
NOW_ISO="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf 'fix/issue-102\tCLOSED\t103\t%s\n' "$NOW_ISO" > "$GH_PR_LIST_FILE"
echo "iss-102" > "$TMUX_WINDOWS_FILE"   # issue #225 — see Test 5's comment

ONCE=0 WATCH_PR_POLL_SECS=2 WATCHER_AUTOCLOSE_MODE=finalized start_watcher 1 "$TEST_DIR/watch-15b.log"
sleep 5
stop_watcher

[ -s "$KILL_LOG" ] \
    || red "a genuinely fresh terminal PR (created after the worktree) failed to trigger reap under WATCHER_AUTOCLOSE_MODE=finalized — fix is over-suppressing. Watch log:
$(cat "$TEST_DIR/watch-15b.log")"
green "a terminal PR created after the worktree still triggers reap under finalized mode (fix isn't over-suppressing)"

# ============================================================================
heading "Test 15c: default WATCHER_AUTOCLOSE_MODE=merged leaves a fresh CLOSED-without-merge PR untouched (issue #237)"
# ============================================================================
# The new default: unlike Test 15b (finalized mode), a CLOSED PR — even one
# created well after the worktree, so pr_predates_worktree would NOT
# suppress it under finalized mode — must never trigger a reap when
# WATCHER_AUTOCLOSE_MODE defaults to "merged". The window/worktree/branch
# are left fully intact for operator inspection.
: > "$KILL_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-103/.swarm/tasks/done"
NOW_ISO_103="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf 'fix/issue-103\tCLOSED\t104\t%s\n' "$NOW_ISO_103" > "$GH_PR_LIST_FILE"
echo "iss-103" > "$TMUX_WINDOWS_FILE"

ONCE=0 WATCH_PR_POLL_SECS=2 WATCHER_AUTOCLOSE_MODE= start_watcher 1 "$TEST_DIR/watch-15c.log"
sleep 5
stop_watcher

[ ! -s "$KILL_LOG" ] \
    || red "kill-finished-workers.sh fired for a CLOSED-without-merge PR under the default WATCHER_AUTOCLOSE_MODE=merged — should be left open for inspection. Kill log:
$(cat "$KILL_LOG")"
green "default mode=merged leaves a fresh CLOSED-without-merge PR's worktree/window untouched"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
if grep -q 'reason=terminal_pr_detected' "$EVENTS_LOG" 2>/dev/null; then
    red "terminal_pr_detected should not fire for a CLOSED-without-merge PR under default mode=merged"
fi
green "no terminal_pr_detected logged for the CLOSED-without-merge PR under default mode=merged"

# Positive control on the same worktree/branch: switching to
# WATCHER_AUTOCLOSE_MODE=finalized reaps it, proving the worktree really was
# reap-eligible all along and mode=merged (not some other suppression) is
# what held it back above.
: > "$KILL_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
ONCE=0 WATCH_PR_POLL_SECS=2 WATCHER_AUTOCLOSE_MODE=finalized start_watcher 1 "$TEST_DIR/watch-15c-control.log"
sleep 5
stop_watcher

[ -s "$KILL_LOG" ] \
    || red "positive control failed: the same CLOSED-without-merge PR did not reap under WATCHER_AUTOCLOSE_MODE=finalized. Watch log:
$(cat "$TEST_DIR/watch-15c-control.log")"
green "the same worktree reaps normally under WATCHER_AUTOCLOSE_MODE=finalized — confirms mode=merged was the reason it was spared above"

# ============================================================================
heading "Test 16: kill-finished-workers.sh --pr-finalized preserves a fresh worktree with a stale closed PR (issue #185)"
# ============================================================================
# Drives the fix at the layer that actually removes worktrees —
# kill-finished-workers.sh's pr_is_finalized — rather than through the
# coordinator-watch.sh stub used above. Uses the real git-fixture repo from
# Tests 10-12 (GIT_PROJECT/GIT_FIXTURE/DEFAULT_BRANCH already set up).
#
# tmux is stubbed (not a live session — see the CI workflow's exclusion
# rationale for test-coordinator-auto-compact.sh/test-e2e-swarm.sh, the
# only two suites here that DO spin up a real tmux server) so this stays
# CI-safe: has-session/list-windows/kill-window are the only calls
# kill-finished-workers.sh + kill-worktree.sh make on the --pr-finalized
# --with-worktree --idle-min 0 path (no parked/idle pane inspection).
KFW_SCRIPT="$SCRIPT_DIR/../scripts/kill-finished-workers.sh"
[ -x "$KFW_SCRIPT" ] || red "kill-finished-workers.sh not executable: $KFW_SCRIPT"

git -C "$GIT_PROJECT" worktree add -q -b fix/issue-120 "$GIT_FIXTURE/wt-issue-120" "$DEFAULT_BRANCH"
git -C "$GIT_PROJECT" worktree add -q -b fix/issue-121 "$GIT_FIXTURE/wt-issue-121" "$DEFAULT_BRANCH"

# gh stub for kill-finished-workers.sh's `gh pr view <branch> --json
# state,createdAt -q '"\(.state)\t\(.createdAt)"'` call — emulate gh's -q
# output shape directly (tab-separated state + createdAt) rather than
# parsing --json/-q, since only one query shape is ever issued here.
GH_VIEW_FILE="$TEST_DIR/gh-pr-view-kfw.tsv"
NOW_ISO_121="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
{
    printf 'fix/issue-120\tCLOSED\t2020-01-01T00:00:00Z\n'
    printf 'fix/issue-121\tCLOSED\t%s\n' "$NOW_ISO_121"
} > "$GH_VIEW_FILE"

mkdir -p "$TEST_DIR/bin-kfw"
FAKE_GH_KFW="$TEST_DIR/bin-kfw/gh"
cat > "$FAKE_GH_KFW" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    branch="\$3"
    awk -F'\t' -v b="\$branch" '\$1 == b { printf "%s\t%s\n", \$2, \$3; found=1 } END { exit found ? 0 : 1 }' "$GH_VIEW_FILE"
    exit \$?
fi
exit 1
EOF
chmod +x "$FAKE_GH_KFW"

# kill-worktree.sh (invoked by --with-worktree) derives its own
# SESSION_NAME as "llm-$(basename PROJECT_DIR)" — not overridable — so
# rather than pass --session and fight that, just let both scripts agree
# by running from $GIT_PROJECT (basename "proj" -> session "llm-proj").
FAKE_TMUX_KFW="$TEST_DIR/bin-kfw/tmux"
cat > "$FAKE_TMUX_KFW" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    has-session)   exit 0 ;;
    list-windows)  printf 'iss-120\niss-121\n' ;;
    kill-window)   exit 0 ;;
esac
exit 0
EOF
chmod +x "$FAKE_TMUX_KFW"

(
    cd "$GIT_PROJECT"
    PATH="$TEST_DIR/bin-kfw:$PATH" \
        "$KFW_SCRIPT" --idle-min 0 --pr-finalized --with-worktree --yes
) > "$TEST_DIR/kfw-run.log" 2>&1 || true

[ -d "$GIT_FIXTURE/wt-issue-120" ] \
    || red "worktree #120 was removed despite its only terminal PR predating the worktree (the #185 bug). Output:
$(cat "$TEST_DIR/kfw-run.log")"
green "kill-finished-workers.sh --pr-finalized preserved a fresh worktree whose terminal PR predates it"

[ ! -d "$GIT_FIXTURE/wt-issue-121" ] \
    || red "worktree #121 (genuinely closed PR created after the worktree) was NOT reaped — fix is over-suppressing. Output:
$(cat "$TEST_DIR/kfw-run.log")"
green "kill-finished-workers.sh --pr-finalized still reaps a worktree whose terminal PR postdates it"

# ============================================================================
heading "Test 17: pr-poll logs orphan_no_window ONCE for a window-less terminal-PR worktree, never reaps it (issue #225)"
# ============================================================================
# The bug: a worktree whose tmux window is already gone (session restart,
# docker daemon restart — cf. #217) has a MERGED/CLOSED PR forever, so every
# pr_poll_pass tick used to re-detect it and re-run kill-finished-workers.sh
# — which can never actually kill anything, since it only iterates LIVE
# iss-N windows. Reproduces that: a terminal PR, no matching entry in
# TMUX_WINDOWS_FILE (no live window), WATCH_ORPHAN_SWEEP_SECS=0 so this test
# isolates pr_poll_pass's own behavior from the sweep. Across several poll
# ticks, kill-finished-workers.sh must never fire, and the orphan_no_window
# reason must be logged exactly once (not once per tick).
: > "$KILL_LOG"
: > "$TMUX_WINDOWS_FILE"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-200/.swarm/tasks/done"
printf 'fix/issue-200\tMERGED\t201\n' > "$GH_PR_LIST_FILE"

ONCE=0 WATCH_PR_POLL_SECS=1 WATCH_ORPHAN_SWEEP_SECS=0 start_watcher 1 "$TEST_DIR/watch-17.log"
sleep 6
stop_watcher

[ ! -s "$KILL_LOG" ] \
    || red "kill-finished-workers.sh fired for a window-less worktree — it can never reap this (issue #225). Kill log:
$(cat "$KILL_LOG")"
green "kill-finished-workers.sh was never invoked for the window-less terminal-PR worktree"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
ORPHAN_LINES=$(grep -c 'reason=orphan_no_window issue=200' "$EVENTS_LOG" 2>/dev/null || true)
[ "$ORPHAN_LINES" -eq 1 ] \
    || red "expected exactly 1 orphan_no_window log line across multiple poll ticks; got $ORPHAN_LINES. Events log:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "orphan_no_window logged exactly once despite multiple WATCH_PR_POLL_SECS ticks (no spam)"

if grep -q 'reason=terminal_pr_detected' "$EVENTS_LOG" 2>/dev/null; then
    red "terminal_pr_detected (the reap_hit trigger) should not fire for a window-less worktree"
fi
green "reap_hit was never set for the window-less worktree — orphan_sweep_pass is the only path that can clear it"

# ============================================================================
heading "Test 18: orphan_sweep_pass runs reap-orphan-worktrees.sh on WATCH_ORPHAN_SWEEP_SECS, gated by WATCHER_AUTOCLOSE (issue #225)"
# ============================================================================
# This is the actual fix for Test 17's scenario: a slower, independent timer
# that walks worktree DIRECTORIES (not tmux windows) via
# reap-orphan-worktrees.sh, so window-less orphans eventually get cleared.
: > "$REAP_ORPHAN_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
make_reap_orphan_stub "Done. Reaped 2 worktree(s) (skipped 1 of 3 scanned)."

ONCE=0 WATCH_PR_POLL_SECS=0 WATCH_ORPHAN_SWEEP_SECS=1 \
    REAP_ORPHAN="$FAKE_REAP_ORPHAN" start_watcher 1 "$TEST_DIR/watch-18a.log"
sleep 4
stop_watcher

[ -s "$REAP_ORPHAN_LOG" ] \
    || red "reap-orphan-worktrees.sh stub was NOT invoked with WATCH_ORPHAN_SWEEP_SECS=1 WATCHER_AUTOCLOSE=1. Watch log:
$(cat "$TEST_DIR/watch-18a.log")"
grep -q -- '--pr-finalized' "$REAP_ORPHAN_LOG" \
    || red "expected --pr-finalized in reap-orphan stub argv; got: $(cat "$REAP_ORPHAN_LOG")"
grep -q -- '--yes' "$REAP_ORPHAN_LOG" \
    || red "expected --yes in reap-orphan stub argv; got: $(cat "$REAP_ORPHAN_LOG")"
green "orphan_sweep_pass invoked reap-orphan-worktrees.sh --pr-finalized --yes on its own timer"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
grep -q '^.*watch\.orphan_sweep .*reaped=2' "$EVENTS_LOG" \
    || red "expected 'watch.orphan_sweep ... reaped=2' event in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "events.log recorded watch.orphan_sweep with the parsed reaped=N count"

: > "$REAP_ORPHAN_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
ONCE=0 WATCH_PR_POLL_SECS=0 WATCH_ORPHAN_SWEEP_SECS=1 \
    REAP_ORPHAN="$FAKE_REAP_ORPHAN" start_watcher 0 "$TEST_DIR/watch-18b.log"
sleep 4
stop_watcher

[ ! -s "$REAP_ORPHAN_LOG" ] \
    || red "orphan sweep ran despite WATCHER_AUTOCLOSE=0 — it should be gated by the same autoclose switch as the window-based reap. Log:
$(cat "$REAP_ORPHAN_LOG")"
green "WATCHER_AUTOCLOSE=0 disables the orphan sweep too (single kill switch for all auto-reaping)"

make_reap_orphan_stub "Done. Reaped 0 worktree(s) (skipped 0 of 0 scanned)."

# ============================================================================
heading "Test 19: done detection synthesizes an outcome file and the coordinator wake fires (issue #314)"
# ============================================================================
# The regression this guards: interactive workers never exit claude, so
# worker-listener.sh never writes done/*.ok.json — the only trigger for the
# worker-finished coord.wake. maybe_run_check must synthesize the outcome
# the moment it wins the check-claim, and the normal on_outcome pipeline
# (worker.finish event + wake) must fire off the synthesized file. No
# check.sh / WORKER_CHECK_CMD here on purpose — the check resolving to
# "skipped" must NOT suppress synthesis (it runs before check resolution).
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
: > "$GH_PR_LIST_FILE"
mkdir -p "$TEST_DIR/wt-issue-190/.swarm/tasks/status"
mkdir -p "$TEST_DIR/wt-issue-190/.swarm/tasks/done"
echo '{"task_id":"t190","state":"ready-for-review","pr":99,"ts":"2026-08-27T00:00:00Z"}' \
    > "$TEST_DIR/wt-issue-190/.swarm/tasks/status/t190.json"

ONCE=0 WATCH_CHECK_ON_DONE=1 start_watcher 0 "$TEST_DIR/watch-19.log"
sleep 5
stop_watcher

SYNTH_JSON="$TEST_DIR/wt-issue-190/.swarm/tasks/done/t190-190.ok.json"
[ -f "$SYNTH_JSON" ] || red "expected synthesized outcome at $SYNTH_JSON. Watch log:
$(cat "$TEST_DIR/watch-19.log")"
grep -q '"synthesized":true' "$SYNTH_JSON" \
    || red "synthesized outcome should carry \"synthesized\":true; got: $(cat "$SYNTH_JSON")"
green "done detection synthesized done/t190-190.ok.json (issue suffix appended for on_outcome's parser)"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
grep -q 'watch\.outcome\.synth .*issue=190' "$EVENTS_LOG" \
    || red "expected watch.outcome.synth event; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'worker\.finish .*issue=190' "$EVENTS_LOG" \
    || red "expected worker.finish for the synthesized outcome; got:
$(cat "$EVENTS_LOG")"
grep -q 'coord\.wake .*issue=190' "$EVENTS_LOG" \
    || red "expected coord.wake off the synthesized outcome; got:
$(cat "$EVENTS_LOG")"
[ -s "$WAKE_LOG" ] || red "llm-start.sh stub was NOT invoked — the synthesized outcome did not produce a wake. Watch log:
$(cat "$TEST_DIR/watch-19.log")"
green "synthesized outcome rode the normal pipeline: worker.finish + coord.wake + llm-start invoked"

# ============================================================================
heading "Test 19b: synthesis skips when the listener already wrote an outcome (issue #314)"
# ============================================================================
# Headless workers DO exit, so the listener's own outcome write still
# happens — synthesis must not clobber it or double-wake.
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-191/.swarm/tasks/status"
mkdir -p "$TEST_DIR/wt-issue-191/.swarm/tasks/done"
echo '{"task_id":"t191","outcome":"ok"}' > "$TEST_DIR/wt-issue-191/.swarm/tasks/done/t191.ok.json"
echo '{"task_id":"t191","state":"ready-for-review","pr":100,"ts":"2026-08-27T00:00:00Z"}' \
    > "$TEST_DIR/wt-issue-191/.swarm/tasks/status/t191.json"

ONCE=0 WATCH_CHECK_ON_DONE=1 start_watcher 0 "$TEST_DIR/watch-19b.log"
sleep 5
stop_watcher

[ ! -f "$TEST_DIR/wt-issue-191/.swarm/tasks/done/t191-191.ok.json" ] \
    || red "synthesis should have been skipped — a listener-written t191.ok.json already exists"
grep -q 'watch\.outcome\.synth\.skip .*reason=outcome_exists' "$PROJECT_DIR/.swarm/events.log" \
    || red "expected watch.outcome.synth.skip reason=outcome_exists; got:
$(cat "$PROJECT_DIR/.swarm/events.log" 2>/dev/null || echo '(missing)')"
green "existing listener outcome suppresses synthesis (watch.outcome.synth.skip reason=outcome_exists)"

# ============================================================================
heading "Test 19c: WATCH_SYNTH_OUTCOME=0 disables synthesis entirely (issue #314)"
# ============================================================================
: > "$WAKE_LOG"
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$TEST_DIR/wt-issue-192/.swarm/tasks/status"
mkdir -p "$TEST_DIR/wt-issue-192/.swarm/tasks/done"
echo '{"task_id":"t192","state":"ready-for-review","pr":101,"ts":"2026-08-27T00:00:00Z"}' \
    > "$TEST_DIR/wt-issue-192/.swarm/tasks/status/t192.json"

ONCE=0 WATCH_CHECK_ON_DONE=1 WATCH_SYNTH_OUTCOME=0 start_watcher 0 "$TEST_DIR/watch-19c.log"
sleep 5
stop_watcher

[ ! -f "$TEST_DIR/wt-issue-192/.swarm/tasks/done/t192-192.ok.json" ] \
    || red "WATCH_SYNTH_OUTCOME=0 should disable synthesis"
[ ! -s "$WAKE_LOG" ] || red "no wake expected with synthesis disabled and no real outcome; got: $(cat "$WAKE_LOG")"
green "WATCH_SYNTH_OUTCOME=0 kill switch works (no synthesis, no wake)"

# ────────────────────────── Done ──────────────────────────

heading "All watcher-autoclose tests passed"
echo "  WATCHER_AUTOCLOSE=1: kill-finished-workers runs BEFORE coord.wake"
echo "  WATCHER_AUTOCLOSE=0: kill-finished-workers is skipped, wake still fires"
echo "  Argv: --merged-only --with-worktree --yes (default WATCHER_AUTOCLOSE_MODE=merged)"
echo "  Events log: watch.autoclose + coord.wake recorded per outcome"
echo "  Smooth-flow: each outcome triggers its own autoclose pass"
echo "  .err.json outcomes also trigger autoclose (parity with .ok.json)"
echo "  #119: pr-poll backstop reaps merged PRs with no outcome.json at all"
echo "  #119: check-on-done runs the resolved check on a ready-for-review status file"
echo "  #119: status-file + PR-open signals converge on one atomic claim (no double-run)"
echo "  #38: default pane echo formats events.log lines to stdout; no leaked tail process"
echo "  #38: WATCHER_QUIET=1 suppresses pane echo without affecting events.log"
echo "  #181: kill-worktree.sh defers removal while a check-claim is active, retries after release"
echo "  #181: a stale (crashed-check) claim past its TTL does not block reaping forever"
echo "  #181: check-on-done skips spawning a check once the PR is already MERGED/CLOSED"
echo "  #181: the claim is released on completion without causing a double-run"
echo "  #185: pr-poll ignores a terminal PR that predates the freshly provisioned worktree"
echo "  #185: kill-finished-workers.sh --pr-finalized preserves a fresh worktree with a stale closed PR"
echo "  #225: pr-poll never reaps a window-less worktree; logs orphan_no_window once, not every tick"
echo "  #225: orphan_sweep_pass runs reap-orphan-worktrees.sh on its own timer, gated by WATCHER_AUTOCLOSE"
echo "  #237: WATCHER_AUTOCLOSE_MODE=merged (default) leaves CLOSED-without-merge workers open; =finalized reaps MERGED-or-CLOSED like before"
echo "  #314: done detection synthesizes done/*.ok.json (parked workers never exit claude) and the normal coord.wake fires off it"
echo "  #314: synthesis skipped when a listener-written outcome exists; WATCH_SYNTH_OUTCOME=0 disables it"
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
