#!/usr/bin/env bash
#
# test-task-done.sh — Regression test for issue #451.
#
# scripts/task-done.sh is the worker's own mandatory "I'm done" step: it
# atomically empties .swarm/tasks/processing/<id>.md into done/ and writes
# the single authoritative done/<id>.{ok,err}.json. This suite covers:
#   1. Happy path: standalone invocation does both moves correctly.
#   2. Duplicate suppression: a second call (or a reconciler re-checking)
#      for the same task_id never overwrites the first record.
#   3. Interactive-worker flow: end-to-end through the REAL
#      worker-listener.sh (like test-shape-noop-detect.sh), with a stub
#      `claude` binary that calls task-done.sh itself mid-"session" before
#      exiting — proving the listener's own exit-triggered write becomes a
#      no-op once the worker already recorded the outcome, and that
#      processing/ is empty (the false-alarm half of #450 finding 3) well
#      before the dispatched process ever returns.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

command -v jq >/dev/null 2>&1 || red "jq required for outcome JSON validation"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_DONE="$SCRIPT_DIR/../scripts/task-done.sh"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$TASK_DONE" ] || red "task-done.sh not executable: $TASK_DONE"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t task-done-XXXXXX)
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

# ── Fixture: a bare git repo + one worktree, so `git rev-parse
# --show-toplevel` (task-done.sh's queue-root resolution) works. ──────────
cd "$TEST_DIR"
git init -q -b master repo
cd repo
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
mkdir -p .swarm/tasks/inbox .swarm/tasks/processing .swarm/tasks/done .swarm/tasks/status
green "fixture ready: $TEST_DIR/repo"

# ============================================================================
heading "Test 1 (happy path): moves the brief and writes the outcome record"
# ============================================================================
echo '## Task

Do something.' > .swarm/tasks/processing/t1.md

"$TASK_DONE" t1 ok >/dev/null

[ ! -e .swarm/tasks/processing/t1.md ] || red "t1: brief was not removed from processing/"
[ -f .swarm/tasks/done/t1.md ] || red "t1: brief was not moved into done/"
[ -f .swarm/tasks/done/t1.ok.json ] || red "t1: outcome record not written"
jq -e '.task_id == "t1" and .outcome == "ok" and .finished != null and .source == "task-done.sh"' \
    .swarm/tasks/done/t1.ok.json >/dev/null \
    || { cat .swarm/tasks/done/t1.ok.json; red "t1: outcome JSON missing expected fields"; }
green "processing/ emptied, brief archived to done/, done/t1.ok.json written with expected fields"

# ============================================================================
heading "Test 2 (duplicate suppression): a second call never overwrites the first"
# ============================================================================
FIRST_MTIME=$(stat -c %Y .swarm/tasks/done/t1.ok.json 2>/dev/null || stat -f %m .swarm/tasks/done/t1.ok.json)
sleep 1.1
"$TASK_DONE" t1 err "pretend failure" >/dev/null

[ ! -e .swarm/tasks/done/t1.err.json ] || red "t1: duplicate call created a second (err) record alongside the first"
SECOND_MTIME=$(stat -c %Y .swarm/tasks/done/t1.ok.json 2>/dev/null || stat -f %m .swarm/tasks/done/t1.ok.json)
[ "$FIRST_MTIME" = "$SECOND_MTIME" ] || red "t1: the existing ok.json was rewritten by a duplicate call"
jq -e '.outcome == "ok"' .swarm/tasks/done/t1.ok.json >/dev/null \
    || red "t1: outcome flipped from ok to err on a duplicate call"
green "second call for the same task_id is a no-op — original ok.json untouched, no err.json created"

# ============================================================================
heading "Test 3 (err outcome + reason): fields recorded correctly"
# ============================================================================
echo '## Task

Do something else.' > .swarm/tasks/processing/t2.md
"$TASK_DONE" t2 err "acceptance check never resolved" >/dev/null

[ ! -e .swarm/tasks/processing/t2.md ] || red "t2: brief was not removed from processing/"
jq -e '.outcome == "err" and .exit_code == 1 and (.reason == "acceptance check never resolved")' \
    .swarm/tasks/done/t2.err.json >/dev/null \
    || { cat .swarm/tasks/done/t2.err.json; red "t2: err outcome/reason not recorded correctly"; }
green "err outcome records exit_code=1 and the given reason"

