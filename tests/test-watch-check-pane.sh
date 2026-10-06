#!/usr/bin/env bash
#
# test-watch-check-pane.sh — Real-tmux acceptance test for issue #550
# (check-on-done as a pane inside iss-N, explicit worker-pane targeting,
# reap closes checks, one check per completion, idle pass/fail marker).
#
# Unlike test-watcher-autoclose.sh (which stubs tmux entirely and so never
# exercises real pane/window mechanics), this test runs coordinator-watch.sh
# against a REAL tmux server on a private `-L` socket, so it can assert the
# actual pane layout execute_check() produces.
#
# Covers the issue's three acceptance tests:
#   1. With iss-N present, a check opens as a PANE in it, the worker pane
#      (index 0) stays active, and an explicit .0-targeted capture still
#      reaches the worker pane even after the operator selects the check
#      pane.
#   2. Reaping issue N (kill-worktree.sh) leaves no chk-N window or pane
#      behind.
#   3. One done signal -> exactly one check run and one events.log terminal
#      line; a second, later completion for the same issue REPLACES the
#      check pane/window rather than stacking a second one (the "chk-999
#      x2, chk-1000 x3" pile-up the issue's evidence section describes).
#
# Also covers the fallback window case (no iss-N window to host a pane in)
# and its own replace-not-stack + idle-marker behavior.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"
[ -x "$KILL_WT" ] || red "kill-worktree.sh not executable: $KILL_WT"

REAL_TMUX="$(command -v tmux)" || red "tmux not installed"
command -v git >/dev/null || red "git not installed"
command -v jq  >/dev/null || red "jq not installed (status_poll_pass requires it)"

export SWARM_WORKTREE_GROUPING=flat

