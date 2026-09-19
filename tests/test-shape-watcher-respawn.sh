#!/usr/bin/env bash
#
# test-shape-watcher-respawn.sh — llm-start.sh's watcher idempotency guard
# must not mistake a DEAD coordinator-watch pane for a running one (#391).
#
# Why this needs a real tmux server rather than a PATH stub: the whole bug
# lives in tmux's own behavior. Under `remain-on-exit`, a pane whose command
# has exited stays in the window and KEEPS REPORTING its original
# pane_start_command, while pane_dead flips to 1. A stubbed tmux would just
# encode whatever we already believe, which is exactly the belief that was
# wrong — llm-start.sh matched on pane_start_command alone, so every re-run
# after coordinator-watch's self-kill (#296) reported "already running" and
# spawned nothing. corpusminder-spring and SAMlytics ran ~23h unwatched.
#
# Same extraction technique as test-llm-start-reprompt.sh: the function body
# is lifted from llm-start.sh with sed (never hand-copied), so a rename or an
# edit that breaks the contract fails here instead of drifting silently.
#
# Requires: tmux.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_START="$SCRIPT_DIR/../llm-start.sh"
[ -x "$LLM_START" ] || red "llm-start.sh not executable: $LLM_START"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"

# Own tmux server, so a failing test can never touch an operator's swarm
# sockets (llm-* sessions live on -L swarm-<project>).
SOCKET="test-respawn-$$"
SESSION="respawn-$$"
TEST_DIR=$(mktemp -d -t shape-respawn-XXXXXX)
cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    sed -n "/^${1}() {/,/^}/p" "$LLM_START"
}
body="$(extract_fn watcher_pane_scan)"
[ -n "$body" ] || red "could not extract 'watcher_pane_scan' from $LLM_START — renamed?"
eval "$body"

# The extracted function calls bare `tmux`; point that at our private server.
tmux() { command tmux -L "$SOCKET" "$@"; }

WATCH_SCRIPT="/opt/work/llm-swarm-runner/scripts/coordinator-watch.sh"

# A stand-in whose argv contains the real script path, so pane_start_command
# matches the way it does in a live swarm. Sleeps until told to die.
cat > "$TEST_DIR/fake-watch.sh" <<EOF
#!/usr/bin/env bash
# argv marker: $WATCH_SCRIPT
while [ ! -f "$TEST_DIR/stop" ]; do sleep 0.1; done
EOF
chmod +x "$TEST_DIR/fake-watch.sh"

command tmux -L "$SOCKET" new-session -d -s "$SESSION" -n util
command tmux -L "$SOCKET" set-option -t "$SESSION" remain-on-exit on

heading "Test 1: no watcher pane at all → scan reports nothing"
out="$(watcher_pane_scan "$SESSION:util" "$WATCH_SCRIPT")"
[ -z "$out" ] || red "expected empty scan on a bare util window; got: '$out'"
green "bare util window → no live marker, no corpses"

heading "Test 2: running watcher pane → 'live' (spawn must be skipped)"
command tmux -L "$SOCKET" split-window -d -v -b -t "$SESSION:util" \
    "$TEST_DIR/fake-watch.sh $WATCH_SCRIPT"
for _ in $(seq 1 50); do
    command tmux -L "$SOCKET" list-panes -t "$SESSION:util" \
        -F '#{pane_start_command}' 2>/dev/null | grep -qF "$WATCH_SCRIPT" && break
    sleep 0.1
done
out="$(watcher_pane_scan "$SESSION:util" "$WATCH_SCRIPT")"
[ "$out" = "live" ] || red "expected 'live' while the watcher runs; got: '$out'"
green "running watcher → 'live'"

heading "Test 3: THE BUG — watcher exits, pane lingers dead → must NOT be 'live'"
touch "$TEST_DIR/stop"
for _ in $(seq 1 100); do
    command tmux -L "$SOCKET" list-panes -t "$SESSION:util" \
        -F '#{pane_dead}' 2>/dev/null | grep -q '^1$' && break
    sleep 0.1
done

# Premise check: the dead pane still advertises its start command. If tmux
# ever stops doing this the bug is gone and this test is obsolete — assert it
# so that shows up as a signal rather than a silent pass.
command tmux -L "$SOCKET" list-panes -t "$SESSION:util" \
    -F '#{pane_dead} #{pane_start_command}' | grep -q "^1 .*$WATCH_SCRIPT" \
    || red "premise broken: dead pane no longer reports pane_start_command"
green "premise holds: dead pane still reports its start command"

out="$(watcher_pane_scan "$SESSION:util" "$WATCH_SCRIPT")"
[ "$out" != "live" ] || red "REGRESSION (#391): dead watcher pane reported as 'live' — llm-start.sh would skip the respawn"
[ -n "$out" ] || red "expected the dead pane's index as a corpse; got nothing"
[[ "$out" =~ ^[0-9]+$ ]] || red "expected a single numeric pane index; got: '$out'"
green "dead watcher → not 'live', corpse index $out returned for reaping"

heading "Test 4: corpse index is real — kill-pane accepts it"
command tmux -L "$SOCKET" kill-pane -t "$SESSION:util.$out" \
    || red "corpse index $out was not a killable pane target"
out2="$(watcher_pane_scan "$SESSION:util" "$WATCH_SCRIPT")"
[ -z "$out2" ] || red "expected a clean window after reaping the corpse; got: '$out2'"
green "corpse reaped; window clean"

heading "Test 5: live watcher alongside an older corpse → still 'live'"
rm -f "$TEST_DIR/stop"
command tmux -L "$SOCKET" split-window -d -v -b -t "$SESSION:util" \
    "$TEST_DIR/fake-watch.sh $WATCH_SCRIPT"
command tmux -L "$SOCKET" split-window -d -v -b -t "$SESSION:util" \
    "$TEST_DIR/fake-watch.sh $WATCH_SCRIPT"
for _ in $(seq 1 50); do
    [ "$(command tmux -L "$SOCKET" list-panes -t "$SESSION:util" \
        -F '#{pane_start_command}' | grep -cF "$WATCH_SCRIPT")" -ge 2 ] && break
    sleep 0.1
done
# Kill one of the two watcher processes, leaving one live + one corpse.
victim="$(command tmux -L "$SOCKET" list-panes -t "$SESSION:util" \
    -F '#{pane_index} #{pane_pid} #{pane_start_command}' \
    | grep -F "$WATCH_SCRIPT" | head -1)"
kill -9 "$(echo "$victim" | awk '{print $2}')" 2>/dev/null || true
for _ in $(seq 1 100); do
    command tmux -L "$SOCKET" list-panes -t "$SESSION:util" \
        -F '#{pane_dead}' | grep -q '^1$' && break
    sleep 0.1
done
out="$(watcher_pane_scan "$SESSION:util" "$WATCH_SCRIPT")"
[ "$out" = "live" ] || red "a live watcher must win over a corpse; got: '$out'"
green "live watcher + corpse → 'live' (no duplicate watcher spawned)"

printf '\n\033[1;32mAll checks passed.\033[0m\n'
