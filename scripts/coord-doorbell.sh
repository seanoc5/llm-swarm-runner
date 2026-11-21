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
# stream-json transcript must contain EXACTLY ONE SendMessage tool_use, to the right
# session, text equal to the expected message, AND the tool_result carrying that call's tool_use_id with
# success:true. Anything else (courier crash or timeout, no live coordinator
# of that name, paraphrased text, success:false) exits 1. A courier timeout is
# not itself a failure: the partial transcript is still read, so a courier that
# delivered and then hung counts as delivered (no duplicate fallback paste).
# Exits 1 with the reason on
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

# #660: .swarm/.env defaults are no longer left in the tmux server env, so
# reload them for this project. Caller-set variables still win.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

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
# The coordinator's tmux session (llm-start.sh's SESSION_NAME). Used only to
# find the coordinator's CURRENT harness name when the pinned one is not
# listed, and only via its "coordinator" window (workers are other windows of
# the same tmux session) (issue #1040: a resumed/restarted/renamed session no longer answers
# to swarm-<base>-<hash>, so SendMessage said "No agent named ... reachable").
TMUX_SESSION="llm-$(basename "$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P || echo "$PROJECT_DIR")")"
[ -r "$PROMPT_FILE" ] || fail "prompt file unreadable: $PROMPT_FILE"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || fail "claude binary not found: $CLAUDE_BIN"

# Command substitution strips trailing newlines on both sides of the compare.
EXPECTED="[swarm wake doorbell, no reply needed] $(cat "$PROMPT_FILE")"

COURIER_PROMPT="First call ListAgents once. The recipient is the listed agent named exactly \"$TARGET\". If no agent has that name, it is the single listed interactive agent whose tmux target is in window \"$TMUX_SESSION:coordinator\" (workers share that tmux session in other windows; never pick them) (use that agent's listed name); if there is not exactly one such agent, call nothing further and reply none. Then call SendMessage exactly once, with to set to the recipient's name and message set to exactly the text between the two marker lines below (no edits, no additions, markers excluded). Then reply with the single word done. Do not call any other tool.
<<<WAKE_BEGIN>>>
$EXPECTED
<<<WAKE_END>>>"

# A neutral cwd: the courier needs no project CLAUDE.md, and its
# no-persistence session must not land in the project's session list.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT="$WORK/courier.jsonl"
CLEAN="$WORK/clean.jsonl"
# Prompt on stdin: --tools is variadic and would swallow a positional prompt.
( cd "$WORK" && printf '%s' "$COURIER_PROMPT" | timeout "$TIMEOUT_SECS" "$CLAUDE_BIN" -p \
    --model "$MODEL" --dangerously-skip-permissions --no-session-persistence \
    --output-format stream-json --verbose --tools SendMessage ListAgents ) > "$OUT" 2> "$WORK/courier.err"
rc=$?
# rc != 0 (including a 124 timeout) may still carry a usable transcript: a
# courier that delivered and then hung must not get a duplicate fallback paste
# in the operator's draft. The checks below decide; a timeout only changes the
# failure wording.
# A kill mid-write can leave a truncated last line, which would make `jq -s`
# reject the whole file; keep only the lines that parse.
jq -cR 'fromjson? // empty' "$OUT" > "$CLEAN" 2>/dev/null
TIMED_OUT=""
[ "$rc" = 124 ] && TIMED_OUT="courier timed out after ${TIMEOUT_SECS}s; "

# Names the coordinator may be reached under: the pinned TARGET, plus (issue
# #1040) the name of the one ListAgents row in this project's tmux "coordinator" window when
# TARGET is not listed. Decided here from the transcript, never from the
# courier's prose, so a wrong-swarm recipient still fails.
LIST_TEXT="$(jq -rs '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "ListAgents") | .id ] as $ids
    | [ .[] | select(.type == "user") | .message.content[]?
        | select(.type == "tool_result" and (.tool_use_id as $i | $ids | index($i)))
        | .content | if type == "array" then map(.text // "") | join("") else (. // "") end ]
    | join("\n")' "$CLEAN" 2>/dev/null)"
ALLOWED="$TARGET"
if ! grep -qE "(^|[^A-Za-z0-9._-])$(printf '%s' "$TARGET" | sed 's/[.[\*^$]/\\&/g')([^A-Za-z0-9._-]|$)" <<<"$LIST_TEXT"; then
    ROWS="$(printf '%s\n' "$LIST_TEXT" | grep -E "(^|[^A-Za-z0-9._-])$(printf '%s' "$TMUX_SESSION" | sed 's/[.[\*^$]/\\&/g'):coordinator([^A-Za-z0-9_-]|$)" | grep -iE '(^|[^A-Za-z-])interactive')"
    if [ -n "$ROWS" ] && [ "$(printf '%s\n' "$ROWS" | wc -l)" = 1 ]; then
        ALLOWED="$(printf '%s' "$ROWS" | sed -E 's/^[[:space:]*•·-]+//' | awk '{print $1}')"
    fi
fi

# Exactly one SendMessage call in the whole transcript, to the expected
# recipient with the expected text. Zero calls, two calls (even if one is
# right), or a call to anyone else is a failure: the caller falls back to the
# paste. Prints that call's tool_use id on success.
SEND_ID="$(jq -rs --arg to "$ALLOWED" --arg exp "$EXPECTED" '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "SendMessage") ]
    | if length == 1
         and (.[0].input.to == $to)
         and (((.[0].input.message // "") | rtrimstr("\n")) == $exp)
         and ((.[0].id // "") != "")
      then .[0].id else "" end' "$CLEAN" 2>/dev/null)"
[ -n "$SEND_ID" ] || fail "${TIMED_OUT}courier did not make exactly one SendMessage call with the expected message to $TARGET (courier rc=$rc: $(head -c 200 "$WORK/courier.err" | tr '\n' ' '))"

# The tool_result that answers THAT call (matching tool_use_id), not the first
# result in the transcript.
RESULT="$(jq -rs --arg id "$SEND_ID" '
    [ .[] | select(.type == "user") | .message.content[]?
      | select(.type == "tool_result" and .tool_use_id == $id) | .content
      | if type == "array" then map(.text // "") | join("") else . end ]
    | if length == 1 then .[0] else "" end' "$CLEAN" 2>/dev/null)"
if [ "$(printf '%s' "$RESULT" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
    fail "${TIMED_OUT}SendMessage reported not delivered: $(printf '%s' "$RESULT" | jq -r '(.message // .) | .[0:160]' 2>/dev/null)"
fi

log_event coord.wake.doorbell "target=$ALLOWED via=sendmessage${TIMED_OUT:+ courier_timeout=1}"
exit 0
