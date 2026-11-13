#!/usr/bin/env bash
# coord-doorbell.sh — wake a claude coordinator with a harness-native
# cross-session SendMessage instead of pasting into its composer
# (issue #421, ADR 0005 Option 1).
#
# Usage: coord-doorbell.sh <project-dir> <prompt-file>
#
# The watcher is a bash script, not an agent, so it cannot call SendMessage
# itself. This is the minimal headless courier (ADR Option 3 shape): one
# `claude -p` call, Haiku, SendMessage as its only tool, that forwards the
# wake text to the coordinator session named by coord_session_name. The
# message reaches the coordinator framed by the harness as a cross-session
# message; nothing touches its composer, so an operator's unsubmitted draft
# is never pasted into or submitted (live trial: ADR 0005 "Residual spike
# results").
#
# Success is decided by this script, never by the courier's own prose: the
# stream-json transcript must contain a SendMessage tool_use to the right
# session whose text equals the expected message, AND a tool_result with
# success:true. Anything else (courier crash or timeout, no live coordinator
# of that name, paraphrased text, success:false) exits 1 with the reason on
# stderr and a coord.wake.doorbell_failed event, so llm-start.sh can fall
# back to the guarded send-keys paste. A dropped doorbell is only latency:
# the file bus (inbox/outbox/done) is untouched.
#
# Exit: 0 delivered, 1 not delivered (caller falls back).
#
# Env:
#   COORD_DOORBELL_MODEL          courier model (default: haiku)
#   COORD_DOORBELL_TIMEOUT_SECS   hard cap on the courier call (default: 30; keep well under the watcher's 60s COORD_WAKE_LOCK_TIMEOUT_SECS, since each wake holds that lock)
#   COORD_DOORBELL_CLAUDE         claude binary (default: claude; tests stub it)
#   EVENTS_LOG                    event log path (llm-start.sh sets it)
#
# Permission mode: a receiver in a different permission mode holds
# cross-session messages for approval. The coordinator runs
# --dangerously-skip-permissions, so the courier does too; keep them equal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_coord-name.sh
. "$SCRIPT_DIR/_coord-name.sh"

PROJECT_DIR="${1:?usage: coord-doorbell.sh <project-dir> <prompt-file>}"
PROMPT_FILE="${2:?usage: coord-doorbell.sh <project-dir> <prompt-file>}"

CLAUDE_BIN="${COORD_DOORBELL_CLAUDE:-claude}"
MODEL="${COORD_DOORBELL_MODEL:-haiku}"
TIMEOUT_SECS="${COORD_DOORBELL_TIMEOUT_SECS:-30}"
EVENTS_LOG="${EVENTS_LOG:-$PROJECT_DIR/.swarm/events.log}"

log_event() {
    local cat="$1"; shift
    printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

fail() {
    echo "coord-doorbell: $*" >&2
    log_event coord.wake.doorbell_failed "target=$TARGET reason=$(printf '%s' "$*" | tr '\n' ' ' | cut -c1-160)"
    exit 1
}

TARGET="$(coord_session_name "$PROJECT_DIR")"
[ -r "$PROMPT_FILE" ] || fail "prompt file unreadable: $PROMPT_FILE"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || fail "claude binary not found: $CLAUDE_BIN"

# Command substitution strips trailing newlines on both sides of the compare.
EXPECTED="[swarm wake doorbell, no reply needed] $(cat "$PROMPT_FILE")"

COURIER_PROMPT="Call SendMessage exactly once, with to=\"$TARGET\" and message set to exactly the text between the two marker lines below (no edits, no additions, markers excluded). Then reply with the single word done. Do not call any other tool.
<<<WAKE_BEGIN>>>
$EXPECTED
<<<WAKE_END>>>"

# A neutral cwd: the courier needs no project CLAUDE.md, and its
# no-persistence session must not land in the project's session list.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT="$WORK/courier.jsonl"
# Prompt on stdin: --tools is variadic and would swallow a positional prompt.
( cd "$WORK" && printf '%s' "$COURIER_PROMPT" | timeout "$TIMEOUT_SECS" "$CLAUDE_BIN" -p \
    --model "$MODEL" --dangerously-skip-permissions --no-session-persistence \
    --output-format stream-json --verbose --tools SendMessage ) > "$OUT" 2> "$WORK/courier.err"
rc=$?
[ "$rc" = 124 ] && fail "courier timed out after ${TIMEOUT_SECS}s"
# rc != 0 may still carry a usable transcript; the checks below decide.

SENT="$(jq -rs --arg to "$TARGET" --arg exp "$EXPECTED" '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "SendMessage"
               and .input.to == $to and ((.input.message // "") | rtrimstr("\n")) == $exp) ]
    | if length > 0 then "ok" else "" end' "$OUT" 2>/dev/null)"
[ "$SENT" = "ok" ] || fail "courier did not send the expected message to $TARGET (courier rc=$rc: $(head -c 200 "$WORK/courier.err" | tr '\n' ' '))"

RESULT="$(jq -rs '
    [ .[] | select(.type == "user") | .message.content[]?
      | select(.type == "tool_result") | .content
      | if type == "array" then map(.text // "") | join("") else . end ] | first // ""' "$OUT" 2>/dev/null)"
if [ "$(printf '%s' "$RESULT" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
    fail "SendMessage reported not delivered: $(printf '%s' "$RESULT" | jq -r '(.message // .) | .[0:160]' 2>/dev/null)"
fi

log_event coord.wake.doorbell "target=$TARGET via=sendmessage"
exit 0
