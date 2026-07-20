#!/usr/bin/env bash
# coordinator-claude.sh — Launch the Claude Code coordinator REPL.
#
# Called by llm-start.sh via tmux send-keys. Wrapping the launch in a script
# keeps the visible tmux line short (the long claude invocation lives here,
# not in the pane's scrollback) and centralizes auth-stripping, model
# defaulting, and the headless/interactive toggle.
#
# Args:
#   $1   path to rendered system prompt file (--append-system-prompt source)
#   $2   path to initial user prompt file   (passed as trailing positional)
#
# Env:
#   COORD_MODEL                Claude model id (default: claude-fable-5)
#   COORDINATOR_HEADLESS=1     Use claude -p (exits after the prompt prints)
#   COORDINATOR_USE_API_KEY=1  Keep ANTHROPIC_API_KEY in env (bills API, not Max OAuth)
#   STATUSLINE_PROBE           Path scripts/statusline-with-context.sh (if
#                              installed as this session's statusLine) dumps
#                              its raw stdin JSON to. Defaulted below to a
#                              project+role-scoped path rather than left to
#                              that script's own generic per-UID default —
#                              coordinator-watch.sh's AUTO_COMPACT feature
#                              reads this same file to decide when to
#                              compact, and the generic default would get
#                              silently clobbered by any other interactive
#                              `claude` session on the same host sharing the
#                              same UID. Caller-set values still win.

set -euo pipefail

SYSTEM_PROMPT_FILE="${1:?coordinator-claude.sh: missing system-prompt file (arg 1)}"
INITIAL_PROMPT_FILE="${2:?coordinator-claude.sh: missing initial-prompt file (arg 2)}"
MODEL="${COORD_MODEL:-claude-fable-5}"
export STATUSLINE_PROBE="${STATUSLINE_PROBE:-${XDG_RUNTIME_DIR:-/tmp}/claude-statusline-$(basename "$PWD")-coordinator.json}"

# Claude Max users authenticate via OAuth in ~/.claude/. If ANTHROPIC_API_KEY
# is set, claude-code prefers it over OAuth (silently bills the API account).
# Strip it so Max is used, unless caller explicitly opted into API billing.
if [ "${COORDINATOR_USE_API_KEY:-0}" != "1" ]; then
    unset ANTHROPIC_API_KEY
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "coordinator-claude: COORDINATOR_USE_API_KEY=1; ANTHROPIC_API_KEY in effect (billing API account)." >&2
fi

INITIAL_PROMPT="$(cat "$INITIAL_PROMPT_FILE")"
rm -f "$INITIAL_PROMPT_FILE"

ARGS=(--model "$MODEL"
      --append-system-prompt "$(cat "$SYSTEM_PROMPT_FILE")"
      --dangerously-skip-permissions)
[ "${COORDINATOR_HEADLESS:-0}" = "1" ] && ARGS+=(-p)
# Trailing positional: initial user message in REPL mode, print-prompt in -p mode.
ARGS+=("$INITIAL_PROMPT")

exec claude "${ARGS[@]}"
