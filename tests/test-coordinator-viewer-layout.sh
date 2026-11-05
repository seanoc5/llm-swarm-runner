#!/usr/bin/env bash
#
# test-coordinator-viewer-layout.sh — issue #785: COORD_VIEWER layout. With the
# read-only conversation viewer in the coordinator window, (1) the Claude
# session stays pane 0, (2) a doorbell (llm-start.sh's reprompt_inject) reaches
# the session and never the viewer, (3) the watcher's busy/state checks read the
# session pane, (4) a viewer crash or a hand-closed pane doesn't touch the
# session, and (5) a viewer renumbered to pane 0 is never typed into.
# Real throwaway tmux server; functions are extracted from the shipped scripts.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLM_START="$ROOT/llm-start.sh"; WATCH="$ROOT/scripts/coordinator-watch.sh"
command -v tmux >/dev/null 2>&1 || red "tmux not found"

TEST_DIR="$(mktemp -d -t coord-viewer-XXXXXX)"
SOCK="viewer-test-$$"; SESSION_NAME="viewer-test"
trap 'command tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
tmux() { command tmux -L "$SOCK" "$@"; }
. "$ROOT/scripts/_coord-layout.sh"

extract_fn() { sed -n "/^${2}() {/,/^}/p" "$1"; }
for spec in "$LLM_START:log_event" "$LLM_START:reprompt_last_pane_line" "$LLM_START:reprompt_confirm_submitted" \
            "$LLM_START:reprompt_composer_dirty" "$LLM_START:reprompt_retry_safe" "$LLM_START:reprompt_inject" \
            "$WATCH:coordinator_pane_state" "$WATCH:coordinator_pane_busy"; do
    body="$(extract_fn "${spec%%:*}" "${spec##*:}")"
    [ -n "$body" ] || red "could not extract ${spec##*:} from ${spec%%:*}"
    eval "$body"
done
EVENTS_LOG="$TEST_DIR/events.log"; : > "$EVENTS_LOG"
COORD_BUSY_PATTERN='\(esc to interrupt\)|Press Ctrl-C again to .xit|· ↓ [0-9.,]+k? tokens|Press up to edit queued messages|Compacting conversation'
AUTO_COMPACT_BUSY_PATTERN="$COORD_BUSY_PATTERN"
COMPACT_SUBMIT_SETTLE_SECS=0.3
REPROMPT_CHROME_PATTERN='^※ recap:|Resume this session with|^[0-9]+\.[[:space:]]*Resume from'
eval "$(grep '^REPROMPT_FOOTER_PATTERN=' "$LLM_START")"

check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }
pane_has() { tmux capture-pane -t "$1" -p 2>/dev/null | grep -qF -- "$2" && echo yes || echo no; }
eventually() { local i; for i in $(seq 40); do [ "$(eval "$2")" = "$1" ] && return 0; sleep 0.1; done; return 1; }

# Fake session: reads lines into $RECV; prints SESSION_BANNER (optionally the
# busy marker) so busy detection has something to read.
RECV="$TEST_DIR/recv"; : > "$RECV"
cat > "$TEST_DIR/fake-repl.sh" <<FAKE
#!/usr/bin/env bash
echo "SESSION_PANE \${FAKE_BUSY:+(esc to interrupt)}"
printf '\n> '
while IFS= read -r l; do printf '%s\n' "\$l" >> "$RECV"; done
FAKE
PROJECT="$TEST_DIR/proj"; mkdir -p "$PROJECT/.swarm"
tmux -f /dev/null new-session -d -s "$SESSION_NAME" -n coordinator -x 120 -y 40 -c "$PROJECT"
tmux set-window-option -t "$SESSION_NAME:coordinator" pane-base-index 0
tmux send-keys -t "$SESSION_NAME:coordinator.0" "exec -a claude bash $TEST_DIR/fake-repl.sh" Enter
eventually yes 'pane_has "$SESSION_NAME:coordinator.0" SESSION_PANE' || red "fake session did not start"

