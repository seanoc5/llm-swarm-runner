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

# Production (llm-start.sh) sets this globally on the real swarm socket
# before any worker window exists — self-review round 12's fix (the
# resolved check pane exits non-zero instead of `exec bash`ing forever,
# so it reads as DEAD rather than a live worker once renumbered into
# slot 0) depends on it being set to at least "failed" from the start,
# same as production, rather than tmux's bare-socket default of "off"
# (which would destroy the pane outright the instant it exits, losing
# the "stays open for review" guarantee entirely). Test 8 used to set
# this itself, later in the file, purely for its own kill-9/dead-pane
# scenario — moved up here so it's in effect from the very first test,
# matching production's real setup.
"$SHIM_TMUX" set-option -g remain-on-exit failed

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

# remain-on-exit=failed is already set globally (session creation, above,
# matching production) — a kill -9'd process doesn't exit 0, so "failed"
# already reproduces the real "dead pane, stale title" shape a killed
# runner script leaves behind; no extra override needed here.

# check_in_flight_for_issue (round 5) no longer trusts the pane label at
# all — it keys off check-claim age instead (same mechanism
# kill-worktree.sh's reap path already uses), so a crashed check's claim
# only stops looking "in flight" once it's older than this. Shrink it for
# this test so t903b doesn't have to wait out the real multi-minute
# default to prove the eventual unblock.
#
# self-review round 9: must stay BIGGER than check.sh's own sleep (5s)
# below. In production CHECK_CLAIM_STALE_SECS defaults to
# WORKER_CHECK_TIMEOUT + 300, which structurally always exceeds a
# genuinely-running check's max lifetime (the runner wraps the check
# command in `timeout $WORKER_CHECK_TIMEOUT`), so maybe_run_check's own
# round-9 own-claim reclaim can never fire against a check that's still
# actually alive. Shrinking this below the check's real runtime (3 was
# tried and broke: a still-alive, mid-sleep t903 kept getting reclaimed
# and restarted every 3s, since the reclaim itself resets the claim's
# mtime and the check never got the full 5s it needed to finish) breaks
# that invariant and self-review round 9 caught it. Keep this above the
# sleep below.
export CHECK_CLAIM_STALE_SECS=8

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

wait_until 30 "t903b's check to run and resolve despite the dead 'chk' pane" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT903/.swarm/tasks/status/t903b.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT903/.swarm/tasks/status/t903b.check.json" \
    || red "t903b should have run past the dead pane and passed; got: $(cat "$WT903/.swarm/tasks/status/t903b.check.json" 2>/dev/null)"
green "a dead check pane (still titled 'chk') did NOT permanently block later completions for the issue"

[ "$(pane_count iss-903)" -eq 2 ] \
    || red "the dead pane should have been replaced, not left alongside a new one — expected 2 panes in iss-903, got $(pane_count iss-903)"
green "the dead pane was replaced (not stacked) by t903b's check"

stop_watcher
unset CHECK_CLAIM_STALE_SECS

# ============================================================================
heading "Test 9: an INSTANT check (no sleep at all) still ends up titled chk-pass, never stuck at plain 'chk' (self-review race finding)"
# ============================================================================

# Self-review finding: the watcher used to label the pane "chk" via its
# OWN tmux select-pane call issued right after split-window returned —
# a check finishing in milliseconds could rename itself chk-pass/chk-fail
# BEFORE that external call landed, which would then clobber the result
# back to plain "chk" with nothing left alive to ever fix it. The fix
# moved the initial "chk" label into the runner script itself, as its
# first line, so the same single process sets both labels strictly in
# order. An instant, zero-sleep check is the most direct way to exercise
# that ordering.
git -C "$PROJ" worktree add -q -b fix/issue-904 "$TEST_DIR/wt-issue-904"
WT904="$TEST_DIR/wt-issue-904"
mkdir -p "$WT904/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WT904/.swarm/check.sh"
chmod +x "$WT904/.swarm/check.sh"
printf 'fix/issue-904\tOPEN\t904\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-904 -c "$WT904" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

