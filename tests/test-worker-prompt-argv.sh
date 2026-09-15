#!/usr/bin/env bash
#
# test-worker-prompt-argv.sh — Regression test for issue #415.
#
# worker-listener.sh used to deliver both the worker-conventions system
# prompt (prompts/worker.md) and the per-task brief to a claude worker via
# argv: `--append-system-prompt "$(cat worker.md)"` and a positional/`-p`
# prompt argument. Since a worker's own `/proc/<pid>/cmdline` is visible to
# any process search it runs (`pgrep -f`, `ps aux | grep`, ...), a brief or
# worker.md containing a common English phrase (`git commit`, `pre-commit`,
# ...) could make the worker match its own process — see prompts/worker.md
# § "Process polling inside worker containers" and issue #124.
#
# The fix: claude now receives worker.md via `--append-system-prompt-file
# <path>` (only the path reaches argv) and the task brief over stdin (not
# on argv at all). This test proves both, at two levels:
#   1. dispatch_agent() called directly (both HEADLESS=1 and the default
#      interactive branch) against a stub `claude` that records its argv
#      and stdin separately.
#   2. A real end-to-end run of the listener loop (claim -> dispatch ->
#      outcome) in headless mode, confirming the wiring holds together.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t worker-prompt-argv-XXXXXX)
LISTENER_PID=""
cleanup() {
    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null || true
    [ -n "$LISTENER_PID" ] && wait "$LISTENER_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        printf 'KEEP=1: leaving %s for inspection\n' "$TEST_DIR"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

SENTINEL_WORKER_MD='SENTINEL_WORKER_MD_marker_git_commit_pre_commit_gh_pr_create'
SENTINEL_TASK='SENTINEL_TASK_BODY_marker_git_commit_pgrep_f_pre_commit_gh_pr_merge'

mkdir -p "$TEST_DIR/runner/prompts"
printf '%s\n' "$SENTINEL_WORKER_MD" > "$TEST_DIR/runner/prompts/worker.md"
WORKER_MD_PATH="$TEST_DIR/runner/prompts/worker.md"

# --- Stub `claude` CLI -------------------------------------------------------
# Records its own argv (one arg per line, unambiguous) and, separately,
# whatever arrives on stdin — the two channels this test must tell apart.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
: > "$CLAUDE_ARGS_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$CLAUDE_ARGS_LOG"; done
: > "$CLAUDE_STDIN_LOG"
if [ ! -t 0 ]; then cat > "$CLAUDE_STDIN_LOG"; fi
slug="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
dir="$HOME/.claude/projects/$slug"
mkdir -p "$dir"
head -c 2000 /dev/zero | tr '\0' 'x' > "$dir/session.jsonl"
exit "${CLAUDE_STUB_EXIT:-0}"
STUB
chmod +x "$TEST_DIR/bin/claude"
export PATH="$TEST_DIR/bin:$PATH"

heading "Part 1: dispatch_agent() called directly, both HEADLESS modes"

extract_fn() { sed -n "/^${1}() {/,/^}/p" "$LISTENER"; }
DISPATCH_BODY="$(extract_fn dispatch_agent)"
[ -n "$DISPATCH_BODY" ] || red "could not extract dispatch_agent() from $LISTENER — has it been renamed?"
eval "$DISPATCH_BODY"

AGENT=claude
MODEL_OPTS=()
WORKER_SYSTEM_PROMPT_OPTS=(--append-system-prompt-file "$WORKER_MD_PATH")
CODEX_PREFIX=""

mkdir -p "$TEST_DIR/work1"
cd "$TEST_DIR/work1"
export HOME="$TEST_DIR/work1/home"
export CLAUDE_ARGS_LOG="$TEST_DIR/work1/claude.args"
export CLAUDE_STDIN_LOG="$TEST_DIR/work1/claude.stdin"

for HEADLESS in 1 0; do
    : > "$CLAUDE_ARGS_LOG"; : > "$CLAUDE_STDIN_LOG"
    dispatch_agent "$SENTINEL_TASK"
    [ "$DISPATCH_RC" = "0" ] || red "HEADLESS=$HEADLESS: dispatch_agent exited $DISPATCH_RC"

    grep -qF -- "--append-system-prompt-file" "$CLAUDE_ARGS_LOG" \
        || red "HEADLESS=$HEADLESS: --append-system-prompt-file missing from argv"
    grep -qF -- "$WORKER_MD_PATH" "$CLAUDE_ARGS_LOG" \
        || red "HEADLESS=$HEADLESS: worker.md path missing from argv"
    grep -qF -- "$SENTINEL_WORKER_MD" "$CLAUDE_ARGS_LOG" \
        && red "HEADLESS=$HEADLESS: worker.md CONTENT leaked into argv"
    grep -qF -- "$SENTINEL_TASK" "$CLAUDE_ARGS_LOG" \
        && red "HEADLESS=$HEADLESS: task brief leaked into argv"
    if [ "$HEADLESS" = "1" ]; then
        grep -qF -- "-p" "$CLAUDE_ARGS_LOG" || red "HEADLESS=1: -p missing from argv"
    fi
    grep -qF -- "$SENTINEL_TASK" "$CLAUDE_STDIN_LOG" \
        || red "HEADLESS=$HEADLESS: task brief missing from stdin"
    green "HEADLESS=$HEADLESS: worker.md delivered by path only, task brief delivered on stdin only"
done

heading "Part 2: real end-to-end listener run (headless), claim -> dispatch -> outcome"

cd "$TEST_DIR"
mkdir seed && cd seed
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m initial
cd "$TEST_DIR"
git clone -q seed "$TEST_DIR/wt" >/dev/null

mkdir -p "$TEST_DIR/wt/.swarm/tasks/inbox"
TMP="$(mktemp -p "$TEST_DIR/wt/.swarm/tasks/inbox" .tmp.XXXX.md)"
printf '%s\n' "$SENTINEL_TASK" > "$TMP"
mv "$TMP" "$TEST_DIR/wt/.swarm/tasks/inbox/t1.md"

(
    cd "$TEST_DIR/wt"
    env WORKER_HEADLESS=1 LLM_SWARM_DIR="$TEST_DIR/runner" \
        HOME="$TEST_DIR/wt/home" \
        CLAUDE_ARGS_LOG="$TEST_DIR/wt/claude.args" \
        CLAUDE_STDIN_LOG="$TEST_DIR/wt/claude.stdin" \
        timeout 20 "$LISTENER" claude > "$TEST_DIR/wt/listener.log" 2>&1
) &
LISTENER_PID=$!

for ((i=0; i<20; i++)); do
    [ -f "$TEST_DIR/wt/.swarm/tasks/done/t1.ok.json" ] && break
    [ -f "$TEST_DIR/wt/.swarm/tasks/done/t1.err.json" ] && break
    sleep 0.5
done
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=""

[ -f "$TEST_DIR/wt/.swarm/tasks/done/t1.ok.json" ] || [ -f "$TEST_DIR/wt/.swarm/tasks/done/t1.err.json" ] \
    || red "listener never wrote an outcome for t1 — see $TEST_DIR/wt/listener.log"

[ -f "$TEST_DIR/wt/claude.args" ] || red "stub claude never ran"
grep -qF -- "--append-system-prompt-file" "$TEST_DIR/wt/claude.args" \
    || red "end-to-end: --append-system-prompt-file missing from argv"
grep -qF -- "$SENTINEL_WORKER_MD" "$TEST_DIR/wt/claude.args" \
    && red "end-to-end: worker.md CONTENT leaked into argv"
grep -qF -- "$SENTINEL_TASK" "$TEST_DIR/wt/claude.args" \
    && red "end-to-end: task brief leaked into argv"
grep -qF -- "$SENTINEL_TASK" "$TEST_DIR/wt/claude.stdin" \
    || red "end-to-end: task brief missing from stdin"
green "end-to-end headless run: brief claimed, dispatched with no prompt text on argv, outcome written"

heading "All worker-prompt-argv checks passed"
