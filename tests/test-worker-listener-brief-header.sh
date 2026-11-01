#!/usr/bin/env bash
#
# test-worker-listener-brief-header.sh — issue #587: a re-delivered brief
# must be visible in the worker pane and carry its own task id.
#
# Real listener loop (WORKER_HEADLESS=1, agent "claude") with a fake `claude`
# on PATH that records its stdin and $TASK_ID. Asserts:
#   1. the listener log's "Task received!" line names the brief path;
#   2. the prompt the agent receives leads with "[swarm] task_id=<id> brief=<path>";
#   3. the agent's environment has TASK_ID set (issue #610 regression guard);
#   4. the original brief text follows the header unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$(mktemp -d -t worker-listener-header-XXXXXX)"
LISTENER_PID=""
cleanup() {
    if [ -n "$LISTENER_PID" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    fi
    if [ "${KEEP:-0}" = 1 ]; then echo "Fixtures: $TEST_DIR"; else rm -rf "$TEST_DIR"; fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

WT="$TEST_DIR/wt-issue-587"
mkdir -p "$WT/.swarm/tasks/"{inbox,processing,status,done} "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/claude" <<FAKE
#!/usr/bin/env bash
cat > "$TEST_DIR/agent-stdin.txt"
printf '%s' "\${TASK_ID:-}" > "$TEST_DIR/agent-task-id.txt"
FAKE
chmod +x "$TEST_DIR/bin/claude"

cd "$WT"
TID="20261008-154655-1396"
printf 'BRIEF-BODY-LINE-1\nBRIEF-BODY-LINE-2\n' > .swarm/tasks/inbox/.tmp.brief
mv .swarm/tasks/inbox/.tmp.brief ".swarm/tasks/inbox/$TID.md"

env PATH="$TEST_DIR/bin:$PATH" LLM_SWARM_DIR= WORKER_MODEL= WORKER_HEADLESS=1 WORKER_CHECK=0 \
    bash "$RUNNER/scripts/worker-listener.sh" claude > listener.log 2>&1 &
LISTENER_PID=$!

for ((i = 0; i < 100; i++)); do
    [ -s "$TEST_DIR/agent-task-id.txt" ] && break
    kill -0 "$LISTENER_PID" 2>/dev/null || { cat listener.log; fail "listener exited early"; }
    sleep 0.1
done
[ -s "$TEST_DIR/agent-task-id.txt" ] || { cat listener.log; fail "fake agent never ran"; }

grep -q "Task received! id=$TID brief=.*processing/$TID.md" listener.log \
    || { cat listener.log; fail "Task received! line lacks id + brief path"; }
green "Task received! line names the task id and the brief path"

head -1 "$TEST_DIR/agent-stdin.txt" | grep -q "^\[swarm\] task_id=$TID brief=.*processing/$TID.md$" \
    || { cat "$TEST_DIR/agent-stdin.txt"; fail "prompt does not lead with the task header"; }
green "agent prompt leads with the [swarm] task_id/brief header"

[ "$(cat "$TEST_DIR/agent-task-id.txt")" = "$TID" ] || fail "TASK_ID not exported to the agent"
green "TASK_ID is exported into the agent environment"

grep -q "^BRIEF-BODY-LINE-1$" "$TEST_DIR/agent-stdin.txt" \
    && grep -q "^BRIEF-BODY-LINE-2$" "$TEST_DIR/agent-stdin.txt" \
    || fail "brief body missing after header"
green "brief body follows the header intact"