echo '{"task_id":"t904","state":"ready-for-review","pr":904,"ts":"2026-07-19T04:00:00Z"}' \
    > "$WT904/.swarm/tasks/status/t904.json"

start_watcher "$TEST_DIR/watch-5.log"

wait_until 15 "t904.check.json to reach a terminal state" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT904/.swarm/tasks/status/t904.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT904/.swarm/tasks/status/t904.check.json" \
    || red "an instant check should still pass; got: $(cat "$WT904/.swarm/tasks/status/t904.check.json" 2>/dev/null)"

wait_until 10 "t904's check pane to settle on chk-pass (not stuck at plain 'chk')" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-904' -F '#{pane_title}' 2>/dev/null | grep -qx chk-pass"
green "an instant check's pane correctly settled on chk-pass — no race against the initial 'chk' label"

stop_watcher

# ============================================================================
heading "Test 10: a check command that clobbers the pane title via a terminal escape sequence gets it reasserted within a few seconds (self-review finding)"
# ============================================================================

# Self-review finding: a check command that itself prints a terminal-title
# escape sequence (some test runners/TUIs do) overwrites the pane's "chk"
# title out from under the watcher — confirmed empirically that this
# tmux version has no pane-title equivalent of the window-name protection
# -n already gives the fallback-window case (automatic-rename off). The
# fix has the runner script reassert "chk" every few seconds for the
# check's duration, so any such clobber self-heals instead of permanently
# misreading as resolved/stale to check_in_flight_for_issue. Long sleep
# (10s) + an early injection gives the reassertion loop (every 3s) ample
# margin to catch and heal it well before the check itself finishes, so
# this test can't race its own "chk" -> "chk-pass" transition.
git -C "$PROJ" worktree add -q -b fix/issue-905 "$TEST_DIR/wt-issue-905"
WT905="$TEST_DIR/wt-issue-905"
mkdir -p "$WT905/.swarm/tasks/status"
# The check command itself emits a title-setting escape sequence (OSC 2)
# as part of its own output, exactly as a real test runner/TUI might —
# this is real output on the pane's pty, not injected input, so tmux's
# terminal emulation genuinely retitles the pane from it.
cat > "$WT905/.swarm/check.sh" <<'CHECKSCRIPT'
#!/usr/bin/env bash
printf '\033]2;HACKED\033\\'
sleep 10
exit 0
CHECKSCRIPT
chmod +x "$WT905/.swarm/check.sh"
printf 'fix/issue-905\tOPEN\t905\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-905 -c "$WT905" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

echo '{"task_id":"t905","state":"ready-for-review","pr":905,"ts":"2026-07-19T05:00:00Z"}' \
    > "$WT905/.swarm/tasks/status/t905.json"

start_watcher "$TEST_DIR/watch-6.log"

wait_until 20 "t905's check pane to show the clobbered 'HACKED' title (confirms the check's own escape sequence really does overwrite 'chk')" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-905' -F '#{pane_title}' 2>/dev/null | grep -qx HACKED"
green "confirmed the check command's own escape sequence clobbers the pane title, as a real misbehaving check command would"

wait_until 8 "the runner script's watchdog to reassert 'chk' within a few seconds" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-905' -F '#{pane_title}' 2>/dev/null | grep -qx chk"
green "the pane title self-healed back to 'chk' without any help from the watcher itself"

wait_until 18 "t905's check to still resolve normally despite the mid-run title clobber" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT905/.swarm/tasks/status/t905.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT905/.swarm/tasks/status/t905.check.json" \
    || red "t905's check should still pass; got: $(cat "$WT905/.swarm/tasks/status/t905.check.json" 2>/dev/null)"

[ "$(pane_count iss-905)" -eq 2 ] \
    || red "the title-clobber must not have caused a duplicate check pane — expected 2 panes in iss-905, got $(pane_count iss-905)"
