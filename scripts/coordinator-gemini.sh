#!/usr/bin/env bash
# coordinator-gemini.sh — Launch the Gemini CLI coordinator.
#
# Usage: coordinator-gemini.sh <rendered-system-prompt-file> <request-file>
#
# Replaces the inline `gemini ...` line llm-start.sh used to type into the
# coordinator pane (#691). That line had no loader, so after #660 stopped
# leaking .env defaults into the tmux server env, a key set only in the
# project's .swarm/.env (COORDINATOR_VERBOSE, say) never reached gemini.
#
# Env: COORD_MODEL (model id), COORDINATOR_VERBOSE (default 1: -i, stay
# interactive after the prompt; 0: -p, exit after it).
set -uo pipefail

# #660: reload .env defaults for the project this pane is in; caller wins.
# shellcheck source=_load-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_load-env.sh" "$PWD"

SYSTEM_PROMPT_FILE="${1:?coordinator-gemini.sh: missing system-prompt file (arg 1)}"
INITIAL_PROMPT_FILE="${2:?coordinator-gemini.sh: missing request file (arg 2)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARGS=()
[ -n "${COORD_MODEL:-}" ] && ARGS+=(-m "$COORD_MODEL")
ARGS+=(--yolo --skip-trust)
# -i (--prompt-interactive) streams tool calls live and keeps gemini alive
# after the prompt; exit with /quit or Ctrl-D. -p exits after the prompt.
if [ "${COORDINATOR_VERBOSE:-1}" = "1" ]; then
    echo "COORDINATOR_VERBOSE=1: gemini will stay interactive after the prompt; exit with /quit."
    ARGS+=(-i)
else
    ARGS+=(-p)
fi

RC=0
GEMINI_SYSTEM_MD="$SYSTEM_PROMPT_FILE" gemini "${ARGS[@]}" "$(cat "$INITIAL_PROMPT_FILE")" || RC=$?
rm -f "$INITIAL_PROMPT_FILE"
# gemini-cli truncates server-side errors to "Operation cancelled"; the tail
# script surfaces the real payload from /tmp/gemini-*-error-*.json.
"$HERE/coordinator-error-tail.sh" || true
exit "$RC"
