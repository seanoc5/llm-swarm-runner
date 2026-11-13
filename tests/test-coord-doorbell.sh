#!/usr/bin/env bash
#
# test-coord-doorbell.sh — scripts/coord-doorbell.sh and _coord-name.sh
# (issue #421, ADR 0005 Option 1).
#
# A stub `claude` stands in for the courier and prints the stream-json shapes
# observed live (ADR 0005 "Residual spike results"): an assistant SendMessage
# tool_use, then a user tool_result carrying {"success":...}. Verifies the
# script decides success from that transcript, not from the courier's prose.
set -uo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; FAILS=$((FAILS + 1)); }
FAILS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOORBELL="$SCRIPT_DIR/../scripts/coord-doorbell.sh"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

T="$(mktemp -d -t coord-doorbell-XXXXXX)"
trap 'rm -rf "$T"' EXIT
PROJ="$T/My Proj.x"; mkdir -p "$PROJ/.swarm"
EV="$PROJ/.swarm/events.log"
PROMPT="$T/prompt.txt"
printf 'Outcome landed for iss-9.\nSweep and report.\n' > "$PROMPT"
EXPECTED_MSG="[swarm wake doorbell, no reply needed] $(cat "$PROMPT")"

check() { # desc expected actual
    if [ "$2" = "$3" ]; then green "$1"; else red "$1 (expected [$2] got [$3])"; fi
}

# --- _coord-name.sh -----------------------------------------------------
# shellcheck source=../scripts/_coord-name.sh
. "$SCRIPT_DIR/../scripts/_coord-name.sh"
NAME="$(coord_session_name "$PROJ")"
check "session name: swarm-<basename>-<8 hex>, unsafe chars replaced" 1 "$(printf %s "$NAME" | grep -Ec "^swarm-My-Proj\.x-[0-9a-f]{8}\$")"
check "session name: trailing slash ignored" "$NAME" "$(coord_session_name "$PROJ/")"
# two projects, same folder name, different parents (review A of PR #935)
mkdir -p "$T/a/app" "$T/b/app"
NA="$(coord_session_name "$T/a/app")"; NB="$(coord_session_name "$T/b/app")"
check "same-basename projects get different session names" 1 "$([ "$NA" != "$NB" ] && echo 1 || echo 0)"
check "same-basename: both keep the readable basename" 2 "$(printf "%s\n%s\n" "$NA" "$NB" | grep -c "^swarm-app-")"
check "session name: relative path and symlink resolve to one name" "$NA" "$(cd "$T/a" && ln -sfn app applink && coord_session_name applink)"

# Transcript stubs. Each call emits assistant tool_use records and user
# tool_result records keyed by tool_use_id, as the harness does.
#   emit_use    <id> <to> <msg>      assistant SendMessage tool_use
#   emit_result <id> <result-json>   user tool_result answering <id>
# make_stub <name> <body...> writes a stub `claude` that runs the body lines.
make_stub() {
    local name="$1"; shift
    {
        printf '#!/usr/bin/env bash\ncat >/dev/null   # courier prompt arrives on stdin\n'
        cat <<'FN'
emit_use() { jq -cn --arg id "$1" --arg to "$2" --arg m "$3" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:"SendMessage",input:{to:$to,message:$m}}]}}'; }
emit_result() { jq -cn --arg id "$1" --arg r "$2" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:$r}]}]}}'; }
FN
        printf '%s\n' "$@"
    } > "$T/$name"
    chmod +x "$T/$name"
}
run() { # stubname -> exit code; resets the event log
    : > "$EV"
    COORD_DOORBELL_CLAUDE="$T/$1" EVENTS_LOG="$EV" COORD_DOORBELL_TIMEOUT_SECS="${2:-20}" \
        "$DOORBELL" "$PROJ" "$PROMPT" 2>/dev/null
    echo $?
}

