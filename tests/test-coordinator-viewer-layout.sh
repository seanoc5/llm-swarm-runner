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
            "$WATCH:coordinator_pane_state" "$WATCH:coordinator_pane_busy" "$WATCH:coordinator_pane_busy_visible" \
            "$WATCH:compact_confirm_submitted" "$WATCH:compact_last_pane_line"; do
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
eval "$(grep -E '^COMPACT_(COMPOSER_CHROME|FOOTER)_PATTERN=' "$WATCH")"

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

# --- the viewer closes itself once it is the last pane (PR review focus) -------
# A separate session, so closing its only window cannot take the other checks down.
SC="viewer-selfclose"
tmux -f /dev/null new-session -d -s "$SC" -n coordinator -x 120 -y 40 -c "$PROJECT"
tmux send-keys -t "$SC:coordinator.0" "exec -a claude bash $TEST_DIR/fake-repl.sh" Enter
coord_layout_on "$SC" "$PROJECT" "$ROOT" 75
check "self-close: real viewer-loop is running beside the session" 2 "$(tmux list-panes -t "$SC:coordinator" | wc -l)"
tmux kill-pane -t "$SC:coordinator.0"
gone() { tmux has-session -t "$SC" 2>/dev/null && echo no || echo yes; }
for _ in $(seq 100); do [ "$(gone)" = yes ] && break; sleep 0.1; done
check "self-close: lone viewer closed its pane (its window and session are gone)" yes "$(gone)"
check "self-close: the other session was not touched" cli "$(coordinator_pane_state)"

# --- viewer renumbered to pane 0 (session pane closed) is never typed into ------
# A stand-in viewer (titled pane that just sleeps) so the real viewer's self-close
# above cannot kill the window while these checks run.
coord_layout_on "$SESSION_NAME" "$PROJECT" "$ROOT" 75
tmux respawn-pane -k -t "$SESSION_NAME:coordinator.1" "sleep 120"
tmux select-pane -t "$SESSION_NAME:coordinator.1" -T "$COORD_VIEWER_TITLE"
tmux kill-pane -t "$SESSION_NAME:coordinator.0"
check "viewer is now pane 0" yes "$(coord_pane_is_viewer "$SESSION_NAME:coordinator.0" && echo yes || echo no)"
check "watcher treats a viewer-only window as absent" absent "$(coordinator_pane_state)"
check "watcher never calls a viewer busy" no "$(coordinator_pane_busy && echo yes || echo no)"
printf 'DOORBELL-NOPE\n' > "$TEST_DIR/bell2"
rc=0; reprompt_inject "$SESSION_NAME:coordinator.0" "$TEST_DIR/bell2" >/dev/null 2>&1 || rc=$?
check "doorbell to a viewer is deferred (rc 2)" 2 "$rc"
check "nothing pasted into the viewer" no "$(pane_has "$SESSION_NAME:coordinator.0" DOORBELL-NOPE)"
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# --- small session pane: busy marker above the visible rows -----------------------
# A turn with a long todo list: the "esc to interrupt" line is ABOVE the rows the
# small pane shows. capture-pane -p alone (the pre-fix check) cannot see it.
SMALL="viewer-small"; SESSION_NAME="$SMALL"
export COORD_BUSY_STATE_FILE="$TEST_DIR/busy-state"
cat > "$TEST_DIR/todo-repl.sh" <<FAKE
#!/usr/bin/env bash
echo "✻ Working… (esc to interrupt)"
for i in \$(seq 1 15); do echo "  ☐ todo item \$i"; done
printf '> '
while IFS= read -r l; do printf '%s\n' "\$l" >> "$RECV"; done
FAKE
tmux -f /dev/null new-session -d -s "$SMALL" -n coordinator -x 80 -y 24 -c "$PROJECT"
tmux set-window-option -t "$SMALL:coordinator" pane-base-index 0
# Floor lowered on purpose: this reproduces the user-shrunk / pre-floor small pane.
COORD_VIEWER_MIN_SESSION_ROWS=1 coord_layout_on "$SMALL" "$PROJECT" "$ROOT" 75
tmux respawn-pane -k -t "$SMALL:coordinator.0" "exec -a claude bash $TEST_DIR/todo-repl.sh"
tmux respawn-pane -k -t "$SMALL:coordinator.1" "sleep 120"
tmux select-pane -t "$SMALL:coordinator.1" -T "$COORD_VIEWER_TITLE"
eventually yes 'pane_has "$SMALL:coordinator.0" "todo item 15"' || red "todo fake did not render"
h="$(tmux display-message -p -t "$SMALL:coordinator.0" -F '#{pane_height}')"
[ "$h" -le 8 ] || red "session pane should be small, got $h rows"
check "premise: marker is not on the visible rows ($h-row pane)" no "$(pane_has "$SMALL:coordinator.0" "esc to interrupt")"
check "premise: marker is in scrollback" yes \
    "$(tmux capture-pane -t "$SMALL:coordinator.0" -p -S -60 | grep -qF 'esc to interrupt' && echo yes || echo no)"
