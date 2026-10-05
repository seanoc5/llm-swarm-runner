#!/usr/bin/env bash
# A completed one-shot coordinator must remain visible and accept a new run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t codex-pane-XXXXXX)"
PROJECT="$TEST_DIR/codex-pane-$$"
SOCKET="swarm-$(basename "$PROJECT")"
SESSION="llm-$(basename "$PROJECT")"
cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$PROJECT" "$TEST_DIR/bin"
git -C "$PROJECT" init -q
cat > "$TEST_DIR/bin/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'CODEX_RUN_COMPLETE\n'
EOF
chmod +x "$TEST_DIR/bin/codex"
export PATH="$TEST_DIR/bin:$PATH"
export LLM_SWARM_DIR="$ROOT" COORDINATOR_CMD=codex
export NON_INTERACTIVE=1 WATCH=0 STATUS=0
# Use a non-login shell in this isolated tmux server so the test's CLI stub
# stays first on PATH; the user's login profile may otherwise reset PATH.
tmux -L "$SOCKET" new-session -d -s setup -n setup -c "$PROJECT"
tmux -L "$SOCKET" set-option -g default-shell /bin/sh

run_coordinator() {
    (cd "$PROJECT" && "$ROOT/llm-start.sh" "$1") >/dev/null
    for ((attempt=0; attempt<150; attempt++)); do
        state="$(tmux -L "$SOCKET" list-panes -t "$SESSION:coordinator" -F '#{pane_dead}' 2>/dev/null || true)"
        if [ "$state" = 1 ]; then
            if tmux -L "$SOCKET" capture-pane -t "$SESSION:coordinator" -p | grep -q CODEX_RUN_COMPLETE; then
                return 0
            fi
        fi
        sleep 0.1
    done
    echo 'FAIL: completed Codex coordinator window disappeared or did not finish' >&2
    tmux -L "$SOCKET" list-panes -t "$SESSION:coordinator" -F '#{pane_dead} #{pane_dead_status} #{pane_current_command}' >&2 || true
    tmux -L "$SOCKET" capture-pane -t "$SESSION:coordinator" -p >&2 || true
    return 1
}
run_coordinator 'First coordinator turn'
echo 'PASS: completed Codex coordinator remains visible with its output'
run_coordinator 'Second coordinator turn'
echo 'PASS: a follow-up run replaces the completed pane and retains its output'