green "the check ran to completion as exactly one pane despite the mid-run title clobber"

stop_watcher

# ============================================================================
heading "Test 11: a misleadingly stale 'chk' LABEL (claim already released) does not defer a later completion (self-review round 5 finding)"
# ============================================================================

# Round 5's actual bug: the label can lag behind (or race past) the real
# resolution — e.g. a stray, already-orphaned retitle-watchdog iteration
# landing right after the runner script's own final chk-pass/chk-fail
# write. check_in_flight_for_issue must not be fooled by that: it keys
# off the check-claim dir (released synchronously, well before any label
# is touched), not the label text. Reproduce the exact shape directly —
# run one check to a real, released resolution, then manually force the
# pane's label back to plain "chk" (simulating that stray landing) before
# the next completion ever looks at it.
git -C "$PROJ" worktree add -q -b fix/issue-906 "$TEST_DIR/wt-issue-906"
WT906="$TEST_DIR/wt-issue-906"
mkdir -p "$WT906/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WT906/.swarm/check.sh"
chmod +x "$WT906/.swarm/check.sh"
printf 'fix/issue-906\tOPEN\t906\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-906 -c "$WT906" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

echo '{"task_id":"t906","state":"ready-for-review","pr":906,"ts":"2026-07-19T06:00:00Z"}' \
    > "$WT906/.swarm/tasks/status/t906.json"

start_watcher "$TEST_DIR/watch-7.log"

wait_until 15 "t906's check to reach a real, released resolution (pass)" \
    bash -c "grep -q '\"state\":\"pass\"' '$WT906/.swarm/tasks/status/t906.check.json' 2>/dev/null"
[ ! -d "$WT906/.swarm/tasks/status/t906.check-claim" ] \
    || red "t906's claim should already be released once its check.json shows pass"
green "t906's check resolved for real — claim released, check.json says pass"

# Force the label back to plain "chk", as if a stray reassertion had just
# landed after the real resolution. Resolve the check pane by its current
# (chk-pass) title rather than assuming a pane index — pane-base-index
# varies by tmux config.
CHK_PANE_906="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-906" -F '#{pane_id} #{pane_title}' \
    | awk '$2=="chk-pass"{print $1; exit}')"
[ -n "$CHK_PANE_906" ] || red "could not find t906's resolved (chk-pass) check pane"
"$SHIM_TMUX" select-pane -t "$CHK_PANE_906" -T chk

EVENTS_LOG_906="$PROJ/.swarm/events.log"
BEFORE_LINES_906="$(wc -l < "$EVENTS_LOG_906" 2>/dev/null || echo 0)"

echo '{"task_id":"t906b","state":"ready-for-review","pr":906,"ts":"2026-07-19T06:00:01Z"}' \
    > "$WT906/.swarm/tasks/status/t906b.json"

wait_until 15 "t906b's check to resolve promptly despite the misleadingly stale 'chk' label" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT906/.swarm/tasks/status/t906b.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT906/.swarm/tasks/status/t906b.check.json" \
    || red "t906b should have passed promptly; got: $(cat "$WT906/.swarm/tasks/status/t906b.check.json" 2>/dev/null)"
green "t906b resolved promptly — not fooled into waiting by the stale label"

tail -n "+$((BEFORE_LINES_906 + 1))" "$EVENTS_LOG_906" 2>/dev/null | grep -q 'task_id=t906b result=skipped reason=prior_check_running' \
    && red "t906b must NOT have been deferred — its claim-dir ground truth showed no real check in flight"
green "t906b was never deferred — the stale label alone didn't trigger a prior_check_running skip"

[ "$(pane_count iss-906)" -eq 2 ] \
    || red "expected exactly 2 panes (worker + one check pane, replaced not stacked) in iss-906, got $(pane_count iss-906)"
green "the stale-labeled pane was replaced cleanly, not stacked alongside a second one"

stop_watcher

