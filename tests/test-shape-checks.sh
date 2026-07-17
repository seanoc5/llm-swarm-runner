#!/usr/bin/env bash
#
# test-shape-checks.sh — Non-LLM shape test for executed acceptance checks
# in worker-listener.sh (concept adopted from ringer; attribution in
# docs/ringer-adoptions.md).
#
# Uses the listener's `bash` fallback agent (same trick as
# test-shape-swarm.sh) so briefs are deterministic shell commands.
# Covers:
#   1. brief `<!-- SWARM_CHECK: … -->` marker, check passes  → ok.json + check fields
#   2. brief marker, agent exits 0 but check fails           → err.json (check gates pass)
#   3. .swarm/check.sh fallback when brief has no marker
#   4. no check configured                                   → check fields null
#   5. WORKER_CHECK=0 kill switch                            → check skipped despite check.sh
#   6. WORKER_CHECK_CMD env fallback
#   7. retry-once: failing check → re-dispatch with failure context → pass
#   8. WORKER_CHECK_RETRY=0 disables the retry
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

command -v jq >/dev/null 2>&1 || red "jq required for outcome JSON validation"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"
SCOREBOARD="$SCRIPT_DIR/../scripts/swarm-scoreboard.sh"
[ -x "$SCOREBOARD" ] || red "swarm-scoreboard.sh not executable: $SCOREBOARD"