TEST_DIR=$(mktemp -d -t watch-chk-pane-XXXXXX)
TEST_SOCK="wcp-test-$$"
cleanup() {
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
    [ -n "${WATCH_PID:-}" ] && wait "$WATCH_PID" 2>/dev/null || true
    "$REAL_TMUX" -L "$TEST_SOCK" kill-server 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

new_project() {
    local proj="$1"
    mkdir -p "$proj"
    git init -q "$proj"
    git -C "$proj" config user.email test@example.com
    git -C "$proj" config user.name "Test"
    echo hello > "$proj/README.md"
    git -C "$proj" add README.md
    git -C "$proj" commit -q -m init
}

PROJ="$TEST_DIR/cp550"
new_project "$PROJ"
SESSION="llm-cp550"

# --- Shims: real tmux on a private socket, + a controllable gh stub ---
SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCK" "\$@"
EOF
chmod +x "$SHIM_DIR/tmux"
SHIM_TMUX="$SHIM_DIR/tmux"

GH_PR_LIST_FILE="$TEST_DIR/gh-pr-list.tsv"
: > "$GH_PR_LIST_FILE"
cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    branch="\$3"
    awk -F'\t' -v b="\$branch" '\$1 == b { print \$2; found=1 } END { exit found ? 0 : 1 }' "$GH_PR_LIST_FILE"
    exit \$?
fi
exit 1
EOF
chmod +x "$SHIM_DIR/gh"

# Helper: run coordinator-watch.sh for real, with every sweep that isn't
# the one under test switched off (this test only wants the 2s
# status_poll_pass/maybe_run_check/execute_check path live).
start_watcher() {
    local logfile="$1"
    PATH="$SHIM_DIR:$PATH" \
    WORKSPACE="$TEST_DIR" SESSION_NAME="$SESSION" \
    WATCH_CHECK_ON_DONE=1 CHECK_RUNNER="" \
    WATCH_PR_POLL_SECS=0 WATCH_ORPHAN_SWEEP_SECS=0 WATCH_BG_VIOLATION_SWEEP_SECS=0 \
    WATCH_TIMEOUT_RETRY_SWEEP_SECS=0 WATCH_ACTIVITY_POLL_SECS=0 WATCH_WORKTREE_SWEEP_SECS=0 \
    WATCH_PENDING_BRIEF_SWEEP_SECS=0 WATCH_STRANDED_BRIEF_SWEEP_SECS=0 \
    AUTO_COMPACT=0 WORKER_AUTO_COMPACT=0 WORKER_AUTO_DELIVER=0 WATCHER_STALE_CHECK=0 \
    WATCHER_AUTOCLOSE=0 COORD_WAKE_RETRY_SECS=0 COORD_WAKE_BUSY_RETRY_SECS=0 \
    KILL_FINISHED=/bin/true LLM_START=/bin/true REAP_ORPHAN=/bin/true SWEEP=/bin/true \
    HOST_STATE_DIR="$TEST_DIR/host-state" HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0 \
    DRY_RUN=0 ONCE=0 POLL_SECS=1 DEBOUNCE_SECS=0 \
        "$WATCH" "$PROJ" > "$logfile" 2>&1 &
    WATCH_PID=$!
}

stop_watcher() {
    [ -n "${WATCH_PID:-}" ] || return 0
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    unset WATCH_PID
}

# wait_until <timeout_secs> <description> <command...> — polls a condition
# every 0.5s instead of a single blind sleep, so this test is fast on a
# quick pass and still tolerant of slow CI.
wait_until() {
    local timeout="$1" desc="$2"; shift 2
    local waited=0
    while ! "$@" >/dev/null 2>&1; do
        sleep 0.5
        waited=$((waited + 1))
        if [ "$waited" -ge $((timeout * 2)) ]; then
            red "timed out after ${timeout}s waiting for: $desc"
        fi
    done
}

pane_count() { "$SHIM_TMUX" list-panes -t "$SESSION:$1" 2>/dev/null | wc -l; }
window_exists() { "$SHIM_TMUX" list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$1"; }

# ============================================================================
heading "Test 1: check-on-done opens as a PANE inside iss-900, worker pane stays active"
# ============================================================================

git -C "$PROJ" worktree add -q -b fix/issue-900 "$TEST_DIR/wt-issue-900"
WT900="$TEST_DIR/wt-issue-900"
mkdir -p "$WT900/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$WT900/.swarm/check.sh"
chmod +x "$WT900/.swarm/check.sh"
printf 'fix/issue-900\tOPEN\t900\n' > "$GH_PR_LIST_FILE"

# A real swarm session always has a coordinator window alongside worker
# windows; a bare single-window fixture would make tmux auto-kill the
# whole SESSION the moment kill-worktree.sh closes iss-900 in Test 4,
# which would make Test 5/6 (same session, issue 901) spuriously see "no
# tmux session". Keep one never-closed window alive for the session's
# lifetime, same as production.
"$SHIM_TMUX" new-session -d -s "$SESSION" -n keepalive bash -c 'while true; do sleep 3600; done'
"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-900 -c "$WT900" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

[ "$(pane_count iss-900)" -eq 1 ] || red "expected 1 pane in a fresh iss-900 window"
green "fixture worker window iss-900 has its single worker pane at index 0"

echo '{"task_id":"t900","state":"ready-for-review","pr":900,"ts":"2026-07-19T00:00:00Z"}' \
    > "$WT900/.swarm/tasks/status/t900.json"

start_watcher "$TEST_DIR/watch-1.log"

wait_until 20 "iss-900 to grow a second (check) pane" \
    bash -c "[ \"\$($SHIM_TMUX list-panes -t '$SESSION:iss-900' 2>/dev/null | wc -l)\" -eq 2 ]"
green "check-on-done spawned as a SECOND pane in iss-900, not a new window"

[ "$(window_exists chk-900 && echo yes || echo no)" = "no" ] \
    || red "a fallback chk-900 WINDOW should not exist when iss-900 hosted the check as a pane"
green "no fallback chk-900 window was created (pane path taken, as expected)"

ACTIVE_PANE_INDEX="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-900" -F '#{pane_index} #{pane_active}' | awk '$2==1{print $1}')"
[ "$ACTIVE_PANE_INDEX" = "0" ] \
    || red "expected pane 0 (the worker pane) to stay active after the check pane was split in (-d); active pane is $ACTIVE_PANE_INDEX"
green "worker pane (index 0) remains the active pane — split-window -d did not steal focus"

NEW_PANE_TITLE="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-900" -F '#{pane_index} #{pane_title}' | awk '$1==1{print $2}')"
case "$NEW_PANE_TITLE" in
    chk*) : ;;
    *) red "expected the new pane's title to start with 'chk' (select-pane -T chk); got '$NEW_PANE_TITLE'" ;;
esac
green "new check pane is tagged with a 'chk' title"

# Simulate an operator clicking into the check pane (changes which pane is
# ACTIVE) — a bare `capture-pane -t session:window` would now read the
# check pane instead of the worker. Every worker-pane probe fixed by #550
# targets pane .0 explicitly, so it must still reach the worker.
"$SHIM_TMUX" select-pane -t "$SESSION:iss-900.1"
CAPTURED="$("$SHIM_TMUX" capture-pane -t "$SESSION:iss-900.0" -p)"
echo "$CAPTURED" | grep -q WORKER_TICK \
    || red "explicit pane-0 capture did not reach the worker pane after the operator selected the check pane. Captured:
