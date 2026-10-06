#!/usr/bin/env bash
# Launch an Antigravity coordinator with the rendered swarm instructions.
set -euo pipefail

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
