#!/usr/bin/env bash
#
# test-shape-worker-prompt-file.sh — WORKER_PROMPT_FILE must ride every
# env hand-off between llm-start.sh and the claude process, or a per-swarm
# override silently falls back to prompts/worker.md (issue #510):
#   llm-start.sh        -> tmux session env
#   provision-worker.sh -> tmux window command line
#   sandbox.sh          -> docker -e pass-through
#   worker-listener.sh  -> resolves the path and passes it to the agent
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for f in llm-start.sh scripts/provision-worker.sh sandbox.sh scripts/worker-listener.sh; do
    grep -q 'WORKER_PROMPT_FILE' "$ROOT/$f" \
        || red "$f does not hand WORKER_PROMPT_FILE through (see header)"
    green "$f names WORKER_PROMPT_FILE"
done

# Resolution rules, exercised in isolation (same case statement as the listener).
resolve() {
    local LLM_SWARM_DIR=/x WORKER_PROMPT_FILE="${1:-}"
    case "${WORKER_PROMPT_FILE:-}" in
        "")  echo "$LLM_SWARM_DIR/prompts/worker.md" ;;
        /*)  echo "$WORKER_PROMPT_FILE" ;;
        *)   echo "$LLM_SWARM_DIR/prompts/$WORKER_PROMPT_FILE" ;;
    esac
}
[ "$(resolve)" = /x/prompts/worker.md ]                 || red "unset should resolve to worker.md"
[ "$(resolve worker-bare.md)" = /x/prompts/worker-bare.md ] || red "relative name should resolve under prompts/"
[ "$(resolve /abs/p.md)" = /abs/p.md ]                   || red "absolute path should pass through"
green "resolution: unset / relative / absolute"

[ -r "$ROOT/prompts/worker-bare.md" ] || red "prompts/worker-bare.md missing"
green "prompts/worker-bare.md present"
