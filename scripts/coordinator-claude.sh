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
#   COORDINATOR_ALLOW_BACKGROUND_TASKS=1
#                              Opt out of the foreground-only backstop below.
#                              Defaults to 0 (deny).
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

# Foreground-only backstop, mirroring sandbox.sh for workers (#301/#298).
# #301 covered worker containers only; the coordinator kept both doors open,
# and the incident that closed this gap was a coordinator (#383): an
# `until tmux capture-pane -t iss-873 | grep -qE 'APPROVE|BLOCK'; do sleep 20;
# done` loop started in the FOREGROUND — so the operator's
# block-background-shells.sh hook correctly saw nothing, since it only
# inspects run_in_background — was then promoted to a background task by the
# harness, outlived the window it was watching (reaped, so the grep could
# never match), and ran ~20h.
#
# The env var shuts all three doors: run_in_background is removed from the
# Bash tool schema, canAutoBackground goes false so a timed-out foreground
# command is not silently promoted, and the manual/deliver-message
# backgrounding path errors out. Door two is the one no PreToolUse hook can
# reach — a hook sees the outgoing call, not the harness's later decision to
# detach it.
#
# The trade-off is deliberate and is the operator's stated preference: a long
# command now BLOCKS this pane in full view rather than detaching into a
# `1 shell` indicator whose output goes nowhere anyone reads.
#
# gemini/codex coordinators ignore this var; prompts/coordinator.md remains
# their only guard, exactly as for workers under #301.
if [ "${COORDINATOR_ALLOW_BACKGROUND_TASKS:-0}" != "1" ]; then
    export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
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