$CAPTURED"
green "explicit .0-targeted capture still reaches the worker pane after the check pane was selected (issue #550 item 2)"

# ============================================================================
heading "Test 2: check resolves, idle pass marker set, exactly one check run recorded"
# ============================================================================

wait_until 15 "t900.check.json to reach a terminal state" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT900/.swarm/tasks/status/t900.check.json' 2>/dev/null"

grep -q '"state":"pass"' "$WT900/.swarm/tasks/status/t900.check.json" \
    || red "expected t900.check.json state=pass; got: $(cat "$WT900/.swarm/tasks/status/t900.check.json" 2>/dev/null)"
green "check.json recorded state=pass"

wait_until 10 "check pane to show the chk-pass idle marker" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-900' -F '#{pane_title}' 2>/dev/null | grep -qx chk-pass"
green "check pane title became chk-pass once the check resolved (idle marker, item 5)"

EVENTS_LOG="$PROJ/.swarm/events.log"
RUNNING_COUNT=$(grep -c 'watch\.check_on_done.*task_id=t900 result=running' "$EVENTS_LOG" 2>/dev/null || true)
PASS_COUNT=$(grep -c 'watch\.check_on_done.*task_id=t900 result=pass' "$EVENTS_LOG" 2>/dev/null || true)
[ "$RUNNING_COUNT" -eq 1 ] || red "expected exactly 1 'result=running' line for t900; got $RUNNING_COUNT. Log:
$(cat "$EVENTS_LOG" 2>/dev/null)"
[ "$PASS_COUNT" -eq 1 ] || red "expected exactly 1 'result=pass' line for t900; got $PASS_COUNT. Log:
$(cat "$EVENTS_LOG" 2>/dev/null)"
green "one done signal -> exactly one check run and one terminal events.log line (item 4)"

[ "$(pane_count iss-900)" -eq 2 ] \
    || red "a resolved check must leave its pane open for review, not close it; expected 2 panes, got $(pane_count iss-900)"
green "resolved check pane stays open for review (worker + chk-pass panes)"

# ============================================================================
heading "Test 3: a second, later completion for the SAME issue REPLACES the check pane, not stacks it"
# ============================================================================

echo '{"task_id":"t900b","state":"ready-for-review","pr":900,"ts":"2026-07-19T01:00:00Z"}' \
    > "$WT900/.swarm/tasks/status/t900b.json"

wait_until 15 "t900b.check.json to reach a terminal state" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT900/.swarm/tasks/status/t900b.check.json' 2>/dev/null"
green "second completion (t900b) on the same issue got its own check run"

[ "$(pane_count iss-900)" -eq 2 ] \
    || red "a second completion's check pane must REPLACE the first, not stack — expected 2 panes in iss-900, got $(pane_count iss-900). This is the 'chk-999 x2' pile-up issue #550 reports."
green "exactly one check pane exists in iss-900 after two sequential completions — no pile-up"

stop_watcher

# ============================================================================
heading "Test 4: reaping issue 900 leaves no chk-900 window or pane behind"
# ============================================================================

(cd "$PROJ" && PATH="$SHIM_DIR:$PATH" "$KILL_WT" 900 "$PROJ") > "$TEST_DIR/reap-900.log" 2>&1 \
    || red "kill-worktree.sh failed on issue 900. Output:
$(cat "$TEST_DIR/reap-900.log")"

[ "$(window_exists iss-900 && echo yes || echo no)" = "no" ] \
    || red "iss-900 window (and its check pane) should be gone after reap"
[ "$(window_exists chk-900 && echo yes || echo no)" = "no" ] \
    || red "no fallback chk-900 window should exist after reap either"
green "reaping issue 900 removed the window and its check pane together — nothing left behind"

# ============================================================================
heading "Test 5: no iss-901 window at all -> check falls back to a standalone chk-901 window"
# ============================================================================

git -C "$PROJ" worktree add -q -b fix/issue-901 "$TEST_DIR/wt-issue-901"
WT901="$TEST_DIR/wt-issue-901"
mkdir -p "$WT901/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$WT901/.swarm/check.sh"
chmod +x "$WT901/.swarm/check.sh"
printf 'fix/issue-901\tOPEN\t901\n' >> "$GH_PR_LIST_FILE"

echo '{"task_id":"t901","state":"ready-for-review","pr":901,"ts":"2026-07-19T00:00:00Z"}' \
    > "$WT901/.swarm/tasks/status/t901.json"

