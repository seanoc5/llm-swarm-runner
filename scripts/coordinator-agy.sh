#!/usr/bin/env bash
# Launch an Antigravity coordinator with the rendered swarm instructions.
set -euo pipefail

# #660: llm-start.sh no longer leaves .env.example/.env defaults in the tmux
# server env (they masked <project>/.swarm/.env), so reload them here, for the
# project this pane is in. Caller-set variables still win.
# shellcheck source=_load-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_load-env.sh" "$PWD"

SYSTEM_PROMPT_FILE="${1:?missing coordinator prompt file}"
INITIAL_PROMPT_FILE="${2:?missing request file}"
ARGS=(--dangerously-skip-permissions)
[ -n "${COORD_MODEL:-}" ] && ARGS+=(--model "$COORD_MODEL")
if [ "${COORDINATOR_HEADLESS:-0}" = "1" ]; then
    ARGS+=(--print)
else
    ARGS+=(--prompt-interactive)
fi

PROMPT="$(cat "$SYSTEM_PROMPT_FILE")"$'\n\n---\n\n# User Request\n\n'"$(cat "$INITIAL_PROMPT_FILE")"
rm -f "$INITIAL_PROMPT_FILE"
exec agy "${ARGS[@]}" "$PROMPT"
