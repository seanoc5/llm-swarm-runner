#!/usr/bin/env bash
#
# test-shape-swarm.sh — Non-LLM shape test for the worker-listener protocol.
#
# Verifies the orchestration plumbing — v2 atomic-claim, outcome JSON, queue
# ordering, and v1 legacy fallback — without invoking any actual LLM. The
# listener's `bash` fallback agent (used when AGENT is neither claude nor
# gemini) executes task briefs as shell commands, which makes deterministic
# assertions trivial.
#
# This is the regression suite that doesn't burn LLM tokens, doesn't need
# auth, and doesn't depend on tmux. Pair with test-e2e-swarm.sh for full
# coverage when you want to validate the full claude/gemini path too.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

# --- Prereqs ---
command -v jq >/dev/null 2>&1 || red "jq required for outcome JSON validation"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t shape-test-XXXXXX)

cleanup() {
    [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" 2>/dev/null || true
    [ -n "${LISTENER_PID:-}" ] && wait "$LISTENER_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

heading "Shape test: worker-listener queue protocol"
echo "test dir: $TEST_DIR"
cd "$TEST_DIR"

# Pre-create the queue layout so we don't race with listener startup
mkdir -p .swarm/tasks/inbox .swarm/tasks/processing .swarm/tasks/done

# Start listener in background. Agent=bash means task briefs run as shell
# commands. WORKER_HEADLESS=1 is irrelevant for the bash branch but set for
# clarity (mirrors how automation should call the listener).
WORKER_HEADLESS=1 "$LISTENER" bash > listener.log 2>&1 &
LISTENER_PID=$!
sleep 0.5  # let listener finish creating dirs and enter polling loop

# Helper: poll for a condition with timeout. $1 = description, $2 = test cmd
wait_for() {
    # 30 s ceiling, polled every 0.25 s (issue #1000): returns the moment the
    # condition holds, so the ceiling only matters on a loaded runner.
    local desc="$1" cmd="$2" max=120
    for ((i=0; i<max; i++)); do
        if eval "$cmd"; then return 0; fi
        sleep 0.25
    done
    red "timeout waiting for: $desc"
}

# Helper: drop a v2 task atomically (mktemp + mv)
drop_v2() {
    local task_id="$1" body="$2"
    local tmp
    tmp=$(mktemp -p .swarm/tasks/inbox .tmp.XXXX.md)
    printf '%s\n' "$body" > "$tmp"
    mv "$tmp" ".swarm/tasks/inbox/$task_id.md"
}

# ============================================================================
heading "Test 1: v2 happy path"
# ============================================================================
TASK_ID="t1-$(date +%s)"
drop_v2 "$TASK_ID" 'echo SUCCESS_1 > test1-output.txt'
wait_for "test1 marker file" '[ -f test1-output.txt ]'
[ "$(cat test1-output.txt)" = "SUCCESS_1" ] || red "test1 output unexpected: $(cat test1-output.txt)"
green "agent ran (bash branch executed brief)"

wait_for "outcome JSON" "[ -f .swarm/tasks/done/$TASK_ID.ok.json ]"
DONE_JSON=".swarm/tasks/done/$TASK_ID.ok.json"
green "outcome JSON exists at $DONE_JSON"

# Validate every required field
jq -e --arg id "$TASK_ID" '
    .task_id == $id
    and .outcome == "ok"
    and .exit_code == 0
    and .agent == "bash"
    and .headless == true
    and .duration_seconds >= 0
    and (.started | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    and (.finished | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
' "$DONE_JSON" >/dev/null || {
    cat "$DONE_JSON"
    red "outcome JSON failed schema validation"
}
green "outcome JSON: task_id, outcome, exit_code, agent, headless, duration, started, finished all correct"

# Brief archived. The outcome JSON and the archive/cleanup are separate steps,
# so poll rather than assume they have all landed (issue #1000).
wait_for "brief archived and queue dirs drained" "[ -f .swarm/tasks/done/$TASK_ID.md ] && [ -z \"\$(ls .swarm/tasks/inbox/ 2>/dev/null)\" ] && [ -z \"\$(ls .swarm/tasks/processing/ 2>/dev/null)\" ]"
[ -f ".swarm/tasks/done/$TASK_ID.md" ] || red "brief not archived to done/"
green "brief archived to done/$TASK_ID.md"

# Inbox + processing drained
[ -z "$(ls .swarm/tasks/inbox/ 2>/dev/null)" ] || red "inbox not drained"
[ -z "$(ls .swarm/tasks/processing/ 2>/dev/null)" ] || red "processing not drained"
green "inbox and processing dirs drained"

# ============================================================================
heading "Test 2: v2 failure path (non-zero exit)"
# ============================================================================
TASK_ID2="t2-$(date +%s)"
drop_v2 "$TASK_ID2" 'echo run-and-fail; exit 7'

wait_for "err JSON" "[ -f .swarm/tasks/done/$TASK_ID2.err.json ]"
DONE_JSON=".swarm/tasks/done/$TASK_ID2.err.json"

jq -e --arg id "$TASK_ID2" '
    .task_id == $id
    and .outcome == "err"
    and .exit_code == 7
' "$DONE_JSON" >/dev/null || {
    cat "$DONE_JSON"
    red "err JSON wrong fields"
}
green ".err.json written with exit_code=7, outcome=err"

# A .ok.json must NOT exist for this task_id
[ ! -f ".swarm/tasks/done/$TASK_ID2.ok.json" ] || red "spurious .ok.json for failed task"
green "no .ok.json for failed task"

# ============================================================================
heading "Test 3: v1 legacy path (.agent-task.md → .agent-task-last.md)"
# ============================================================================
echo 'echo LEGACY_OK > legacy-output.txt' > .agent-task.md

wait_for "legacy output" '[ -f legacy-output.txt ]'
[ "$(cat legacy-output.txt)" = "LEGACY_OK" ] || red "legacy output unexpected"
green "legacy v1 task ran"

# The archive move happens after the agent exits, i.e. after legacy-output.txt
# appears, so poll for it rather than checking at once (issue #1000).
wait_for "legacy archive" '[ -f .agent-task-last.md ] && [ ! -f .agent-task.md ]'
[ -f ".agent-task-last.md" ] || red "legacy file not archived"
[ ! -f ".agent-task.md" ] || red ".agent-task.md should have been moved"
green "legacy v1: archived to .agent-task-last.md, original gone"

# Legacy should NOT write any v2 outcome JSON
LEGACY_JSONS=$(find .swarm/tasks/done -name 'legacy-*.json' 2>/dev/null)
[ -z "$LEGACY_JSONS" ] || red "legacy task wrote outcome JSON (should not)"
green "legacy v1 correctly skipped outcome JSON"

# ============================================================================
heading "Test 4: 3 v2 tasks queued — strict lexicographic order"
# ============================================================================
for n in 1 2 3; do
    drop_v2 "t4-$(printf '%03d' $n)" "echo step-$n >> sequence.txt"
done

wait_for "all 3 lines in sequence.txt" '[ -f sequence.txt ] && [ "$(wc -l < sequence.txt)" = "3" ]'

EXPECTED=$(printf 'step-1\nstep-2\nstep-3\n')
ACTUAL=$(cat sequence.txt)
[ "$ACTUAL" = "$EXPECTED" ] || {
    echo "expected:"; echo "$EXPECTED"
    echo "actual:"; echo "$ACTUAL"
    red "tasks not processed in lex order"
}
green "3 tasks processed in lex order"

# The third agent's sequence line lands BEFORE its outcome JSON (the listener
# writes that after the agent exits), so wait for the files, not just the
# lines (issue #1000: "expected 3 .ok.json files; got 2").
wait_for "3 t4 outcome JSONs" '[ "$(ls .swarm/tasks/done/t4-*.ok.json 2>/dev/null | wc -l)" = 3 ]'
JSON_COUNT=$(ls .swarm/tasks/done/t4-*.ok.json 2>/dev/null | wc -l)
[ "$JSON_COUNT" = "3" ] || red "expected 3 .ok.json files; got $JSON_COUNT"
green "3 outcome JSONs written"

# ============================================================================
heading "Test 5: v2 inbox ignored when filename starts with '.tmp.'"
# ============================================================================
# .tmp.* files represent in-flight atomic writes that must NOT be claimed.
# Drop a .tmp.XXXX.md without renaming and verify the listener never picks it up.
TMP_FILE=$(mktemp -p .swarm/tasks/inbox .tmp.lingering.XXXX.md)
echo 'touch should-not-exist' > "$TMP_FILE"

# Wait 3 polling cycles; if the listener wrongly claimed it, marker would appear
sleep 3
[ ! -f "should-not-exist" ] || red "listener wrongly claimed a .tmp.* file"
[ -f "$TMP_FILE" ] || red ".tmp.* file disappeared (should still be in inbox)"
green ".tmp.* file in inbox correctly ignored"

# Clean it up so it doesn't pollute test runs
rm -f "$TMP_FILE"

# ============================================================================
heading "All shape tests passed"
green "v2 happy path, v2 failure path, v1 legacy, lex ordering, .tmp.* exclusion"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
