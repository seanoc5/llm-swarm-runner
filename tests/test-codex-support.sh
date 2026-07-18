#!/usr/bin/env bash
# test-codex-support.sh — Deterministic Codex coordinator + worker shape test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$(mktemp -d -t codex-shape-XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODEX_ARGS_LOG"
if [ ! -t 0 ]; then
    cat >> "$CODEX_STDIN_LOG"
fi
exit "${CODEX_EXIT:-0}"
EOF
chmod +x "$TEST_DIR/bin/codex"

export PATH="$TEST_DIR/bin:$PATH"
export CODEX_ARGS_LOG="$TEST_DIR/codex.args"
export CODEX_STDIN_LOG="$TEST_DIR/codex.stdin"

printf 'SYSTEM PROCEDURE\n' > "$TEST_DIR/system.md"
printf 'USER REQUEST\n' > "$TEST_DIR/user.md"
COORD_MODEL=test-codex "$ROOT/scripts/coordinator-codex.sh" \
    "$TEST_DIR/system.md" "$TEST_DIR/user.md"

grep -q 'exec --dangerously-bypass-approvals-and-sandbox' "$CODEX_ARGS_LOG"
grep -q -- '-m test-codex -' "$CODEX_ARGS_LOG"
grep -q 'SYSTEM PROCEDURE' "$CODEX_STDIN_LOG"
grep -q 'USER REQUEST' "$CODEX_STDIN_LOG"
[ ! -e "$TEST_DIR/user.md" ]
echo "✓ codex coordinator wrapper passes model, bypass flag, and combined prompt"

printf 'USER FAILURE REQUEST\n' > "$TEST_DIR/user-fail.md"
set +e
CODEX_EXIT=9 "$ROOT/scripts/coordinator-codex.sh" \
    "$TEST_DIR/system.md" "$TEST_DIR/user-fail.md"
RC=$?
set -e
[ "$RC" -eq 9 ]
[ ! -e "$TEST_DIR/user-fail.md" ]
echo "✓ codex coordinator wrapper removes its prompt file after a failed run"

: > "$CODEX_ARGS_LOG"
: > "$CODEX_STDIN_LOG"
WT="$TEST_DIR/wt"
mkdir -p "$WT/.swarm/tasks/inbox"
printf 'WORKER TASK\n' > "$WT/.swarm/tasks/inbox/t1.md"

set +e
(
    cd "$WT"
    CODEX_EXIT=7 WORKER_HEADLESS=1 WORKER_MODEL=test-worker \
        LLM_SWARM_DIR="$ROOT" timeout 4 "$ROOT/scripts/worker-listener.sh" codex
)
RC=$?
set -e
[ "$RC" -eq 124 ]

OUTCOME="$WT/.swarm/tasks/done/t1.err.json"
[ -f "$OUTCOME" ]
grep -q '"exit_code": 7' "$OUTCOME"
grep -q '"agent": "codex"' "$OUTCOME"
grep -q 'exec -m test-worker --dangerously-bypass-approvals-and-sandbox' "$CODEX_ARGS_LOG"
echo "✓ codex worker path records a failed run as structured .err.json and keeps listening"
