#!/usr/bin/env bash
#
# test-worker-close-defers-active-check.sh — issue #555 self-review round
# 13: a check-on-done run (coordinator-watch.sh's execute_check, this PR's
# pane) can still be genuinely running when the operator closes the worker.
# The check pane shares its window with the worker pane (index 0); closing
# pane 0 right then would let tmux renumber the still-RUNNING check pane
# down into slot 0 the instant pane 0 exits, and every pane_dead(head -1)
# reader in the codebase (provision-worker.sh's reclaim guard,
# has_live_window_draining_brief, check-stuck-workers.sh) would read that
# genuinely-running check command as a live worker until it finishes.
#
# Round 12's fix only covers a check that has already resolved (the pane
# exits dead instead of staying an interactive shell — see
# tests/test-watch-check-pane.sh's Test 16). This test covers the
# still-running case: worker-listener.sh's close-worker and double-exit
# clean-exit paths now wait out any active, non-stale check-claim (same
# claim-dir ground truth kill-worktree.sh's reap-defer path, issue #181,
# already uses) before actually exiting.
#
# No real tmux needed — run_idle_shell()'s `bash --rcfile ... -i` reads
# commands from whatever stdin the listener process itself was given, so a
# FIFO stands in for a human typing at the idle prompt, exactly the way
# tests/test-shape-checks.sh drives the listener's `bash` fallback agent
# without a tty.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t worker-close-defer-XXXXXX)
LISTENER_PID=""
STDIN_FD=9
cleanup() {
    exec 9>&- 2>/dev/null || true
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
    red "timed out after ${max}0.5s waiting for: $desc"
}

heading "Setup: an idle listener with no queued task, and a simulated still-running check's claim"

WT="$TEST_DIR/wt-a"
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing" "$WT/.swarm/tasks/done" "$WT/.swarm/tasks/status"

# Stands in for coordinator-watch.sh's execute_check having won this claim
# (maybe_run_check, issue #181) for a completion on this same worktree —
# the exact shape a check pane leaves behind while genuinely still running.
mkdir -p "$WT/.swarm/tasks/status/t1.check-claim"

mkdir -p "$WT/home"
mkfifo "$WT/stdin.fifo"
# Interactive mode (WORKER_HEADLESS unset/0), not the headless default
# other listener tests use — run_idle_shell()'s `bash -i` idle prompt
# (the close-worker/double-exit code this test covers) only runs in
# interactive mode; headless mode skips straight to a silent poll.
(
    cd "$WT" && \
    env HOME="$WT/home" "$LISTENER" bash \
        < stdin.fifo > listener.log 2>&1
) &
LISTENER_PID=$!
# A persistent writer fd keeps the fifo open across multiple writes —
# without it, the reader (bash -i) would see EOF the instant a single
# `echo > fifo` writer closed, and exit on its own instead of staying
# parked at the idle prompt the way a real human-attached pane would.
exec 9>"$WT/stdin.fifo"

wait_for "listener to go idle (no queued task)" \
    "grep -q 'dropping to interactive shell' '$WT/listener.log' 2>/dev/null"
green "listener has no task and dropped to its idle shell"

# ============================================================================
heading "Test 1: close-worker defers while the check-claim is active, not an immediate exit"
# ============================================================================

printf 'close-worker\n' >&$STDIN_FD

wait_for "the deferred-close wait message to appear" \
    "grep -q 'still running — waiting for it to finish before closing' '$WT/listener.log' 2>/dev/null"
green "close-worker was honored but deferred — the listener printed that it's waiting on the active check"

sleep 2
kill -0 "$LISTENER_PID" 2>/dev/null \
    || red "the listener process should still be alive, waiting out the active check-claim, not have exited early"
green "the listener is still alive 2s later — it did not exit while the check-claim was still active"

grep -q 'listener exiting' "$WT/listener.log" 2>/dev/null \
    && red "the listener should not have printed its final exit message yet — the claim is still active"
green "no premature 'listener exiting' — the close is genuinely parked, not raced past"

# ============================================================================
heading "Test 2: once the check-claim clears, the deferred close completes on its own"
# ============================================================================

rmdir "$WT/.swarm/tasks/status/t1.check-claim"

wait_for "the listener process to exit now that the claim is gone" \
    "! kill -0 '$LISTENER_PID' 2>/dev/null"
green "the listener exited once the check-claim cleared — the deferred close completed on its own, no operator action needed"

grep -q 'close requested: listener exiting — window will close' "$WT/listener.log" \
    || red "expected the real close-exit message in the log; got:
$(cat "$WT/listener.log")"
green "the log shows the real close-exit message, not a stuck or silent exit"

LISTENER_PID=""
echo
green "ALL TESTS PASSED"