# ============================================================================
heading "Test 12: an iss-N window too short for the pane split falls back to the chk-N window instead of being permanently stuck (self-review round 7 finding)"
# ============================================================================

# Round 7's actual bug: split-window -l 12 needs enough rows for the new
# pane plus at least one left for the worker's own pane; an attached
# client that keeps iss-N shorter than that makes tmux refuse the split
# with "no space for new pane" on EVERY sweep, forever — the claim gets
# released, check.json is stuck at "checking", and nothing ever runs the
# check. Force iss-907 down to 2 rows (manual per-window sizing, so this
# doesn't shrink the session's other windows) and confirm the check still
# completes, by falling back to the standalone chk-N window path.
git -C "$PROJ" worktree add -q -b fix/issue-907 "$TEST_DIR/wt-issue-907"
WT907="$TEST_DIR/wt-issue-907"
mkdir -p "$WT907/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WT907/.swarm/check.sh"
chmod +x "$WT907/.swarm/check.sh"
printf 'fix/issue-907\tOPEN\t907\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-907 -c "$WT907" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'
"$SHIM_TMUX" set-window-option -t "$SESSION:iss-907" window-size manual
"$SHIM_TMUX" resize-window -t "$SESSION:iss-907" -y 2

echo '{"task_id":"t907","state":"ready-for-review","pr":907,"ts":"2026-07-19T07:00:00Z"}' \
    > "$WT907/.swarm/tasks/status/t907.json"

start_watcher "$TEST_DIR/watch-8.log"

wait_until 15 "t907's check to resolve despite iss-907 being too short to split" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT907/.swarm/tasks/status/t907.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT907/.swarm/tasks/status/t907.check.json" \
    || red "t907 should have passed via the fallback window; got: $(cat "$WT907/.swarm/tasks/status/t907.check.json" 2>/dev/null)"
green "t907's check resolved via the chk-N window fallback despite the too-short iss-907 window"

window_exists "chk-907:pass" \
    || red "expected a resolved chk-907:pass fallback window, found: $("$SHIM_TMUX" list-windows -t "$SESSION" -F '#{window_name}')"
green "chk-907 window carries the pass marker — the fallback path ran, not a silently stuck pane split"

[ "$(pane_count iss-907)" -eq 1 ] \
    || red "iss-907 should still have just its own worker pane (no stray half-split pane left behind), got $(pane_count iss-907)"
green "iss-907 itself was never left with a stray pane from the failed split attempt"

stop_watcher
"$SHIM_TMUX" kill-window -t "$SESSION:chk-907" 2>/dev/null || true

# ============================================================================
heading "Test 13: a worker-only reap that kills the whole iss-N window (no -w, no claim-defer) must not orphan its own check forever (self-review round 9 finding)"
# ============================================================================

# Round 9's actual bug: before this PR, a check ran in its own chk-N
# window — a plain kill-finished-workers.sh reap of just iss-N (no -w;
# only kill-worktree.sh's own protocol defers on an active claim) left
# that chk-N window, and its claim, untouched. Now the check is a PANE
# INSIDE iss-N, so killing that whole window kills the check mid-run too.
# Its runner script never reaches its own final rmdir, orphaning t908's
# own claim-dir forever — maybe_run_check's mkdir on an already-existing
# claim just returned silently, with nothing left alive to ever retry it.
# self-review round 9: must stay BIGGER than check.sh's own sleep (4s)
# below, for the same reason Test 8 bumped its own value — the
# own-claim reclaim must never fire while the check is still genuinely
# alive, only once it's truly orphaned (which it is here, right after
# the kill-window below).
export CHECK_CLAIM_STALE_SECS=7

git -C "$PROJ" worktree add -q -b fix/issue-908 "$TEST_DIR/wt-issue-908"
WT908="$TEST_DIR/wt-issue-908"
mkdir -p "$WT908/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nsleep 4\nexit 0\n' > "$WT908/.swarm/check.sh"
chmod +x "$WT908/.swarm/check.sh"
printf 'fix/issue-908\tOPEN\t908\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-908 -c "$WT908" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

