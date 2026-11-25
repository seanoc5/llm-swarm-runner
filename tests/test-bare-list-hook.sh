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

hook() {   # <json> -> "<exit>|<stderr>"
    local err ec
    err="$(printf '%s' "$1" | "$HOOK" 2>&1 >/dev/null)"; ec=$?
    printf '%s|%s' "$ec" "$err"
}
j() { jq -cn --arg m "$1" --argjson a "${2:-false}" '{last_assistant_message: $m, stop_hook_active: $a}'; }
out="$(hook "$(j $'Why:\n1. a\n2. b')")"
check "hook blocks a bare list with exit 2" "2" "${out%%|*}"
check "hook message asks for letter prefixes" "yes" "$([[ "$out" == *"Relabel every list with a letter prefix (A1, B1...)"* ]] && echo yes || echo no)"
check "hook allows a lettered reply" "0" "$(hook "$(j $'- A1 a\n- A2 b')" | cut -d'|' -f1)"
check "hook allows a continuation (stop_hook_active) so it cannot loop" "0" "$(hook "$(j $'1. a' true)" | cut -d'|' -f1)"
NO_BARE_LISTS_HOOK=0 true
check "NO_BARE_LISTS_HOOK=0 opts out" "0" "$(printf '%s' "$(j $'1. a')" | NO_BARE_LISTS_HOOK=0 "$HOOK" >/dev/null 2>&1; echo $?)"
# transcript fallback: every assistant text record since the last user prompt is judged
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"1. old"}]}}' \
    '{"type":"user","message":{"content":"hi"}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"- A1 fine"}]}}' > "$T/t.jsonl"
check "transcript fallback ignores assistant text from before the last user prompt" "0" "$(hook "$(jq -cn --arg p "$T/t.jsonl" '{transcript_path:$p}')" | cut -d'|' -f1)"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"1. bad"}]}}' > "$T/t2.jsonl"
check "transcript fallback blocks a bare list" "2" "$(hook "$(jq -cn --arg p "$T/t2.jsonl" '{transcript_path:$p}')" | cut -d'|' -f1)"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"1. bad before the tool call"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"- A1 fine after"}]}}' > "$T/t3.jsonl"
check "transcript fallback blocks a bare list before a tool call (text, tool, text)" "2" "$(hook "$(jq -cn --arg p "$T/t3.jsonl" '{transcript_path:$p}')" | cut -d'|' -f1)"
check "hook through a symlink still finds the lint" "2" "$(ln -s "$HOOK" "$T/link.sh"; printf '%s' "$(j $'1. a')" | "$T/link.sh" >/dev/null 2>&1; echo $?)"
check "garbage stdin: allowed" "0" "$(printf 'not json' | "$HOOK" >/dev/null 2>&1; echo $?)"
echo "all passed"
