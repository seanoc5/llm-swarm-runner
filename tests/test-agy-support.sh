#!/usr/bin/env bash
# Antigravity receives the swarm prompt and model; unknown workers fail closed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t agy-shape-XXXXXX)"
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [ -n "${AGY_ARGS_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$AGY_ARGS_LOG"
    printf '%s\n' "${!#}" >> "$AGY_PROMPT_LOG"
fi
printf 'AGY_RUN_COMPLETE\n'
exit "${AGY_EXIT:-0}"
EOF
chmod +x "$TEST_DIR/bin/agy"
export PATH="$TEST_DIR/bin:$PATH"
export AGY_ARGS_LOG="$TEST_DIR/agy.args" AGY_PROMPT_LOG="$TEST_DIR/agy.prompt"

printf 'COORDINATOR PROCEDURE\n' > "$TEST_DIR/system.md"
printf 'START REQUEST\n' > "$TEST_DIR/start.md"
COORD_MODEL=test-flash COORDINATOR_HEADLESS=1 "$ROOT/scripts/coordinator-agy.sh" "$TEST_DIR/system.md" "$TEST_DIR/start.md"
rg -q -- '--model test-flash --print' "$AGY_ARGS_LOG"
rg -q COORDINATOR.PROCEDURE "$AGY_PROMPT_LOG"
rg -q START.REQUEST "$AGY_PROMPT_LOG"
[ ! -e "$TEST_DIR/start.md" ]

printf 'INTERACTIVE REQUEST\n' > "$TEST_DIR/interactive.md"
COORD_MODEL=test-flash COORDINATOR_HEADLESS=0 "$ROOT/scripts/coordinator-agy.sh" "$TEST_DIR/system.md" "$TEST_DIR/interactive.md"
rg -q -- '--prompt-interactive' "$AGY_ARGS_LOG"

WT="$TEST_DIR/wt"
mkdir -p "$WT/.swarm/tasks/inbox"
printf 'WORKER TASK\n' > "$WT/.swarm/tasks/inbox/t1.md"
set +e
(cd "$WT" && AGY_EXIT=7 WORKER_HEADLESS=1 WORKER_MODEL=test-worker LLM_SWARM_DIR="$ROOT" timeout 4 "$ROOT/scripts/worker-listener.sh" agy) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ]
rg -q '"exit_code": 7' "$WT/.swarm/tasks/done/t1.err.json"
rg -q '"agent": "agy"' "$WT/.swarm/tasks/done/t1.err.json"
rg -q -- '--model test-worker --dangerously-skip-permissions --print' "$AGY_ARGS_LOG"
rg -q WORKER.TASK "$AGY_PROMPT_LOG"
rg -q 'Worker conventions' "$AGY_PROMPT_LOG"

if (cd "$WT" && LLM_SWARM_DIR="$ROOT" COORDINATOR_CMD=unknown NON_INTERACTIVE=1 WATCH=0 \
    "$ROOT/llm-start.sh" 'bad backend') >"$TEST_DIR/unknown-coord.log" 2>&1; then
    echo 'FAIL: unsupported coordinator backend succeeded' >&2
    exit 1
fi
rg -q 'unsupported COORDINATOR_CMD' "$TEST_DIR/unknown-coord.log"

printf 'touch %s\n' "$TEST_DIR/should-not-exist" > "$WT/.swarm/tasks/inbox/t2.md"
if (cd "$WT" && LLM_SWARM_DIR="$ROOT" "$ROOT/scripts/worker-listener.sh" unknown) >"$TEST_DIR/unknown.log" 2>&1; then
    echo 'FAIL: unsupported worker backend succeeded' >&2
    exit 1
fi
[ ! -e "$TEST_DIR/should-not-exist" ]
rg -q 'unsupported WORKER_CMD' "$TEST_DIR/unknown.log"
echo 'PASS: agy coordinator/worker prompts and models, failure outcome, unknown-backend guard'