echo '{"task_id":"t908","state":"ready-for-review","pr":908,"ts":"2026-07-19T08:00:00Z"}' \
    > "$WT908/.swarm/tasks/status/t908.json"

start_watcher "$TEST_DIR/watch-9.log"

wait_until 10 "t908's check pane to show the still-running 'chk' title" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-908' -F '#{pane_title}' 2>/dev/null | grep -qx chk"

[ -d "$WT908/.swarm/tasks/status/t908.check-claim" ] \
    || red "t908's claim-dir should exist while its check is still running"

# Simulate kill-finished-workers.sh WITHOUT -w: kill the whole iss-N
# window directly (worker pane and check pane together), bypassing
# kill-worktree.sh's claim-defer protocol entirely.
"$SHIM_TMUX" kill-window -t "$SESSION:iss-908" 2>/dev/null || true
window_exists iss-908 && red "iss-908 should be fully gone after the simulated worker-only reap"
green "iss-908 (worker + check pane together) was killed, simulating a plain worker-only reap"

[ -d "$WT908/.swarm/tasks/status/t908.check-claim" ] \
    || red "t908's claim-dir should still exist immediately after the kill — nothing ran its rmdir"
green "t908's claim-dir is now orphaned, exactly as a kill-finished-workers.sh (no -w) reap would leave it"

wait_until 25 "t908's check to recover via the stale-claim reclaim and resolve on its own" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT908/.swarm/tasks/status/t908.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT908/.swarm/tasks/status/t908.check.json" \
    || red "t908 should have recovered and passed; got: $(cat "$WT908/.swarm/tasks/status/t908.check.json" 2>/dev/null)"
green "t908's own orphaned claim was reclaimed once stale, and its check ran to completion — never stuck forever"

window_exists "chk-908:pass" \
    || red "expected t908's reclaimed check to fall back to a standalone chk-908:pass window (iss-908 no longer exists), found: $("$SHIM_TMUX" list-windows -t "$SESSION" -F '#{window_name}')"
green "t908's reclaimed check ran via the fallback chk-908 window, since iss-908 itself is gone"

stop_watcher
unset CHECK_CLAIM_STALE_SECS
"$SHIM_TMUX" kill-window -t "$SESSION:chk-908" 2>/dev/null || true

# ============================================================================
heading "Test 14: a crashed check with a title clobbered past recognition still gets replaced, not stacked, and a live Ctrl-Z scratch pane in the same window is never touched (self-review round 10 finding)"
# ============================================================================

# Same reasoning as Test 8/13: t909b's cross-task defer (check_in_flight_for_issue)
# needs t909's now-dead claim to age past this before it'll proceed, so
# shrink it for the test — kept above check.sh's own sleep below so the
# round-9 own-claim reclaim can't fire against a still-genuinely-running
# check either (same invariant Test 8/13 rely on).
export CHECK_CLAIM_STALE_SECS=8

git -C "$PROJ" worktree add -q -b fix/issue-909 "$TEST_DIR/wt-issue-909"
WT909="$TEST_DIR/wt-issue-909"
mkdir -p "$WT909/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nsleep 5\nexit 0\n' > "$WT909/.swarm/check.sh"
chmod +x "$WT909/.swarm/check.sh"
printf 'fix/issue-909\tOPEN\t909\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-909 -c "$WT909" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

echo '{"task_id":"t909","state":"ready-for-review","pr":909,"ts":"2026-07-19T09:00:00Z"}' \
    > "$WT909/.swarm/tasks/status/t909.json"

start_watcher "$TEST_DIR/watch-10.log"

wait_until 10 "t909's check pane to show the still-running 'chk' title" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-909' -F '#{pane_title}' 2>/dev/null | grep -qx chk"