TARGET="$NAME"
OKRES='{"success":true,"message":"queued"}'
q() { printf '%q' "$1"; }

make_stub ok "emit_use tu1 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu1 '$OKRES'"
check "delivered: exit 0" 0 "$(run ok)"
check "delivered: coord.wake.doorbell logged" 1 "$(grep -c "coord.wake.doorbell target=$TARGET" "$EV")"

make_stub gone "emit_use tu1 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu1 '{\"success\":false,\"message\":\"No agent named x is reachable.\"}'"
check "gone target (success:false): exit 1" 1 "$(run gone)"
check "gone target: coord.wake.doorbell_failed logged" 1 "$(grep -c 'coord.wake.doorbell_failed' "$EV")"

make_stub paraphrase "emit_use tu1 $(q "$TARGET") 'Something changed, please look'" "emit_result tu1 '$OKRES'"
check "courier paraphrased the text: exit 1 (not trusted)" 1 "$(run paraphrase)"

make_stub wrongto "emit_use tu1 swarm-other $(q "$EXPECTED_MSG")" "emit_result tu1 '$OKRES'"
check "sent to the wrong session: exit 1" 1 "$(run wrongto)"

# The collision case: the other project's coordinator has the same basename.
make_stub samebase "emit_use tu1 $(q "$NB") $(q "$EXPECTED_MSG")" "emit_result tu1 '$OKRES'"
check "sent to a same-basename project's coordinator: exit 1" 1 "$(run samebase)"
check "same-basename: failure logged, no delivery logged" "1 0" "$(printf '%s %s' "$(grep -c doorbell_failed "$EV")" "$(grep -c 'coord.wake.doorbell target' "$EV")")"

# B: exactly one SendMessage call, and the result must belong to it.
make_stub zero "echo 'no tools today'"
check "zero SendMessage calls: exit 1" 1 "$(run zero)"
make_stub zero_result "emit_result tu1 '$OKRES'"
check "zero calls but a success result present: exit 1" 1 "$(run zero_result)"

make_stub two_same "emit_use tu1 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu1 '$OKRES'" "emit_use tu2 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu2 '$OKRES'"
check "two SendMessage calls (both correct): exit 1" 1 "$(run two_same)"
make_stub two_one_bad "emit_use tu1 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu1 '$OKRES'" "emit_use tu2 swarm-other $(q "$EXPECTED_MSG")" "emit_result tu2 '$OKRES'"
check "two calls, one to the wrong session: exit 1" 1 "$(run two_one_bad)"
check "two calls: failure logged" 1 "$(grep -c 'doorbell_failed' "$EV")"

make_stub other_result "emit_use tu1 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu9 '$OKRES'"
check "only result belongs to a different call id: exit 1" 1 "$(run other_result)"
make_stub fail_then_other "emit_use tu1 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu9 '$OKRES'" "emit_result tu1 '{\"success\":false}'"
check "first result is another call's success, ours failed: exit 1" 1 "$(run fail_then_other)"
make_stub late_ours "emit_use tu1 $(q "$TARGET") $(q "$EXPECTED_MSG")" "emit_result tu9 '{\"success\":false}'" "emit_result tu1 '$OKRES'"
check "first result is another call's failure, ours succeeded: exit 0" 0 "$(run late_ours)"

printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 30\n' > "$T/slow"; chmod +x "$T/slow"
check "courier timeout: exit 1" 1 "$(run slow 2)"
check "courier timeout: reason says timed out" 1 "$(grep -c 'timed out' "$EV")"

: > "$EV"
check "missing claude binary: exit 1" 1 "$(COORD_DOORBELL_CLAUDE=/nonexistent/claude EVENTS_LOG="$EV" "$DOORBELL" "$PROJ" "$PROMPT" >/dev/null 2>&1; echo $?)"

[ "$FAILS" = 0 ] && { green "All coord-doorbell tests passed"; exit 0; }
echo "$FAILS check(s) failed" >&2; exit 1