check "small pane, marker above visible rows: coordinator_pane_busy sees the turn" yes \
    "$(coordinator_pane_busy && echo yes || echo no)"
# Stale marker: the pane is now static. After the cap it must read idle, not busy forever.
COORD_BUSY_SCROLLBACK_MAX_SECS=2
sleep 3
check "stale scrollback marker stops reading busy after the cap" no "$(coordinator_pane_busy && echo yes || echo no)"
tmux send-keys -t "$SMALL:coordinator.0" "new input" Enter
sleep 0.5
check "changed pane text re-arms the check (busy again)" yes "$(coordinator_pane_busy && echo yes || echo no)"
unset COORD_BUSY_SCROLLBACK_MAX_SECS
tmux kill-session -t "$SMALL" 2>/dev/null || true

# --- stale scrollback marker must never lead to a paste or to "submitted" (#785 review) ---
# Fake session in a small pane: a finished turn's "esc to interrupt" line sits
# above the visible rows, and the composer is on the last row. Raw-mode input so
# the fake can keep a draft in the composer and (optionally) swallow Enter.
cat > "$TEST_DIR/stale-repl.sh" <<'FAKE'
#!/usr/bin/env bash
echo "✻ Worked for 12s (esc to interrupt)"
for i in $(seq 1 15); do echo "  ☑ todo item $i"; done
buf="${FAKE_DRAFT:-}"
printf '❯ %s' "$buf"
stty -icanon -echo
while IFS= read -rsn1 ch; do
    case "$ch" in
        ''|$'\r'|$'\n')
            [ -n "${FAKE_SWALLOW_ENTER:-}" ] && continue
            [ -n "$buf" ] && printf '%s\n' "$buf" >> "$RECV_FILE"
            buf=""; printf '\r\033[K❯ ' ;;
        *) buf="$buf$ch"; printf '\r\033[K❯ %s' "$buf" ;;
    esac
done
FAKE
STALE="viewer-stale"
start_stale() {   # start_stale <session> <viewer:yes|no> [env assignments for the fake...]
    local s="$1" viewer="$2"; shift 2
    tmux kill-session -t "$s" 2>/dev/null || true
    tmux -f /dev/null new-session -d -s "$s" -n coordinator -x 80 -y 24 -c "$PROJECT"
    tmux set-window-option -t "$s:coordinator" pane-base-index 0
    if [ "$viewer" = yes ]; then
        COORD_VIEWER_MIN_SESSION_ROWS=1 coord_layout_on "$s" "$PROJECT" "$ROOT" 75
        tmux respawn-pane -k -t "$s:coordinator.1" "sleep 120"
        tmux select-pane -t "$s:coordinator.1" -T "$COORD_VIEWER_TITLE"
    fi
    : > "$TEST_DIR/stale-recv"
    tmux respawn-pane -k -t "$s:coordinator.0" "RECV_FILE=$TEST_DIR/stale-recv $* exec -a claude bash $TEST_DIR/stale-repl.sh"
}
SESSION_NAME="$STALE"
rm -f "$COORD_BUSY_STATE_FILE"

# 1. Operator draft + stale marker above the visible rows: no paste.
start_stale "$STALE" yes FAKE_DRAFT=my-unsent-operator-draft
eventually yes 'pane_has "$STALE:coordinator.0" my-unsent-operator-draft' || red "stale fake did not render"
check "premise: stale marker is not on the visible rows" no "$(pane_has "$STALE:coordinator.0" "esc to interrupt")"
printf 'DOORBELL-STALE-1\n' > "$TEST_DIR/bell3"
: > "$EVENTS_LOG"
rc=0; reprompt_inject "$STALE:coordinator.0" "$TEST_DIR/bell3" >/dev/null 2>&1 || rc=$?
check "operator draft + stale scrollback marker: wake deferred (rc 2)" 2 "$rc"
check "operator draft + stale scrollback marker: nothing pasted" no "$(pane_has "$STALE:coordinator.0" DOORBELL-STALE-1)"
check "operator draft + stale scrollback marker: nothing submitted to the session" no \
    "$(grep -qF DOORBELL-STALE-1 "$TEST_DIR/stale-recv" && echo yes || echo no)"
check "operator draft + stale scrollback marker: composer_dirty logged" yes \
    "$(grep -q 'reason=composer_dirty' "$EVENTS_LOG" && echo yes || echo no)"

