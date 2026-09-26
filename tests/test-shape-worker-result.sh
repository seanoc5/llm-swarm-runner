#!/usr/bin/env bash
# Real listener loop with shell briefs and stubbed GitHub; no model/network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$(mktemp -d -t worker-result-XXXXXX)"
LISTENER_PID=""
cleanup() {
    if [ -n "$LISTENER_PID" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    fi
    if [ "${KEEP:-0}" = 1 ]; then
        echo "Fixtures: $TEST_DIR"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/wt-issue-900/.swarm/tasks/inbox"
export GH_LOG="$TEST_DIR/gh.log"
cat > "$TEST_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2" = "pr view" ]; then
    echo '<!-- SWARM_PENDING_BRIEF: queued -->'
fi
STUB
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"
cd "$TEST_DIR/wt-issue-900"
env LLM_SWARM_DIR= WORKER_MODEL= WORKER_HEADLESS=1 WORKER_CHECK=1 \
    WORKER_CHECK_CMD= WORKER_CHECK_RETRY=0 SWARM_EVAL_LOG="$TEST_DIR/eval.jsonl" \
    bash "$RUNNER/scripts/worker-listener.sh" bash > listener.log 2>&1 &
LISTENER_PID=$!

wait_for_footer() {
    local expected="$1"
    for ((attempt=0; attempt<100; attempt++)); do
        if [ "$(grep -c '^\[worker-run-ended ' listener.log || true)" -eq "$expected" ]; then
            return
        fi
        kill -0 "$LISTENER_PID" 2>/dev/null || { cat listener.log; fail "listener exited"; }
        sleep 0.1
    done
    cat listener.log
    fail "timed out waiting for footer $expected"
}

count=0
run_case() {
    local id="$1" status="$2" check="$3" outcome="$4" verification="$5"
    mkdir -p .swarm/tasks/status
    printf '%s\n' "$status" > ".swarm/tasks/status/$id.json"
    : > "$GH_LOG"
    printf 'true\n' > .swarm/tasks/inbox/.tmp.brief
    if [ -n "$check" ]; then
        printf '# <!-- SWARM_CHECK: %s -->\n' "$check" >> .swarm/tasks/inbox/.tmp.brief
    fi
    mv .swarm/tasks/inbox/.tmp.brief ".swarm/tasks/inbox/$id.md"
    count=$((count + 1))
    wait_for_footer "$count"
    jq -e --arg outcome "$outcome" --arg verification "$verification" \
        '.outcome == $outcome and .verification == $verification' \
        ".swarm/tasks/done/$id.$outcome.json" >/dev/null || fail "$id: incorrect outcome"
    tail -5 listener.log > "$TEST_DIR/$id.footer"
    [ "$(wc -l < "$TEST_DIR/$id.footer")" -eq 5 ] || fail "$id: footer length"
    grep -q '^Issue #900:' "$TEST_DIR/$id.footer" || fail "$id: missing context"
    grep -q '^Next:' "$TEST_DIR/$id.footer" || fail "$id: missing next action"
    grep -q '\[polling for next brief' "$TEST_DIR/$id.footer" || fail "$id: parked marker lost"
    if grep -qE 'TASK COMPLETE|Accept & merge|gh pr merge' "$TEST_DIR/$id.footer"; then
        fail "$id: unwarranted completion/merge claim"
    fi
}

run_case unchecked '{}' '' ok not-run
grep -q 'not verified by the listener' "$TEST_DIR/unchecked.footer" || fail "unchecked reads as verified"
run_case ready '{"state":"ready-for-review","pr":77}' true ok passed
grep -q 'handed back PR #77 for review' "$TEST_DIR/ready.footer" || fail "missing PR"
grep -q 'not merge approval' "$TEST_DIR/ready.footer" || fail "check pass reads as approval"
grep -q 'pr comment 77' "$GH_LOG" || fail "successful follow-up did not clear queued marker"

run_case failed '{"state":"ready-for-review","pr":77}' false err failed
[ ! -s "$GH_LOG" ] || fail "failed fix cleared pending warning"
grep -q 'Acceptance check: failed' "$TEST_DIR/failed.footer" || fail "missing check failure"
run_case blocked '{"state":"blocked","pr":77,"note":"Awaiting scope\nKeep existing data"}' '' err not-run
[ ! -s "$GH_LOG" ] || fail "blocked fix cleared pending warning"
grep -q '^Issue #900: blocked' "$TEST_DIR/blocked.footer" || fail "PR hides blocked state"
grep -q 'Awaiting scope Keep existing data' "$TEST_DIR/blocked.footer" || fail "multiline blocker lost"
jq -e '.task_state == "blocked" and (.reason | startswith("worker-blocked:"))' \
    .swarm/tasks/done/blocked.err.json >/dev/null || fail "blocker missing from durable outcome"
[ ! -e .swarm/tasks/done/blocked.ok.json ] || fail "blocked task also recorded ok"

run_case blocked_pass '{"state":"blocked","pr":77}' true err passed
[ ! -s "$GH_LOG" ] || fail "passing check erased blocker"
run_case no_pr '{"state":"done-no-pr","pr":null,"note":"No change needed"}' true ok passed
grep -q 'No change needed' "$TEST_DIR/no_pr.footer" || fail "no-PR context lost"
run_case malformed '{bad json' '' ok not-run
grep -q 'completion is not established' "$TEST_DIR/malformed.footer" || fail "invalid status treated as delivery"

# A v1 brief after a passing v2 check must not inherit that verification.
run_case last_checked '{"state":"done-no-pr"}' true ok passed
printf 'true\n' > .agent-task.md
count=$((count + 1))
wait_for_footer "$count"
tail -5 listener.log > "$TEST_DIR/legacy.footer"
grep -q 'Acceptance check: not run' "$TEST_DIR/legacy.footer" || fail "v1 claims check execution"

jq -es 'map(select(.task_id == "blocked")) | .[0].outcome == "err"
    and .[0].task_state == "blocked" and .[0].verification == "not-run"' \
    "$TEST_DIR/eval.jsonl" >/dev/null || fail "blocked task counted as success in eval log"
bash "$RUNNER/scripts/swarm-scoreboard.sh" --json "$TEST_DIR/eval.jsonl" \
    | jq -e '.[0] | .tasks == 8 and .pass == 3 and .checked == 5 and .unchecked == 3' \
    >/dev/null || fail "scoreboard counts unchecked/blocked tasks as passes"
# Historical unchecked ok rows also must not count as verified passes.
printf '%s\n' '{"agent":"bash","model":null,"outcome":"ok","check_exit":null,"duration_seconds":1,"retried":false}' \
    > "$TEST_DIR/historical.jsonl"
bash "$RUNNER/scripts/swarm-scoreboard.sh" --json "$TEST_DIR/historical.jsonl" \
    | jq -e '.[0] | .pass == 0 and .pass_rate == 0 and .first_try_pass_rate == 0 and .unchecked == 1' \
    >/dev/null || fail "historical unchecked ok counted as pass"

# Test the real watcher's pane fallback, without launching a watcher/tmux.
eval "$(sed -n '/^worker_task_done() {/,/^}/p' "$RUNNER/scripts/coordinator-watch.sh")"
SESSION_NAME=fixture
HAVE_JQ=1
mkdir -p "$TEST_DIR/pane-only/.swarm/tasks/processing"
touch "$TEST_DIR/pane-only/.swarm/tasks/processing/current.md"
tmux() { printf '%s\n' "$PANE_TEXT"; }
PANE_TEXT="$(cat "$TEST_DIR/blocked.footer")"
worker_task_done iss-900 "$TEST_DIR/pane-only" || fail "new process-ended marker not recognized"
PANE_TEXT='  TASK COMPLETE    exit=0    duration=42s'
worker_task_done iss-900 "$TEST_DIR/pane-only" || fail "old banner not recognized"
PANE_TEXT='printf "[worker-run-ended exit=0 duration=42s]"'
if worker_task_done iss-900 "$TEST_DIR/pane-only"; then fail "source text marked a live task done"; fi

eval "$(sed -n '/^detect_state() {/,/^}/p' "$RUNNER/scripts/check-stuck-workers.sh")"
[ "$(detect_state "$(cat "$TEST_DIR/blocked.footer")")" = IDLE-PARKED ] \
    || fail "new footer no longer recognized as a parked listener"

echo "PASS: truthful five-line results, blocked outcomes, scoreboard, legacy and watcher compatibility"