# --- layout on --------------------------------------------------------------
coord_layout_on "$SESSION_NAME" "$PROJECT" "$ROOT" 75
n="$(tmux list-panes -t "$SESSION_NAME:coordinator" | wc -l)"
check "layout on: window has session + viewer" 2 "$n"
check "pane 0 is the session, not the viewer" no "$(coord_pane_is_viewer "$SESSION_NAME:coordinator.0" && echo yes || echo no)"
check "pane 1 is the viewer" yes "$(coord_pane_is_viewer "$SESSION_NAME:coordinator.1" && echo yes || echo no)"
check "pane 0 is above and smaller (typing pane)" yes \
    "$(tmux list-panes -t "$SESSION_NAME:coordinator" -F '#{pane_index} #{pane_height}' | awk 'NR==1{a=$2} NR==2{b=$2} END{print (a<b)?"yes":"no"}')"
coord_layout_on "$SESSION_NAME" "$PROJECT" "$ROOT" 75
check "layout on is idempotent" 2 "$(tmux list-panes -t "$SESSION_NAME:coordinator" | wc -l)"
check "state check sees the session as a cli" cli "$(coordinator_pane_state)"

# --- doorbell reaches the session, never the viewer --------------------------
printf 'DOORBELL-785 triage inbox\n' > "$TEST_DIR/bell"
rc=0; reprompt_inject "$SESSION_NAME:coordinator.0" "$TEST_DIR/bell" >/dev/null 2>&1 || rc=$?
check "doorbell text arrived at the session" yes "$(grep -qF DOORBELL-785 "$RECV" && echo yes || echo no)"
check "doorbell text is absent from the viewer pane" no "$(pane_has "$SESSION_NAME:coordinator.1" DOORBELL-785)"

# --- busy detection reads the session pane ------------------------------------
check "idle session, idle viewer: not busy" no "$(coordinator_pane_busy && echo yes || echo no)"
tmux respawn-pane -k -t "$SESSION_NAME:coordinator.1" "echo '(esc to interrupt)'; sleep 60"
tmux select-pane -t "$SESSION_NAME:coordinator.1" -T "$COORD_VIEWER_TITLE"
eventually yes 'pane_has "$SESSION_NAME:coordinator.1" "esc to interrupt"' || red "viewer marker not shown"
check "busy marker only in the viewer: still not busy" no "$(coordinator_pane_busy && echo yes || echo no)"
tmux respawn-pane -k -t "$SESSION_NAME:coordinator.0" "FAKE_BUSY=1 exec -a claude bash $TEST_DIR/fake-repl.sh"
eventually yes 'coordinator_pane_busy && echo yes || echo no' || red "busy not detected from the session pane"
green "busy marker in the session pane: busy"
tmux respawn-pane -k -t "$SESSION_NAME:coordinator.0" "exec -a claude bash $TEST_DIR/fake-repl.sh"

# --- a crashed/closed viewer leaves the session alone -------------------------
tmux kill-pane -t "$SESSION_NAME:coordinator.1"
check "viewer closed by hand: session pane still alive" 1 "$(tmux list-panes -t "$SESSION_NAME:coordinator" | wc -l)"
check "session still pane 0 and a cli" cli "$(coordinator_pane_state)"
coord_layout_on "$SESSION_NAME" "$PROJECT" "$ROOT" 75
coord_layout_off "$SESSION_NAME"
check "layout off closes only the viewer" 1 "$(tmux list-panes -t "$SESSION_NAME:coordinator" | wc -l)"

# --- viewer renumbered to pane 0 (session pane closed) is never typed into ------
coord_layout_on "$SESSION_NAME" "$PROJECT" "$ROOT" 75
tmux kill-pane -t "$SESSION_NAME:coordinator.0"
check "viewer is now pane 0" yes "$(coord_pane_is_viewer "$SESSION_NAME:coordinator.0" && echo yes || echo no)"
check "watcher treats a viewer-only window as absent" absent "$(coordinator_pane_state)"
check "watcher never calls a viewer busy" no "$(coordinator_pane_busy && echo yes || echo no)"
printf 'DOORBELL-NOPE\n' > "$TEST_DIR/bell2"
rc=0; reprompt_inject "$SESSION_NAME:coordinator.0" "$TEST_DIR/bell2" >/dev/null 2>&1 || rc=$?
check "doorbell to a viewer is deferred (rc 2)" 2 "$rc"
check "nothing pasted into the viewer" no "$(pane_has "$SESSION_NAME:coordinator.0" DOORBELL-NOPE)"

echo "all viewer-layout checks passed"