# 2. Swallowed Enter: the paste changes the pane text, which re-arms the scrollback
#    match; the old check then read "busy" and reported the wake as submitted.
rm -f "$COORD_BUSY_STATE_FILE"; : > "$EVENTS_LOG"
start_stale "$STALE" yes FAKE_SWALLOW_ENTER=1
eventually yes 'pane_has "$STALE:coordinator.0" "❯"' || red "stale fake (swallow) did not render"
printf 'DOORBELL-STALE-2\n' > "$TEST_DIR/bell4"
rc=0; reprompt_inject "$STALE:coordinator.0" "$TEST_DIR/bell4" >/dev/null 2>&1 || rc=$?
check "swallowed Enter + stale marker: reprompt_inject reports failure (rc 1)" 1 "$rc"
check "swallowed Enter + stale marker: submit_failed logged" yes \
    "$(grep -q 'coord.wake.submit_failed' "$EVENTS_LOG" && echo yes || echo no)"
check "swallowed Enter: the fake really did not receive it" no "$(grep -qF DOORBELL-STALE-2 "$TEST_DIR/stale-recv" && echo yes || echo no)"
rm -f "$COORD_BUSY_STATE_FILE"
start_stale "$STALE" yes FAKE_SWALLOW_ENTER=1   # fresh composer, so "/compact" is its whole content
eventually yes 'pane_has "$STALE:coordinator.0" "❯"' || red "stale fake (compact) did not render"
tmux send-keys -t "$STALE:coordinator.0" -l "/compact"
sleep 0.4
check "compact_confirm_submitted: swallowed Enter + stale marker is NOT confirmed" 1 \
    "$(compact_confirm_submitted "$STALE:coordinator.0" "$COORD_BUSY_PATTERN" "/compact" && echo 0 || echo 1)"

# 3. The "did compaction start" wait reads visible rows only; the don't-interrupt
#    gate keeps the scrollback read while the viewer is on.
rm -f "$COORD_BUSY_STATE_FILE"
check "viewer on: coordinator_pane_busy (a hold gate) still sees the stale marker" yes "$(coordinator_pane_busy && echo yes || echo no)"
check "viewer on: coordinator_pane_busy_visible (start wait) does not" no "$(coordinator_pane_busy_visible && echo yes || echo no)"

# 4. Setting off (no viewer pane): a short pane behaves exactly as on master.
rm -f "$COORD_BUSY_STATE_FILE"
SESSION_NAME="viewer-off"
tmux kill-session -t "$STALE" 2>/dev/null || true
start_stale "$SESSION_NAME" no
eventually yes 'pane_has "$SESSION_NAME:coordinator.0" "todo item 15"' || red "viewer-off fake did not render"
tmux resize-window -t "$SESSION_NAME:coordinator" -y 10 2>/dev/null || true
sleep 0.3
check "premise (viewer off): pane is short" yes "$([ "$(tmux display-message -p -t "$SESSION_NAME:coordinator.0" -F '#{pane_height}')" -lt 24 ] && echo yes || echo no)"
check "premise (viewer off): marker is in scrollback" yes \
    "$(tmux capture-pane -t "$SESSION_NAME:coordinator.0" -p -S -60 | grep -qF 'esc to interrupt' && echo yes || echo no)"
check "viewer off, short pane, marker in scrollback: not busy (as on master)" no "$(coordinator_pane_busy && echo yes || echo no)"
check "viewer off: no scrollback state file written" no "$([ -e "$COORD_BUSY_STATE_FILE" ] && echo yes || echo no)"
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# --- the floor: the viewer never squeezes the session pane below the minimum -------
SESSION_NAME="viewer-floor"
tmux -f /dev/null new-session -d -s "$SESSION_NAME" -n coordinator -x 80 -y 24 -c "$PROJECT"
coord_layout_on "$SESSION_NAME" "$PROJECT" "$ROOT" 90
check "COORD_VIEWER_PCT=90 on a 24-row window keeps >=12 session rows" yes \
    "$([ "$(tmux display-message -p -t "$SESSION_NAME:coordinator.0" -F '#{pane_height}')" -ge 12 ] && echo yes || echo no)"
tmux kill-session -t "$SESSION_NAME"
tmux -f /dev/null new-session -d -s "$SESSION_NAME" -n coordinator -x 80 -y 10 -c "$PROJECT"
rc=0; coord_layout_on "$SESSION_NAME" "$PROJECT" "$ROOT" 75 2>/dev/null || rc=$?
check "10-row window: no viewer added (rc 1)" 1 "$rc"
check "10-row window: session pane left alone" 1 "$(tmux list-panes -t "$SESSION_NAME:coordinator" | wc -l)"

echo "all viewer-layout checks passed"