# A live Ctrl-Z worker-shell scratch pane landing in the SAME window —
# install-tmux-binding.sh's sibling-shell binding does exactly this for an
# iss-N window. It must survive everything below untouched. Split
# explicitly off the worker pane (.0) and capture the new pane's id
# straight from split-window's own output, rather than re-deriving it by
# index afterward — tmux can renumber the EXISTING check pane's index
# when a new pane lands, and a guess here would risk retitling the wrong
# one.
SCRATCH_PANE_ID="$("$SHIM_TMUX" split-window -h -P -F '#{pane_id}' -t "$SESSION:iss-909.0" bash -c 'while true; do sleep 0.3; done')"
[ -n "$SCRATCH_PANE_ID" ] || red "could not resolve the simulated Ctrl-Z scratch pane's id"
"$SHIM_TMUX" select-pane -t "$SCRATCH_PANE_ID" -T coord-scratch

# Simulate the check command's own escape sequence clobbering its title to
# something unrecognizable, then crashing before its next periodic
# reassertion tick (Test 10 proves the reassertion itself works — this is
# the narrower case where the crash wins the race instead).
CHECK_PANE_PID="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-909" -F '#{pane_title} #{pane_pid}' | awk '$1=="chk"{print $2; exit}')"
[ -n "$CHECK_PANE_PID" ] || red "could not resolve t909's check pane pid"
CHECK_PANE_ID="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-909" -F '#{pane_title} #{pane_id}' | awk '$1=="chk"{print $2; exit}')"
"$SHIM_TMUX" select-pane -t "$CHECK_PANE_ID" -T 'garbage-from-check-cmd'
kill -9 "$CHECK_PANE_PID" 2>/dev/null || true

wait_until 10 "the clobbered check pane to be marked dead by tmux" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-909' -F '#{pane_id} #{pane_dead}' 2>/dev/null | grep -qx '$CHECK_PANE_ID 1'"
green "t909's check pane is dead with its title clobbered to something the old title-only match can't recognize"

[ "$("$SHIM_TMUX" list-panes -t "$SESSION:iss-909" -F '#{pane_title}' | grep -cx coord-scratch)" -eq 1 ] \
    || red "the scratch pane should still be alive and tagged before the next completion runs"

echo '{"task_id":"t909b","state":"ready-for-review","pr":909,"ts":"2026-07-19T09:00:01Z"}' \
    > "$WT909/.swarm/tasks/status/t909b.json"

wait_until 30 "t909b's check to run and resolve despite the unrecognizably-titled dead pane" \
    bash -c "grep -q '\"state\":\"pass\"\|\"state\":\"fail\"' '$WT909/.swarm/tasks/status/t909b.check.json' 2>/dev/null"
grep -q '"state":"pass"' "$WT909/.swarm/tasks/status/t909b.check.json" \
    || red "t909b should have run past the clobbered-title dead pane and passed; got: $(cat "$WT909/.swarm/tasks/status/t909b.check.json" 2>/dev/null)"
green "t909b's check ran and resolved despite the dead pane's unrecognizable title — the dead-pane fallback caught it"

"$SHIM_TMUX" list-panes -t "$SESSION:iss-909" -F '#{pane_id}' | grep -qx "$CHECK_PANE_ID" \
    && red "the clobbered-title dead pane should have been replaced (killed), not left alongside the new check"
green "the clobbered-title dead pane was replaced, not stacked"

[ "$("$SHIM_TMUX" list-panes -t "$SESSION:iss-909" -F '#{pane_title}' | grep -cx coord-scratch)" -eq 1 ] \
    || red "the live Ctrl-Z scratch pane should never be touched by the dead-pane fallback match"
green "the live Ctrl-Z scratch pane survived untouched"

[ "$(pane_count iss-909)" -eq 3 ] \
    || red "expected exactly 3 panes in iss-909 (worker, scratch, new check) — got $(pane_count iss-909)"
green "iss-909 ended with exactly worker + scratch + new-check panes — no pile-up, no collateral damage"

stop_watcher
unset CHECK_CLAIM_STALE_SECS

