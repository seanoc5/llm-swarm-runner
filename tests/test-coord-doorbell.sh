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
check "session name: swarm-<basename>, unsafe chars replaced" "swarm-My-Proj.x" "$(coord_session_name "$PROJ")"
check "session name: trailing slash ignored" "swarm-corpusminder" "$(coord_session_name /opt/work/corpusminder/)"

# make_stub <name> <to> <message-sent> <result-json>: emits the transcript.
make_stub() {
    local name="$1" to="$2" msg="$3" result="$4"
    cat > "$T/$name" <<STUB
#!/usr/bin/env bash
cat >/dev/null   # the courier prompt arrives on stdin
jq -cn --arg to '$to' --arg m '$msg' '{type:"assistant",message:{content:[{type:"tool_use",name:"SendMessage",input:{to:\$to,message:\$m}}]}}'
jq -cn --arg r '$result' '{type:"user",message:{content:[{type:"tool_result",content:[{type:"text",text:\$r}]}]}}'
STUB
    chmod +x "$T/$name"
}
run() { # stubname -> exit code; resets the event log
    : > "$EV"
    COORD_DOORBELL_CLAUDE="$T/$1" EVENTS_LOG="$EV" COORD_DOORBELL_TIMEOUT_SECS="${2:-20}" \
        "$DOORBELL" "$PROJ" "$PROMPT" 2>/dev/null
    echo $?
}

make_stub ok swarm-My-Proj.x "$EXPECTED_MSG" '{"success":true,"message":"queued"}'
check "delivered: exit 0" 0 "$(run ok)"
check "delivered: coord.wake.doorbell logged" 1 "$(grep -c 'coord.wake.doorbell target=swarm-My-Proj.x' "$EV")"

make_stub gone swarm-My-Proj.x "$EXPECTED_MSG" '{"success":false,"message":"No agent named x is reachable."}'
check "gone target (success:false): exit 1" 1 "$(run gone)"
check "gone target: coord.wake.doorbell_failed logged" 1 "$(grep -c 'coord.wake.doorbell_failed' "$EV")"

make_stub paraphrase swarm-My-Proj.x "Something changed, please look" '{"success":true}'
check "courier paraphrased the text: exit 1 (not trusted)" 1 "$(run paraphrase)"

make_stub wrongto swarm-other "$EXPECTED_MSG" '{"success":true}'
check "sent to the wrong session: exit 1" 1 "$(run wrongto)"

printf '#!/usr/bin/env bash\ncat >/dev/null\necho "no tools today"\n' > "$T/notool"; chmod +x "$T/notool"
check "courier made no SendMessage call: exit 1" 1 "$(run notool)"

printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 30\n' > "$T/slow"; chmod +x "$T/slow"
check "courier timeout: exit 1" 1 "$(run slow 2)"
check "courier timeout: reason says timed out" 1 "$(grep -c 'timed out' "$EV")"

: > "$EV"
check "missing claude binary: exit 1" 1 "$(COORD_DOORBELL_CLAUDE=/nonexistent/claude EVENTS_LOG="$EV" "$DOORBELL" "$PROJ" "$PROMPT" >/dev/null 2>&1; echo $?)"

[ "$FAILS" = 0 ] && { green "All coord-doorbell tests passed"; exit 0; }
echo "$FAILS check(s) failed" >&2; exit 1