start_watcher "$TEST_DIR/watch-2.log"

wait_until 20 "a fallback chk-901 window to appear" \
    bash -c "window_exists() { $SHIM_TMUX list-windows -t '$SESSION' -F '#{window_name}' 2>/dev/null | grep -qx \"\$1\"; }; window_exists chk-901"
green "check-on-done fell back to a standalone chk-901 window (no iss-901 window existed)"

wait_until 15 "t901.check.json to reach a terminal state" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT901/.swarm/tasks/status/t901.check.json' 2>/dev/null"

wait_until 10 "chk-901 window to be renamed with its idle pass marker" \
    bash -c "$SHIM_TMUX list-windows -t '$SESSION' -F '#{window_name}' 2>/dev/null | grep -qx 'chk-901:pass'"
green "fallback window renamed to chk-901:pass once the check resolved (idle marker, fallback path)"

echo '{"task_id":"t901b","state":"ready-for-review","pr":901,"ts":"2026-07-19T01:00:00Z"}' \
    > "$WT901/.swarm/tasks/status/t901b.json"

wait_until 15 "t901b.check.json to reach a terminal state" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT901/.swarm/tasks/status/t901b.check.json' 2>/dev/null"

CHK901_COUNT=$("$SHIM_TMUX" list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -c '^chk-901' || true)
[ "$CHK901_COUNT" -eq 1 ] \
    || red "expected exactly 1 chk-901 window after two sequential fallback completions, got $CHK901_COUNT. This is the 'chk-1000 x3' pile-up issue #550 reports."
green "exactly one chk-901 window exists after two sequential fallback completions — no pile-up"

stop_watcher

# ============================================================================
heading "Test 6: reaping issue 901 closes the leftover fallback chk-901 window too"
# ============================================================================

(cd "$PROJ" && PATH="$SHIM_DIR:$PATH" "$KILL_WT" 901 "$PROJ") > "$TEST_DIR/reap-901.log" 2>&1 \
    || red "kill-worktree.sh failed on issue 901. Output:
$(cat "$TEST_DIR/reap-901.log")"

[ "$(window_exists chk-901 && echo yes || echo no)" = "no" ] \
    || red "chk-901 fallback window should be closed by kill-worktree.sh's swarm_close_chk_windows call"
green "reaping issue 901 also closed its leftover fallback chk-901 window"

# ============================================================================
heading "Test 7: a DIFFERENT task_id's completion for the same issue, while an earlier check is still running, is deferred rather than killing it (self-review finding)"
# ============================================================================

git -C "$PROJ" worktree add -q -b fix/issue-902 "$TEST_DIR/wt-issue-902"
WT902="$TEST_DIR/wt-issue-902"
mkdir -p "$WT902/.swarm/tasks/status"
# Slow enough that t902b's status file can land, and a sweep can observe
# t902's check pane still mid-run (title plain "chk", not yet resolved),
# well before this finishes.
printf '#!/usr/bin/env bash\nsleep 4\nexit 0\n' > "$WT902/.swarm/check.sh"
chmod +x "$WT902/.swarm/check.sh"
printf 'fix/issue-902\tOPEN\t902\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-902 -c "$WT902" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

echo '{"task_id":"t902","state":"ready-for-review","pr":902,"ts":"2026-07-19T02:00:00Z"}' \
    > "$WT902/.swarm/tasks/status/t902.json"

start_watcher "$TEST_DIR/watch-3.log"

wait_until 20 "iss-902 to grow a second (check) pane" \
    bash -c "[ \"\$($SHIM_TMUX list-panes -t '$SESSION:iss-902' 2>/dev/null | wc -l)\" -eq 2 ]"
wait_until 10 "t902's check pane to show the still-running 'chk' title" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-902' -F '#{pane_title}' 2>/dev/null | grep -qx chk"
green "t902's check pane is up and still running (title is plain 'chk', not yet resolved)"

# A different task_id, same issue, while t902's check is still mid-flight.
echo '{"task_id":"t902b","state":"ready-for-review","pr":902,"ts":"2026-07-19T02:00:01Z"}' \
    > "$WT902/.swarm/tasks/status/t902b.json"

EVENTS_LOG_902="$PROJ/.swarm/events.log"
wait_until 10 "t902b to be deferred instead of killing t902's running check" \
    bash -c "grep -q 'task_id=t902b result=skipped reason=prior_check_running' '$EVENTS_LOG_902' 2>/dev/null"
green "a second task_id's completion on the same issue was deferred, not run concurrently (reason=prior_check_running)"