# ============================================================================
heading "Test 15: a NEW check pane splits off the worker pane even when a Ctrl-Z scratch pane is the ACTIVE one (self-review round 11 finding)"
# ============================================================================

git -C "$PROJ" worktree add -q -b fix/issue-910 "$TEST_DIR/wt-issue-910"
WT910="$TEST_DIR/wt-issue-910"
mkdir -p "$WT910/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WT910/.swarm/check.sh"
chmod +x "$WT910/.swarm/check.sh"
printf 'fix/issue-910\tOPEN\t910\n' >> "$GH_PR_LIST_FILE"

"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-910 -c "$WT910" \
    bash -c 'while true; do echo WORKER_TICK; sleep 0.3; done'

# Same technique as Test 14: split explicitly off the worker pane (.0) and
# capture the new pane's own id, then make IT the active pane — the exact
# state a human mid-Ctrl-Z-session would leave the window in right before
# a completion lands.
"$SHIM_TMUX" split-window -h -t "$SESSION:iss-910.0" bash -c 'while true; do sleep 0.3; done'
"$SHIM_TMUX" select-pane -t "$SESSION:iss-910.1" -T coord-scratch

WORKER_HEIGHT_BEFORE="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-910" -F '#{pane_index} #{pane_height}' | awk '$1==0{print $2; exit}')"
[ -n "$WORKER_HEIGHT_BEFORE" ] || red "could not resolve iss-910's worker pane height before the check spawns"

echo '{"task_id":"t910","state":"ready-for-review","pr":910,"ts":"2026-07-19T10:00:00Z"}' \
    > "$WT910/.swarm/tasks/status/t910.json"

start_watcher "$TEST_DIR/watch-11.log"

wait_until 20 "iss-910 to grow a third (check) pane while the scratch pane stayed active" \
    bash -c "[ \"\$($SHIM_TMUX list-panes -t '$SESSION:iss-910' 2>/dev/null | wc -l)\" -eq 3 ]"

WORKER_HEIGHT_AFTER="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-910" -F '#{pane_index} #{pane_height}' | awk '$1==0{print $2; exit}')"
SCRATCH_HEIGHT_AFTER="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-910" -F '#{pane_title} #{pane_height}' | awk '$1=="coord-scratch"{print $2; exit}')"

[ "$WORKER_HEIGHT_AFTER" -lt "$WORKER_HEIGHT_BEFORE" ] \
    || red "the check split should have shrunk the WORKER pane (it targets .0 explicitly) — worker height before=$WORKER_HEIGHT_BEFORE after=$WORKER_HEIGHT_AFTER, scratch after=$SCRATCH_HEIGHT_AFTER (scratch being the one that shrank would mean the split landed on whichever pane was active instead)"
green "the check pane split off the worker pane (its height shrank) even though the scratch pane was the active one"

[ "$("$SHIM_TMUX" list-panes -t "$SESSION:iss-910" -F '#{pane_title}' | grep -cx coord-scratch)" -eq 1 ] \
    || red "the scratch pane should still be present and untouched"
green "the scratch pane was left alone — only the worker pane's geometry changed"

stop_watcher

# ============================================================================
heading "Test 16: a resolved check pane is left DEAD (not an interactive shell), so it reads as a corpse rather than a live worker once the worker's own pane exits cleanly and tmux renumbers the check pane down into slot 0 (self-review round 12 finding)"
# ============================================================================

# remain-on-exit=failed is already the session global (set at session
# creation, above, matching production): a CLEAN (zero) exit destroys a
# pane outright (no dead-but-visible state at all), while a non-zero
# exit leaves it around as [dead] — exactly the two behaviors this test
# needs from the worker pane and the check pane respectively, with no
# further override needed here.
git -C "$PROJ" worktree add -q -b fix/issue-911 "$TEST_DIR/wt-issue-911"
WT911="$TEST_DIR/wt-issue-911"
mkdir -p "$WT911/.swarm/tasks/status"
printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$WT911/.swarm/check.sh"
chmod +x "$WT911/.swarm/check.sh"
printf 'fix/issue-911\tOPEN\t911\n' >> "$GH_PR_LIST_FILE"

