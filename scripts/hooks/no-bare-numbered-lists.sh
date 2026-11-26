#!/usr/bin/env bash
#
# no-bare-numbered-lists.sh — user-level Claude Code hook (issue #800).
# Catches a reply that contains a bare "1." / "2)" list outside a code fence.
# The terminal renumbers every "N." list from 1, so two lists in one reply both
# read "1, 2, 3" and "your 2" is ambiguous. The regex lives in
# lint-coordinator-reply.sh (rule bare-list), shared with swarm coordinators.
#
# Two modes, never a resend:
#   Stop (no args): on a hit, save a reminder for this session and exit 0.
#     It used to exit 2, which made the model resend a reply the operator had
#     already read: the same message twice, looking like a glitch (2026-11-26).
#   --remind (UserPromptSubmit): print the saved reminder, if any, as context
#     for the next reply, then delete it. Never blocks the prompt.
#
# Install in ~/.claude/settings.json:
#   "Stop":             [{"hooks": [{"type": "command", "command": "<this script>"}]}]
#   "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "<this script> --remind"}]}]
#
# State: ${BARE_LIST_STATE_DIR:-~/.local/state/llm-swarm/bare-list-pending}/<session_id>.
# Any failure (no jq, unreadable transcript) does nothing. Opt out: NO_BARE_LISTS_HOOK=0.
set -uo pipefail
input="$(cat)"   # drain stdin first so the writer never sees a broken pipe
[ "${NO_BARE_LISTS_HOOK:-1}" = "0" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
dir="${BARE_LIST_STATE_DIR:-$HOME/.local/state/llm-swarm/bare-list-pending}"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
sid="${sid//[^A-Za-z0-9_-]/}"; sid="${sid:-nosession}"
note="$dir/$sid"

if [ "${1:-}" = "--remind" ]; then
    [ -s "$note" ] || exit 0
    cat "$note"; rm -f "$note"
    exit 0
fi

text="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)"
if [ -z "$text" ]; then
    tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    # Text blocks of every assistant entry after the last real user prompt (a reply split by tool calls spans several records).
    [ -n "$tp" ] && [ -r "$tp" ] && text="$(jq -rs '(to_entries | map(select(.value.type=="user" and ((.value.message.content|type)=="string" or ((.value.message.content|type)=="array" and (.value.message.content|any(.type=="text")))))) | last | .key // -1) as $u | .[$u+1:][] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$tp" 2>/dev/null || true)"
fi
[ -n "$text" ] || exit 0
self="$(readlink -f "${BASH_SOURCE[0]}")"
lint="$(dirname "$self")/../lint-coordinator-reply.sh"
[ -x "$lint" ] || exit 0
hit="$(printf '%s\n' "$text" | "$lint" --only bare-list 2>/dev/null)" || true
[ -n "$hit" ] || exit 0
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s\n' "Reminder from the bare-list hook: your previous reply used a bare numbered list (\"${hit#bare-list: }\"). Don't resend it. Use letter labels (A1, B1...) from now on, continuing letters already used; if the operator answers \"your 2\", ask which list they mean." > "$note"
exit 0
