#!/usr/bin/env bash
#
# test-worker-idle-shell-untouched-pickup.sh — issue #589: a brief dropped
# into inbox/ by requeue.sh must launch the agent even when the idle
# interactive shell's pane has never been touched (no Enter pressed) — see
# run_idle_shell()'s / poll_for_brief()'s header comments in
# worker-listener.sh for the mechanism (poll_for_brief ends the idle shell
# itself via SIGHUP once it's genuinely idle, instead of only ever noticing
# a pending brief from PROMPT_COMMAND on the next redrawn prompt).
#
# Same FIFO-stands-in-for-a-human technique as
# test-worker-close-defers-active-check.sh (see that file's header comment)
# — no real tmux/pty needed, since run_idle_shell()'s `bash -i` just reads
# whatever stdin the listener process itself was given.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t worker-idle-pickup-XXXXXX)
LISTENER_PID=""
STDIN_FD=9
cleanup() {
    exec 9>&- 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null || true
    [ -n "$LISTENER_PID" ] && wait "$LISTENER_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

wait_for() {
    local desc="$1" cmd="$2" max="${3:-20}"
    for ((i=0; i<max; i++)); do
        if eval "$cmd"; then return 0; fi
        sleep 0.5
    done
    red "timed out after ${max}x0.5s waiting for: $desc"
}

# drop_brief <wt> <id> <text> — mirrors requeue.sh's own atomic
# tmp-then-mv into inbox/ (same convention test-shape-checks.sh uses).
drop_brief() {
    local wt="$1" id="$2" text="$3" tmp
    tmp=$(mktemp -p "$wt/.swarm/tasks/inbox" .tmp.XXXX.md)
    printf '%s\n' "$text" > "$tmp"
    mv "$tmp" "$wt/.swarm/tasks/inbox/$id.md"
}

# ============================================================================
heading "Test 1: a brief dropped into an UNTOUCHED idle shell launches the agent on its own"
# ============================================================================
# The exact iss-1214 shape from the issue: nothing ever writes to the fifo
# (no Enter, no keystroke at all) after the shell goes idle.

WT="$TEST_DIR/wt-a"
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing" "$WT/.swarm/tasks/done" "$WT/.swarm/tasks/status"
mkdir -p "$WT/home"
mkfifo "$WT/stdin.fifo"

(
    cd "$WT" && \
    # -u TMUX -u TMUX_PANE: see test-worker-close-defers-active-check.sh's
    # identical guard for why an ambient TMUX_PANE must not leak in here.
    # AGENT=bash: dispatch_agent's no-real-CLI fallback (`bash -c
    # "$task_text"`) — this test only needs to prove the brief gets
    # CLAIMED, not exercise a real coding agent.
    env -u TMUX -u TMUX_PANE HOME="$WT/home" "$LISTENER" bash \
        < stdin.fifo > listener.log 2>&1
) &
LISTENER_PID=$!
# Persistent writer fd (see test-worker-close-defers-active-check.sh's
# comment on this same pattern): keeps the fifo open so the idle `bash -i`
# never sees an EOF of its own accord and exits for the wrong reason.
exec 9>"$WT/stdin.fifo"

wait_for "listener to go idle (no queued task)" \
    "grep -q 'dropping to interactive shell' '$WT/listener.log' 2>/dev/null"
green "listener has no task and dropped to its idle shell"

IDLE_AT=$SECONDS
drop_brief "$WT" "t1" "echo UNTOUCHED_PICKUP_OK"
green "brief dropped straight into inbox/ — nothing written to the fifo, exactly like an unattended pane"

# Generous bound: poll_for_brief's own cadence is 2s either side of the
# idle check, well under this.
wait_for "the untouched shell to notice and claim the brief on its own" \
    "grep -q 'Task received! id=t1' '$WT/listener.log' 2>/dev/null" 20
PICKUP_SECS=$((SECONDS - IDLE_AT))
green "picked up with no operator input, ${PICKUP_SECS}s after the brief landed (issue #589 fixed)"

[ "$PICKUP_SECS" -le 10 ] \
    || red "pickup took ${PICKUP_SECS}s — far more than the 2s poll cadence; something other than the fix is delaying it"
green "pickup latency (${PICKUP_SECS}s) is within the poll cadence, not stuck waiting on a keypress that never comes"

kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
exec 9>&-
LISTENER_PID=""

# ============================================================================
heading "Test 2: a brief landing mid-command is NOT claimed until that command finishes (issue #43 preserved)"
# ============================================================================

WT2="$TEST_DIR/wt-b"
mkdir -p "$WT2/.swarm/tasks/inbox" "$WT2/.swarm/tasks/processing" "$WT2/.swarm/tasks/done" "$WT2/.swarm/tasks/status"
mkdir -p "$WT2/home"
mkfifo "$WT2/stdin.fifo"

(
    cd "$WT2" && \
    exec env -u TMUX -u TMUX_PANE HOME="$WT2/home" "$LISTENER" bash \
        < stdin.fifo > listener.log 2>&1
) &
LISTENER_PID=$!
exec 8>"$WT2/stdin.fifo"

wait_for "second listener to go idle (no queued task)" \
    "grep -q 'dropping to interactive shell' '$WT2/listener.log' 2>/dev/null"
green "second listener idle"

# Operator starts a long foreground command — the shell has a live child
# the whole time this runs, so poll_for_brief must never signal it away.
printf 'sleep 4; echo MIDCOMMAND_FINISHED\n' >&8
sleep 1
drop_brief "$WT2" "t2" "echo SHOULD_WAIT"
green "brief dropped while the operator's 'sleep 4' is still running in the foreground"

sleep 2
grep -q 'Task received!' "$WT2/listener.log" 2>/dev/null \
    && red "brief was claimed while a foreground command was still running — issue #43's guarantee was broken; listener.log:
$(cat "$WT2/listener.log")"
green "2s in: still not claimed — the running command was not interrupted"

wait_for "'sleep 4' to finish on its own" \
    "grep -q 'MIDCOMMAND_FINISHED' '$WT2/listener.log' 2>/dev/null"
green "the foreground command ran to completion, undisturbed"

wait_for "the brief to be claimed now that the shell is actually idle" \
    "grep -q 'Task received! id=t2' '$WT2/listener.log' 2>/dev/null" 20
green "claimed right after the shell returned to idle — mid-command deferral still works, and the untouched case now self-heals too"

kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
exec 8>&-
LISTENER_PID=""

# ============================================================================
heading "Test 3: after a PR handback, the idle banner names the PR it waits on, with a clickable URL"
# ============================================================================

WT3="$TEST_DIR/wt-issue-903"
mkdir -p "$WT3/.swarm/tasks/inbox" "$WT3/.swarm/tasks/processing" "$WT3/.swarm/tasks/done" "$WT3/.swarm/tasks/status"
mkdir -p "$WT3/home" "$WT3/bin"
mkfifo "$WT3/stdin.fifo"
git -C "$WT3" init -q && git -C "$WT3" remote add origin git@github.com:acme/widgets.git
# Offline gh stub: the PR-marker cleanup on a handback must not hit GitHub.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WT3/bin/gh" && chmod +x "$WT3/bin/gh"
printf '%s\n' '{"state":"ready-for-review","pr":42}' > "$WT3/.swarm/tasks/status/t3.json"

(
    cd "$WT3" && \
    exec env -u TMUX -u TMUX_PANE HOME="$WT3/home" PATH="$WT3/bin:$PATH" "$LISTENER" bash \
        < stdin.fifo > listener.log 2>&1
) &
LISTENER_PID=$!
exec 8>"$WT3/stdin.fifo"

wait_for "third listener to go idle" \
    "grep -q 'dropping to interactive shell' '$WT3/listener.log' 2>/dev/null"
grep -q 'Waiting on:' "$WT3/listener.log" \
    && red "banner claims to wait on a PR before any task handed one back"
green "no 'Waiting on' line before any handback"

drop_brief "$WT3" "t3" "true"
wait_for "the handback task to finish and re-park" \
    "[ \"\$(grep -c 'dropping to interactive shell' '$WT3/listener.log')\" -ge 2 ]" 20
grep -qF 'Waiting on: your merge decision for PR #42 — https://github.com/acme/widgets/pull/42' "$WT3/listener.log" \
    || red "idle banner after a handback lacks the PR's clickable URL; listener.log:
$(cat "$WT3/listener.log")"
green "idle banner says it waits on PR #42 and carries its full https URL"

echo
green "ALL TESTS PASSED"