# Worker pane ticks for ~12s (plenty of margin for the check above to
# spawn and resolve first) then exits 0 on its own — the same "listener's
# own process ends with exit 0" shape worker-listener.sh's close-worker/
# double-exit/reaped-worktree paths all share, deterministic rather than
# relying on an external kill/send-keys race.
"$SHIM_TMUX" new-window -d -t "$SESSION" -n iss-911 -c "$WT911" \
    bash -c 'for i in $(seq 1 40); do echo WORKER_TICK; sleep 0.3; done; exit 0'
"$SHIM_TMUX" set-window-option -t "$SESSION:iss-911" remain-on-exit failed

echo '{"task_id":"t911","state":"ready-for-review","pr":911,"ts":"2026-07-19T11:00:00Z"}' \
    > "$WT911/.swarm/tasks/status/t911.json"

start_watcher "$TEST_DIR/watch-12.log"

wait_until 20 "t911's check pane to resolve to chk-pass" \
    bash -c "$SHIM_TMUX list-panes -t '$SESSION:iss-911' -F '#{pane_title}' 2>/dev/null | grep -qx chk-pass"
green "t911's check resolved and its pane is titled chk-pass"

CHECK_PANE_DEAD="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-911" -F '#{pane_title} #{pane_dead}' | awk '$1=="chk-pass"{print $2; exit}')"
[ "$CHECK_PANE_DEAD" = "1" ] \
    || red "a resolved check pane must exit non-zero so remain-on-exit=failed leaves it DEAD (not an interactive exec-bash shell staying genuinely alive) — got pane_dead=$CHECK_PANE_DEAD"
green "the resolved check pane is DEAD, not an interactive shell (round 12's actual fix)"

wait_until 15 "iss-911's worker pane to exit cleanly on its own and the window to collapse to a single pane" \
    bash -c "[ \"\$($SHIM_TMUX list-panes -t '$SESSION:iss-911' 2>/dev/null | wc -l)\" -eq 1 ]"
green "the worker's clean exit destroyed pane 0 (remain-on-exit=failed), leaving only the check pane — renumbered down into slot 0"

SURVIVOR_INFO="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-911" -F '#{pane_index} #{pane_title} #{pane_dead}')"
[ "$(echo "$SURVIVOR_INFO" | awk '{print $1}')" = "0" ] \
    || red "expected the surviving check pane to have been renumbered to index 0; got: $SURVIVOR_INFO"
[ "$(echo "$SURVIVOR_INFO" | awk '{print $2}')" = "chk-pass" ] \
    || red "the surviving pane at index 0 should still be the resolved check pane (title chk-pass); got: $SURVIVOR_INFO"
green "the check pane was renumbered down into index 0, exactly the shape every pane_dead(head -1) reader in this codebase will see next"

# This is the exact query provision-worker.sh's reclaim guard,
# has_live_window_draining_brief and check-stuck-workers.sh all run
# (list-panes, take the first line's pane_dead) — before round 12's fix
# this would have read "0" (interactive exec-bash shell, alive), silently
# passing the renumbered check-pane corpse off as a live worker.
PANE_DEAD_VIA_HEAD1="$("$SHIM_TMUX" list-panes -t "$SESSION:iss-911" -F '#{pane_dead}' | head -1)"
[ "$PANE_DEAD_VIA_HEAD1" = "1" ] \
    || red "every pane_dead(head -1) reader in this codebase (provision-worker.sh's reclaim guard, has_live_window_draining_brief, check-stuck-workers.sh) would misread this window as a live worker — got pane_dead=$PANE_DEAD_VIA_HEAD1"
green "the renumbered window correctly reads as dead/reclaimable to every existing pane_dead(head -1) check — no zombie worker slot"

stop_watcher

echo
green "ALL TESTS PASSED"
