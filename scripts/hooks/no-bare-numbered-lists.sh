#!/usr/bin/env bash
#
# no-bare-numbered-lists.sh — user-level Claude Code Stop hook (issue #800).
# Blocks a reply that contains a bare "1." / "2)" list outside a code fence and
# asks for letter labels (A1, B1...). The terminal renumbers every "N." list from
# 1, so two lists in one reply both read "1, 2, 3" and "your 2" is ambiguous.
# Prose rules and memories did not hold; this runs on every reply in every
# session, swarm or not. The regex lives in lint-coordinator-reply.sh (rule
# bare-list), so swarm coordinators and interactive sessions share one check.
#
# Install (user-level, covers every session) in ~/.claude/settings.json:
#   {"hooks": {"Stop": [{"hooks": [{"type": "command",
#     "command": "/path/to/llm-swarm-runner/scripts/hooks/no-bare-numbered-lists.sh"}]}]}}
#
# Input: Stop hook JSON on stdin (last_assistant_message, else transcript_path,
# stop_hook_active). Exit 2 + stderr = block and show the reason to the model;
# 0 = fine. Blocks at most once per reply chain (stop_hook_active => allow), and
# any failure (no jq, unreadable transcript) lets the reply through.
# Known trade-off: Stop runs after the reply is displayed, so a caught reply
# shows twice. Move the check to a pre-display hook if Claude Code gains one.
# Opt out for one session: NO_BARE_LISTS_HOOK=0.
set -uo pipefail
input="$(cat)"   # drain stdin first so the writer never sees a broken pipe
[ "${NO_BARE_LISTS_HOOK:-1}" = "0" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && exit 0
text="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)"
if [ -z "$text" ]; then
    tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    [ -n "$tp" ] && [ -r "$tp" ] && text="$(jq -rs '[.[] | select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | select(length > 0) | join("\n")] | last // empty' "$tp" 2>/dev/null || true)"
fi
[ -n "$text" ] || exit 0
self="$(readlink -f "${BASH_SOURCE[0]}")"
lint="$(dirname "$self")/../lint-coordinator-reply.sh"
[ -x "$lint" ] || exit 0
hit="$(printf '%s\n' "$text" | "$lint" --only bare-list 2>/dev/null)" || true
[ -n "$hit" ] || exit 0
echo "Relabel every list with a letter prefix (A1, B1...), continuing letters already used; resend. Bare numbered lists collapse to 1, 2, 3 in the terminal, so \"your 2\" is ambiguous. First hit: ${hit#bare-list: }" >&2
exit 2