[ "$(pane_count iss-902)" -eq 2 ] \
    || red "deferring t902b must not spawn a second check pane — expected 2 panes in iss-902, got $(pane_count iss-902)"
green "no extra pane was spawned for the deferred completion"

wait_until 15 "t902.check.json to reach a terminal state, undisturbed by the deferred t902b" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT902/.swarm/tasks/status/t902.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT902/.swarm/tasks/status/t902.check.json" \
    || red "t902's check should have run to completion undisturbed; got: $(cat "$WT902/.swarm/tasks/status/t902.check.json" 2>/dev/null)"
green "t902's check ran to completion (pass) without being killed by the deferred t902b"

wait_until 20 "t902b's own check to retry and resolve once t902's pane freed up" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT902/.swarm/tasks/status/t902b.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT902/.swarm/tasks/status/t902b.check.json" \
    || red "t902b's deferred check should eventually retry and pass; got: $(cat "$WT902/.swarm/tasks/status/t902b.check.json" 2>/dev/null)"
green "the deferred t902b check retried on a later sweep and resolved on its own — never stuck"

stop_watcher

# ============================================================================
heading "Test 8: a check pane killed outright (crash/Ctrl-C) leaves a DEAD pane still titled 'chk' — later completions must not be stuck forever (self-review finding)"
# ============================================================================

# remain-on-exit is what production (llm-start.sh) sets on the swarm
# socket; this test's raw tmux socket doesn't have it by default, so set
# it explicitly to reproduce the real "dead pane, stale title" shape a
# killed runner script leaves behind.
"$SHIM_TMUX" set-option -g remain-on-exit on

git -C "$PROJ" worktree add -q -b fix/issue-903 "$TEST_DIR/wt-issue-903"
WT903="$TEST_DIR/wt-issue-903"
mkdir -p "$WT903/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nsleep 5\nexit 0\n' > "$WT903/.swarm/check.sh"
chmod +x "$WT903/.swarm/check.sh"
printf 'fix/issue-903\tOPEN\t903\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-903 -c "$WT903" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

echo '{"task_id":"t903","state":"ready-for-review","pr":903,"ts":"2026-07-19T03:00:00Z"}' \
    > "$WT903/.swarm/tasks/status/t903.json"

start_watcher "$TEST_DIR/watch-4.log"

wait_until 20 "iss-903 to grow a second (check) pane" \
    bash -c "[ \"\$($SHIM_TMUX list-panes -t '$SESSION:iss-903' 2>/dev/null | wc -l)\" -eq 2 ]"
wait_until 10 "t903's check pane to show the still-running 'chk' title" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-903' -F '#{pane_title}' 2>/dev/null | grep -qx chk"

CHECK_PANE_PID="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-903" -F '#{pane_title} #{pane_pid}' | awk '$1=="chk"{print $2; exit}')"
[ -n "$CHECK_PANE_PID" ] || red "could not resolve t903's check pane pid"
# Kill the runner script's own process directly (not `tmux kill-pane`) to
# simulate a crash/Ctrl-C from inside the pane — the script never reaches
# its own rename-on-finish line, so the title is stuck at "chk" forever
# while remain-on-exit keeps the pane around as [dead].
kill -9 "$CHECK_PANE_PID" 2>/dev/null || true

wait_until 10 "the killed check pane to be marked dead by tmux" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-903' -F '#{pane_title} #{pane_dead}' 2>/dev/null | grep -qx 'chk 1'"
green "t903's check pane is dead but still titled 'chk' (simulated crash)"

# A different task_id, same issue — must NOT be deferred forever just
# because a dead pane is still sitting there titled "chk".
echo '{"task_id":"t903b","state":"ready-for-review","pr":903,"ts":"2026-07-19T03:00:01Z"}' \
    > "$WT903/.swarm/tasks/status/t903b.json"

wait_until 20 "t903b's check to run and resolve despite the dead 'chk' pane" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT903/.swarm/tasks/status/t903b.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT903/.swarm/tasks/status/t903b.check.json" \
    || red "t903b should have run past the dead pane and passed; got: $(cat "$WT903/.swarm/tasks/status/t903b.check.json" 2>/dev/null)"
green "a dead check pane (still titled 'chk') did NOT permanently block later completions for the issue"

[ "$(pane_count iss-903)" -eq 2 ] \
    || red "the dead pane should have been replaced, not left alongside a new one — expected 2 panes in iss-903, got $(pane_count iss-903)"
green "the dead pane was replaced (not stacked) by t903b's check"

stop_watcher

echo
green "ALL TESTS PASSED"