# ============================================================================
heading "Test 4 (missing brief tolerated): outcome still written if processing/ already empty"
# ============================================================================
"$TASK_DONE" t3 ok >/dev/null
jq -e '.task_id == "t3" and .outcome == "ok"' .swarm/tasks/done/t3.ok.json >/dev/null \
    || red "t3: outcome not written despite no processing/t3.md ever existing"
green "no processing/<id>.md to move (already gone, or never existed) does not block the outcome write"

# ============================================================================
heading "Test 5 (usage errors): bad args exit non-zero without touching the queue"
# ============================================================================
"$TASK_DONE" >/dev/null 2>&1 && red "no args should fail" || true
"$TASK_DONE" t4 maybe >/dev/null 2>&1 && red "invalid outcome word should fail" || true
[ ! -e .swarm/tasks/done/t4.ok.json ] && [ ! -e .swarm/tasks/done/t4.err.json ] \
    || red "t4: a rejected invocation should not have written anything"
green "missing task_id / invalid outcome word both rejected, nothing written"

# ============================================================================
heading "Test 6 (interactive-worker flow): worker calls task-done.sh mid-session"
# ============================================================================
# Stub `claude` CLI: on launch, calls task-done.sh itself (simulating the
# worker's own mandatory last step, prompts/worker.md § "Task completion"),
# THEN sleeps briefly before exiting — modeling the real gap between an
# interactive worker finishing its bookkeeping and a human eventually
# typing /quit. While it sleeps, processing/ must already be empty and the
# outcome record must already exist — well before dispatch_agent returns.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/claude" <<STUB
#!/usr/bin/env bash
"$TASK_DONE" "\$SWARM_TEST_TASK_ID" ok >/dev/null
sleep 1
exit 0
STUB
chmod +x "$TEST_DIR/bin/claude"

WT="$TEST_DIR/wt-interactive"
git clone -q "$TEST_DIR/repo" "$WT"
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing" "$WT/.swarm/tasks/done" "$WT/.swarm/tasks/status" "$WT/home"

drop_v2() {
    local dir="$1" task_id="$2" body="$3"
    local tmp
    tmp=$(mktemp -p "$dir/.swarm/tasks/inbox" .tmp.XXXX.md)
    printf '%s\n' "$body" > "$tmp"
    mv "$tmp" "$dir/.swarm/tasks/inbox/$task_id.md"
}

(
    cd "$WT" && env PATH="$TEST_DIR/bin:$PATH" WORKER_HEADLESS=1 \
        HOME="$WT/home" SWARM_TEST_TASK_ID=i1 WORKER_CHECK=0 \
        "$LISTENER" claude > listener.log 2>&1
) &
LISTENER_PIDS+=($!)
sleep 0.3

drop_v2 "$WT" "i1" '## Task

Do something.'

# The window this test exists to prove: task-done.sh runs and empties
# processing/ WHILE the stub is still sleeping (i.e. before
# dispatch_agent returns to the listener's main loop).
wait_for "i1 processing/ emptied by task-done.sh" \
    '[ -z "$(find "'"$WT"'/.swarm/tasks/processing" -maxdepth 1 -type f 2>/dev/null)" ]'
wait_for "i1 outcome recorded" '[ -f "'"$WT"'/.swarm/tasks/done/i1.ok.json" ]'
jq -e '.source == "task-done.sh"' "$WT/.swarm/tasks/done/i1.ok.json" >/dev/null \
    || red "i1: outcome record should be task-done.sh's, not the listener's fallback"
green "processing/ emptied and outcome recorded by task-done.sh before the dispatched process even exited"

# Now let the stub finish (it's mid-sleep) and let the listener's own
# post-dispatch fallback run — it must detect the existing record and
# skip, not overwrite it or double-log a second write.
sleep 1.5
grep -q "Outcome already recorded by task-done.sh" "$WT/listener.log" \
    || { cat "$WT/listener.log"; red "i1: listener did not recognize the pre-existing task-done.sh record"; }
[ -f "$WT/.swarm/tasks/done/i1.md" ] || red "i1: brief was not archived to done/"
green "listener's own fallback recognized the existing record and skipped the duplicate write"

# ============================================================================
heading "All task-done.sh tests passed"
# ============================================================================
green "happy path, duplicate suppression, err+reason, missing-brief tolerance, usage errors, interactive-worker flow"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