TEST_DIR=$(mktemp -d -t shape-checks-XXXXXX)
LISTENER_PIDS=()
cleanup() {
    for pid in "${LISTENER_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

wait_for() {
    local desc="$1" cmd="$2" max=20
    for ((i=0; i<max; i++)); do
        if eval "$cmd"; then return 0; fi
        sleep 0.5
    done
    red "timeout waiting for: $desc"
}

drop_v2() {
    local task_id="$1" body="$2"
    local tmp
    tmp=$(mktemp -p .swarm/tasks/inbox .tmp.XXXX.md)
    printf '%s\n' "$body" > "$tmp"
    mv "$tmp" ".swarm/tasks/inbox/$task_id.md"
}

start_listener() {   # $1 = dir; rest = env VAR=VAL pairs
    local dir="$1"; shift
    mkdir -p "$dir/.swarm/tasks/inbox" "$dir/.swarm/tasks/processing" "$dir/.swarm/tasks/done"
    ( cd "$dir" && env WORKER_HEADLESS=1 "$@" "$LISTENER" bash > listener.log 2>&1 ) &
    LISTENER_PIDS+=($!)
    sleep 0.5
}

heading "Shape test: executed acceptance checks"
echo "test dir: $TEST_DIR"

# ============================================================================
heading "Listener A: default check config"
# ============================================================================
start_listener "$TEST_DIR/wt-a"
cd "$TEST_DIR/wt-a"

# --- Test 1: brief marker, check passes -------------------------------------
drop_v2 "c1" 'echo agent-ran > t1.txt
# <!-- SWARM_CHECK: grep -q agent-ran t1.txt -->'
wait_for "c1 outcome" '[ -f .swarm/tasks/done/c1.ok.json ]'
jq -e '
    .outcome == "ok"
    and .exit_code == 0
    and .check_exit == 0
    and .retried == false
    and (.check_cmd | test("grep -q agent-ran"))
' .swarm/tasks/done/c1.ok.json >/dev/null \
    || { cat .swarm/tasks/done/c1.ok.json; red "c1 check fields wrong"; }
[ -f .swarm/tasks/done/c1.check.log ] || red "c1 check.log missing"
green "marker check ran and passed: ok.json + check_cmd/check_exit + check.log"

# --- Test 2: agent exits 0 but check fails → err ----------------------------
drop_v2 "c2" 'echo looks-done-but-is-not
# <!-- SWARM_CHECK: test -f file-the-agent-never-made.txt -->'
wait_for "c2 outcome" '[ -f .swarm/tasks/done/c2.err.json ]'
jq -e '
    .outcome == "err"
    and .exit_code == 0
    and .check_exit != 0
    and .check_exit != null
    and .retried == true
' .swarm/tasks/done/c2.err.json >/dev/null \
    || { cat .swarm/tasks/done/c2.err.json; red "c2: failing check did not flip outcome to err"; }
[ ! -f .swarm/tasks/done/c2.ok.json ] || red "c2: spurious ok.json despite failed check"
[ -f .swarm/tasks/done/c2.check.attempt1.log ] || red "c2: first-attempt check log not preserved"
green "failing check gates the pass: agent exit 0 + check fail → retry → still err.json"

# --- Test 3: .swarm/check.sh fallback (no marker in brief) ------------------
cat > .swarm/check.sh <<'EOF'
grep -q via-standing-check t3.txt
EOF
drop_v2 "c3" 'echo via-standing-check > t3.txt'
wait_for "c3 outcome" '[ -f .swarm/tasks/done/c3.ok.json ]'
jq -e '.check_exit == 0 and (.check_cmd == "bash .swarm/check.sh")' \
    .swarm/tasks/done/c3.ok.json >/dev/null \
    || { cat .swarm/tasks/done/c3.ok.json; red "c3 standing check not used"; }
green ".swarm/check.sh fallback used when brief has no marker"
rm -f .swarm/check.sh

# --- Test 4: no check configured → null fields ------------------------------
drop_v2 "c4" 'echo no-check-here'
wait_for "c4 outcome" '[ -f .swarm/tasks/done/c4.ok.json ]'
jq -e '
    .check_cmd == null and .check_exit == null and .check_output_tail == null
' .swarm/tasks/done/c4.ok.json >/dev/null \
    || { cat .swarm/tasks/done/c4.ok.json; red "c4: expected null check fields"; }
green "no check configured → check_* fields null, outcome unchanged"

# ============================================================================
heading "Listener B: WORKER_CHECK=0 kill switch"
# ============================================================================
start_listener "$TEST_DIR/wt-b" WORKER_CHECK=0
cd "$TEST_DIR/wt-b"
cat > .swarm/check.sh <<'EOF'
exit 1
EOF
drop_v2 "c5" 'echo disabled-check'
wait_for "c5 outcome" '[ -f .swarm/tasks/done/c5.ok.json ]'
jq -e '.check_cmd == null and .check_exit == null' \
    .swarm/tasks/done/c5.ok.json >/dev/null \
    || { cat .swarm/tasks/done/c5.ok.json; red "c5: WORKER_CHECK=0 did not skip check"; }
green "WORKER_CHECK=0 skips the check even with a failing .swarm/check.sh present"

# ============================================================================
heading "Listener C: WORKER_CHECK_CMD env fallback"
# ============================================================================
start_listener "$TEST_DIR/wt-c" WORKER_CHECK_CMD='grep -q env-check t6.txt'
cd "$TEST_DIR/wt-c"
drop_v2 "c6" 'echo env-check > t6.txt'
wait_for "c6 outcome" '[ -f .swarm/tasks/done/c6.ok.json ]'
jq -e '.check_exit == 0 and (.check_cmd | test("env-check"))' \
    .swarm/tasks/done/c6.ok.json >/dev/null \
    || { cat .swarm/tasks/done/c6.ok.json; red "c6 env fallback not used"; }
green "WORKER_CHECK_CMD env fallback used when no marker and no check.sh"

# ============================================================================
heading "Listener D: retry-once rescues a failing check"
# ============================================================================
# First attempt appends one line; the check needs two. The retry re-runs the
# brief (with failure context injected before it), appending the second line,
# so the re-run check passes.
start_listener "$TEST_DIR/wt-d"
cd "$TEST_DIR/wt-d"
drop_v2 "c7" 'echo try >> attempts.txt
# <!-- SWARM_CHECK: test "$(wc -l < attempts.txt)" -ge 2 -->'
wait_for "c7 outcome" '[ -f .swarm/tasks/done/c7.ok.json ]'
jq -e '.outcome == "ok" and .check_exit == 0 and .retried == true' \
    .swarm/tasks/done/c7.ok.json >/dev/null \
    || { cat .swarm/tasks/done/c7.ok.json; red "c7: retry did not rescue the task"; }
[ "$(wc -l < attempts.txt)" -ge 2 ] || red "c7: agent was not re-dispatched"
[ -f .swarm/tasks/done/c7.check.attempt1.log ] || red "c7: attempt1 check log missing"
green "retry-once: check fail → re-dispatch with failure context → check pass → ok.json (retried: true)"

# ============================================================================
heading "Listener E: WORKER_CHECK_RETRY=0 disables the retry"
# ============================================================================
start_listener "$TEST_DIR/wt-e" WORKER_CHECK_RETRY=0
cd "$TEST_DIR/wt-e"
drop_v2 "c8" 'echo once >> attempts.txt
# <!-- SWARM_CHECK: false -->'
wait_for "c8 outcome" '[ -f .swarm/tasks/done/c8.err.json ]'
jq -e '.outcome == "err" and .retried == false' \
    .swarm/tasks/done/c8.err.json >/dev/null \
    || { cat .swarm/tasks/done/c8.err.json; red "c8: retry fired despite WORKER_CHECK_RETRY=0"; }
[ "$(wc -l < attempts.txt)" -eq 1 ] || red "c8: agent dispatched more than once"
[ ! -f .swarm/tasks/done/c8.check.attempt1.log ] || red "c8: attempt1 log should not exist"
green "WORKER_CHECK_RETRY=0: single attempt, retried: false"

# ============================================================================
heading "Eval log + scoreboard"
# ============================================================================
# Listener A processed c1..c4 → 4 eval rows: 3 ok (c1, c3, c4), 1 err after
# retry (c2). Validate the JSONL and the scoreboard aggregation over it.
EVAL_LOG="$TEST_DIR/wt-a/.swarm/eval-log.jsonl"
[ -f "$EVAL_LOG" ] || red "eval log missing: $EVAL_LOG"
[ "$(wc -l < "$EVAL_LOG")" -eq 4 ] || { cat "$EVAL_LOG"; red "expected 4 eval rows"; }
jq -es 'all(.[]; has("ts") and has("task_id") and has("agent") and has("model")
            and has("duration_seconds") and has("exit_code") and has("check_cmd")
            and has("check_exit") and has("retried") and has("outcome"))' \
    "$EVAL_LOG" >/dev/null || { cat "$EVAL_LOG"; red "eval rows missing fields"; }
jq -es 'map(select(.task_id == "c2")) | .[0].retried == true and .[0].outcome == "err"' \
    "$EVAL_LOG" >/dev/null || { cat "$EVAL_LOG"; red "c2 eval row wrong"; }
green "eval log: 4 rows, full schema, retry + outcome recorded"

SB_JSON=$("$SCOREBOARD" --json "$EVAL_LOG")
printf '%s' "$SB_JSON" | jq -e '
    length == 1
    and .[0].agent == "bash"
    and .[0].tasks == 4
    and .[0].pass == 3
    and .[0].retries == 1
    and .[0].checked == 3
    and .[0].first_try_pass_rate == 0.75
' >/dev/null || { printf '%s\n' "$SB_JSON"; red "scoreboard aggregation wrong"; }
green "scoreboard --json: tasks=4 pass=3 retries=1 first_try=75%"

"$SCOREBOARD" "$EVAL_LOG" | grep -q "bash" || red "scoreboard table missing agent row"
green "scoreboard table renders"

# ============================================================================
heading "All executed-check shape tests passed"
green "marker pass, check-gated fail, check.sh fallback, null fields, kill switch, env fallback"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
