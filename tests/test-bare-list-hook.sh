#!/usr/bin/env bash
# test-bare-list-hook.sh — issue #800: the bare-list lint rule and the user-level
# Stop hook scripts/hooks/no-bare-numbered-lists.sh. No tmux, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/lint-coordinator-reply.sh"
HOOK="$ROOT/scripts/hooks/no-bare-numbered-lists.sh"
T="$(mktemp -d -t bare-list-XXXXXX)"; trap 'rm -rf "$T"' EXIT

rules() { printf '%b' "$1" | "$LINT" --only bare-list | cut -d: -f1 | sort -u | paste -sd, -; }
check "'1.' list: bare-list" "bare-list" "$(rules 'Why:\n1. a\n2. b\n')"
check "'1)' list: bare-list" "bare-list" "$(rules '1) a\n')"
check "indented '  3. x': bare-list" "bare-list" "$(rules 'x\n  3. y\n')"
check "lettered A1/B1 list: clean" "" "$(rules '- A1 one\n- B1 two\n')"
check "numbered line inside a fence: clean" "" "$(rules 'ok\n```\n1. in fence\n```\n')"
check "numbered line inside a ~~~ fence: clean" "" "$(rules 'ok\n~~~\n1. in fence\n~~~\n')"
check "number mid-sentence / decimal: clean" "" "$(rules 'PR 3. done\nv1.2 is out\n3.5 ms\n')"
check "after a closed fence a bare list is flagged again" "bare-list" "$(rules '```\nx\n```\n1. a\n')"
check "--only hides other rules" "" "$(printf 'see earlier\n' | "$LINT" --only bare-list | paste -sd, -)"
check "without --only other rules still fire" "backref" "$(printf 'see earlier\n' | "$LINT" | cut -d: -f1 | paste -sd, -)"

export BARE_LIST_STATE_DIR="$T/state"
hook() {   # <json> [args] -> "<exit>|<stdout+stderr>"
    local out ec
    out="$(printf '%s' "$1" | "$HOOK" "${@:2}" 2>&1)"; ec=$?
    printf '%s|%s' "$ec" "$out"
}
j() { jq -cn --arg m "$1" --arg s "${2:-s1}" '{last_assistant_message: $m, session_id: $s}'; }
remind() { hook "$(jq -cn --arg s "${1:-s1}" '{session_id: $s, prompt: "hi"}')" --remind; }
out="$(hook "$(j $'Why:\n1. a\n2. b')")"
check "Stop: a bare list never blocks (exit 0, nothing printed, no resend)" "0|" "$out"
check "Stop: a bare list saves a reminder for the session" "yes" "$([ -s "$T/state/s1" ] && echo yes || echo no)"
out="$(remind s1)"
check "--remind: prints the reminder, exit 0" "yes" "$([[ "$out" == "0|Reminder from the bare-list hook"*"Don't resend"* ]] && echo yes || echo no)"
check "--remind: reminder is delivered once" "0|" "$(remind s1)"
check "--remind: nothing pending prints nothing" "0|" "$(remind other)"
hook "$(j $'1. a' s2)" >/dev/null
check "reminders are per session" "0|" "$(remind s1)"
check "Stop: a lettered reply saves nothing" "no" "$(hook "$(j $'- A1 a\n- A2 b' s3)" >/dev/null; [ -e "$T/state/s3" ] && echo yes || echo no)"
check "NO_BARE_LISTS_HOOK=0 opts out" "no" "$(printf '%s' "$(j $'1. a' s4)" | NO_BARE_LISTS_HOOK=0 "$HOOK" >/dev/null 2>&1; [ -e "$T/state/s4" ] && echo yes || echo no)"
pending() { [ -s "$T/state/$1" ] && echo yes || echo no; rm -f "$T/state/$1"; }
# transcript fallback: every assistant text record since the last user prompt is judged
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"1. old"}]}}' \
    '{"type":"user","message":{"content":"hi"}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"- A1 fine"}]}}' > "$T/t.jsonl"
hook "$(jq -cn --arg p "$T/t.jsonl" '{transcript_path:$p, session_id:"t1"}')" >/dev/null
check "transcript fallback ignores assistant text from before the last user prompt" "no" "$(pending t1)"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"1. bad"}]}}' > "$T/t2.jsonl"
hook "$(jq -cn --arg p "$T/t2.jsonl" '{transcript_path:$p, session_id:"t2"}')" >/dev/null
check "transcript fallback catches a bare list" "yes" "$(pending t2)"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"1. bad before the tool call"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"- A1 fine after"}]}}' > "$T/t3.jsonl"
hook "$(jq -cn --arg p "$T/t3.jsonl" '{transcript_path:$p, session_id:"t3"}')" >/dev/null
check "transcript fallback catches a bare list before a tool call (text, tool, text)" "yes" "$(pending t3)"
ln -s "$HOOK" "$T/link.sh"; printf '%s' "$(j $'1. a' t4)" | "$T/link.sh" >/dev/null 2>&1
check "hook through a symlink still finds the lint" "yes" "$(pending t4)"
check "garbage stdin: allowed" "0" "$(printf 'not json' | "$HOOK" >/dev/null 2>&1; echo $?)"
check "garbage stdin with --remind: allowed" "0" "$(printf 'not json' | "$HOOK" --remind >/dev/null 2>&1; echo $?)"
check "session id with path characters stays inside the state dir" "yes" "$(hook "$(j $'1. a' '../../x')" >/dev/null; [ -s "$T/state/x" ] && echo yes || echo no)"
echo "all passed"
