#!/usr/bin/env bash
# coordinator-codex.sh — Launch a one-shot Codex coordinator.
#
# Codex CLI does not expose Claude Code's --append-system-prompt flag. Feed
# the rendered coordinator instructions and the user's request together on
# stdin so `codex exec` receives the same operating procedure.

set -euo pipefail

SYSTEM_PROMPT_FILE="${1:?coordinator-codex.sh: missing system-prompt file (arg 1)}"
INITIAL_PROMPT_FILE="${2:?coordinator-codex.sh: missing initial-prompt file (arg 2)}"

ARGS=(exec --dangerously-bypass-approvals-and-sandbox -C "$PWD")
[ -n "${COORD_MODEL:-}" ] && ARGS+=(-m "$COORD_MODEL")

if {
    cat "$SYSTEM_PROMPT_FILE"
    printf '\n\n---\n\n# User Request\n\n'
    cat "$INITIAL_PROMPT_FILE"
} | codex "${ARGS[@]}" -; then
    RC=0
else
    RC=$?
fi

rm -f "$INITIAL_PROMPT_FILE"
exit "$RC"
