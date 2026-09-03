#!/usr/bin/env bash
#
# test-worker-deliver-brief.sh — Tests for coordinator-watch.sh's
# WORKER_AUTO_DELIVER feature (issue #313): a follow-up brief dropped by
# requeue.sh into a worker's inbox/ never reaches it if that worker's
# interactive agent session is parked at rest INSIDE the still-running
# `claude` process rather than back at worker-listener.sh's own idle bash
# loop (dispatch_agent blocks on the live agent process, so claim_next_task
# never runs again). maybe_worker_deliver_brief() closes that gap by ending
# the session (/quit) once it's verified idle, with a real brief waiting,
# AND its current task has positively confirmed reaching a terminal status
# (self-review finding: a `blocked` worker awaiting a decision looks
# identical to a finished one from pane state alone — see
# worker_current_task_terminal()'s header comment in coordinator-watch.sh).
#
# Same extraction-from-the-real-script technique as test-worker-auto-compact.sh
# (the sibling feature sharing the same background sweep) — see that file's
# header comment for the full rationale.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"
command -v jq   >/dev/null 2>&1 || red "jq not found — required by this feature and this test"

TEST_DIR=$(mktemp -d -t worker-deliver-brief-XXXXXX)
SESSION_NAME="test-worker-deliver-$$"
cleanup() {
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    local fn="$1"
    sed -n "/^${fn}() {/,/^}/p" "$WATCH"
}
for fn in worker_pane_state worker_pane_busy worker_pane_ctx_used worker_pending_brief \
          worker_current_task_terminal compact_last_pane_line compact_composer_clear \
          compact_confirm_submitted compact_retract_queued worker_deliver_record_failure \
          worker_deliver_record_success maybe_worker_deliver_brief log_event; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done

# ─────────────────────────── fixed env the functions expect ────────────────
EVENTS_LOG="$TEST_DIR/events.log"; : > "$EVENTS_LOG"
HAVE_JQ=1
DRY_RUN=1
WORKER_AUTO_DELIVER=1
# issue #252/#274: must match coordinator-watch.sh's own default — see
# test-worker-auto-compact.sh's copy of this same pattern for why.
WORKER_COMPACT_BUSY_PATTERN='\(esc to interrupt\)|Press Ctrl-C again to .xit|Compacting conversation'
WORKER_DELIVER_POLL_SECS=1
WORKER_DELIVER_END_TIMEOUT_SECS=10
WORKER_DELIVER_BACKOFF_SECS=600
WORKER_DELIVER_MAX_FAILURES=3
COMPACT_QUEUED_MARKER_PATTERN='Press up to edit queued messages'
COMPACT_RETRACT_BACKSPACES=3
COMPACT_SUBMIT_SETTLE_SECS=0
declare -A WORKER_DELIVER_LAST_FAIL=()
declare -A WORKER_DELIVER_FAIL_COUNT=()
declare -A WORKER_DELIVER_GAVE_UP=()

WORKSPACE="$TEST_DIR/workspace"
WT_DIR="$WORKSPACE/wt-issue-42"
INBOX_DIR="$WT_DIR/.swarm/tasks/inbox"
PROCESSING_DIR="$WT_DIR/.swarm/tasks/processing"
STATUS_DIR="$WT_DIR/.swarm/tasks/status"
mkdir -p "$INBOX_DIR" "$PROCESSING_DIR" "$STATUS_DIR"
WIN="iss-42"

# set_current_task <task_id> [state]
#
# Simulates worker-listener.sh's claim_next_task having a task claimed in
# processing/ (always true while the agent is alive), optionally with a
# worker-written status file at the given state. No status argument leaves
# processing/ populated but status/ empty — "claimed, no status written
# yet" (e.g. a task still genuinely in flight).
set_current_task() {
    local task_id="$1" state="${2:-}"
    rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
    echo "the current task brief" > "$PROCESSING_DIR/$task_id.md"
    if [ -n "$state" ]; then
        printf '{"task_id":"%s","state":"%s","pr":null,"ts":"2026-01-01T00:00:00Z","note":""}' \
            "$task_id" "$state" > "$STATUS_DIR/$task_id.json"
    fi
}

PASS=0

check() {
    local desc="$1" expect="$2" got="$3"
    if [ "$expect" = "$got" ]; then
        green "$desc"
        PASS=$((PASS + 1))
    else
        red "$desc (expected [$expect] got [$got])"
    fi
}

# check_eventually — poll instead of a fixed sleep, avoids flaking under load
# (same rationale as test-worker-auto-compact.sh's twin).
check_eventually() {
    local desc="$1" expect="$2" cmd="$3" max="${4:-30}"
    local got=""
    for ((i = 0; i < max; i++)); do
        got="$(eval "$cmd")"
        if [ "$expect" = "$got" ]; then
            green "$desc"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep 0.1
    done
    red "$desc (expected [$expect] got [$got] after $((max))x0.1s polling)"
}

heading "Test 1: worker_pending_brief"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "empty inbox -> rc1 (nothing pending)" "1" "$rc"

: > "$INBOX_DIR/.tmp.abc123.md"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "only a mktemp temp file in inbox -> rc1 (not a real brief)" "1" "$rc"
rm -f "$INBOX_DIR"/.tmp.*

echo "a follow-up brief" > "$INBOX_DIR/20260826-120000-42.md"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "real brief file in inbox -> rc0 (pending)" "0" "$rc"

heading "Test 2: worker_current_task_terminal (self-review finding — the false-completion guard)"
rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "nothing claimed in processing/ -> rc1 (not confirmed terminal)" "1" "$rc"

set_current_task "t1"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "claimed in processing/ but no status file yet -> rc1 (can't confirm; still could be genuinely in flight)" "1" "$rc"

set_current_task "t1" "blocked"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "status=blocked -> rc1 (awaiting a decision, task did NOT actually conclude)" "1" "$rc"

set_current_task "t1" "ready-for-review"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "status=ready-for-review -> rc0 (genuinely terminal)" "0" "$rc"

set_current_task "t1" "done-no-pr"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "status=done-no-pr -> rc0 (genuinely terminal)" "0" "$rc"

heading "Test 3: maybe_worker_deliver_brief — gating (DRY_RUN)"
tmux new-session -d -s "$SESSION_NAME" -n "$WIN" 2>/dev/null
check_eventually "fresh window, bash foreground -> shell" "shell" "worker_pane_state '$WIN'"

: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
check "listener's own idle bash shell (state=shell) -> nothing logged (issue #43 self-heals this case)" "0" "$(wc -l < "$EVENTS_LOG")"

tmux send-keys -t "$SESSION_NAME:$WIN" "sleep 300" Enter
check_eventually "non-shell foreground -> cli" "cli" "worker_pane_state '$WIN'"
rm -f "$INBOX_DIR"/*.md
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
check "cli state but nothing pending in inbox/ -> nothing logged" "0" "$(wc -l < "$EVENTS_LOG")"

echo "a follow-up brief" > "$INBOX_DIR/20260826-120000-42.md"

# The critical self-review-fixed case: a real brief IS pending, but the
# CURRENT task is merely "blocked" (a decision-needed worker awaiting the
# coordinator's answer — the exact incident half prompts/coordinator.md's
# "unblock it with requeue.sh" line describes). Must NOT be treated the same
# as a finished-and-parked worker.
set_current_task "t1" "blocked"
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.skip.*reason=task_not_terminal' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "current task status=blocked -> skipped as task_not_terminal (never falsely 'completes' unfinished work)" "skipped" "$got"
if grep -q 'worker.deliver.attempt' "$EVENTS_LOG"; then got=attempted; else got=notattempted; fi
check "blocked task -> delivery never attempted" "notattempted" "$got"

# From here on, the current task has genuinely finished — the OTHER incident
# half (a worker that opened its PR, handed off, and simply never ran /quit).
set_current_task "t1" "ready-for-review"

busy_or_idle() { if worker_pane_busy "$WIN"; then echo busy; else echo idle; fi; }

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo '✻ Considering… (esc to interrupt)'; sleep 300" Enter
check_eventually "busy chrome visible -> worker_pane_busy true" "busy" 'busy_or_idle'
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.skip.*reason=pane_busy' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "brief pending, task terminal, but pane busy -> skipped as pane_busy (never interrupt a live turn)" "skipped" "$got"

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane -> cli" "cli" "worker_pane_state '$WIN'"
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.attempt' "$EVENTS_LOG"; then got=attempted; else got=notattempted; fi
check "idle, brief pending, task terminal, composer empty -> attempts delivery (DRY_RUN, no real injection sent)" "attempted" "$got"

heading "Test 3b: no_ctx_parsed guard — a WORKER_HEADLESS=1 claude -p run renders no busy chrome AND no statusline (self-review finding)"
# A headless `claude -p` invocation shows plain output, never Claude Code's
# TUI statusline — worker_pane_busy() never matches it either, so without
# this gate a still-running headless task could otherwise look identical to
# an idle interactive one the whole time it runs.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'plain -p stdout, no statusline, no busy chrome'; sleep 300" Enter
check_eventually "headless-like plain-text pane -> cli" "cli" "worker_pane_state '$WIN'"
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.skip.*reason=no_ctx_parsed' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "no interactive statusline on screen -> skipped as no_ctx_parsed (never touches a live headless run)" "skipped" "$got"
if grep -q 'worker.deliver.attempt' "$EVENTS_LOG"; then got=attempted; else got=notattempted; fi
check "no_ctx_parsed -> delivery never attempted" "notattempted" "$got"

# Restore the idle-with-statusline pane for the tests that follow.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane restored -> cli" "cli" "worker_pane_state '$WIN'"

heading "Test 4: composer-not-clear guard (issue #313's observed dimmed-suggestion case)"
compact_composer_clear() { return 1; }   # simulate unsubmitted composer text
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.skip.*reason=composer_not_clear' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "composer holds unsubmitted text -> skipped, never pastes /quit over it" "skipped" "$got"
if grep -q 'worker.deliver.attempt' "$EVENTS_LOG"; then got=attempted; else got=notattempted; fi
check "composer not clear -> delivery never attempted" "notattempted" "$got"
unset -f compact_composer_clear
body="$(extract_fn compact_composer_clear)"; eval "$body"   # restore the real function

heading "Test 5: per-window backoff after failed delivery attempts (issue #313, mirrors #252's compact backoff)"
: > "$EVENTS_LOG"
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]'

worker_deliver_record_failure 42
check "1st consecutive failure -> not yet given up" "" "${WORKER_DELIVER_GAVE_UP[42]:-}"
worker_deliver_record_failure 42
check "2nd consecutive failure -> still not given up" "" "${WORKER_DELIVER_GAVE_UP[42]:-}"
if grep -q 'worker.deliver.giving_up' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "no giving_up event before WORKER_DELIVER_MAX_FAILURES (3) is reached" "missing" "$got"

worker_deliver_record_failure 42
check "3rd consecutive failure (MAX_FAILURES=3) -> gave up" "1" "${WORKER_DELIVER_GAVE_UP[42]:-}"
if grep -q 'worker.deliver.giving_up.*issue=42 failures=3' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "worker.deliver.giving_up logged exactly once, with failures=3" "logged" "$got"

before="$(wc -l < "$EVENTS_LOG")"
maybe_worker_deliver_brief "$WIN"
after="$(wc -l < "$EVENTS_LOG")"
check "gave-up window: maybe_worker_deliver_brief stays silent (no new log lines)" "$before" "$after"

unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]'
WORKER_DELIVER_LAST_FAIL[42]=$(date +%s)
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.skip.*reason=backoff' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "recent failure timestamp -> skipped as backoff (cooldown still active)" "skipped" "$got"

WORKER_DELIVER_FAIL_COUNT[42]=2
worker_deliver_record_success 42
check "record_success clears LAST_FAIL" "" "${WORKER_DELIVER_LAST_FAIL[42]:-}"
check "record_success clears FAIL_COUNT" "" "${WORKER_DELIVER_FAIL_COUNT[42]:-}"
check "record_success clears GAVE_UP" "" "${WORKER_DELIVER_GAVE_UP[42]:-}"

heading "Test 6: real (non-DRY_RUN) /quit injection against a fake worker REPL"
# Stand-in for a live worker Claude Code REPL that recognizes /quit as its
# own exit command (matching worker-listener.sh's documented convention).
# Launched as `bash -c 'exec -a claude bash $FAKE_REPL'` — a FOREGROUND
# CHILD of the pane's own top-level bash, exec-renaming only that child
# (not the pane's shell itself) so pane_current_command reports "claude"
# while it runs, exactly like a real dispatch_agent invocation, and so the
# pane cleanly returns to that same top-level bash the moment the fake REPL
# exits — mirroring worker-listener.sh's real claim_next_task loop
# regaining control after dispatch_agent's `claude ...` returns.
FAKE_REPL="$TEST_DIR/fake-worker-repl.sh"
cat > "$FAKE_REPL" <<'REPL'
#!/usr/bin/env bash
render() { echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; }
render
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$line" = "/quit" ]; then
        exit 0
    fi
    clear
    echo "resumed: $line"
    render
done
REPL
chmod +x "$FAKE_REPL"

DRY_RUN=0
WORKER_DELIVER_END_TIMEOUT_SECS=10
WORKER_DELIVER_POLL_SECS=1
: > "$EVENTS_LOG"
rm -f "$INBOX_DIR"/*.md
echo "a follow-up brief" > "$INBOX_DIR/20260826-140000-42.md"
set_current_task "t2" "ready-for-review"   # current task already finished

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "bash -c 'exec -a claude bash $FAKE_REPL'" Enter
check_eventually "fake REPL foreground (argv[0]=claude) -> cli" "cli" "worker_pane_state '$WIN'"

maybe_worker_deliver_brief "$WIN"

check_eventually "session ended -> pane back to the listener's own bash shell (state=shell)" "shell" "worker_pane_state '$WIN'"
if grep -q 'worker.deliver.ended' "$EVENTS_LOG"; then
    green "real /quit injection ended the parked session"
    PASS=$((PASS + 1))
else
    red "expected worker.deliver.ended; events.log: $(cat "$EVENTS_LOG")"
fi
if grep -q 'worker.deliver.timeout' "$EVENTS_LOG"; then
    red "unexpected worker.deliver.timeout logged alongside a successful exit; events.log: $(cat "$EVENTS_LOG")"
else
    green "no false-positive worker.deliver.timeout on a successful exit"
    PASS=$((PASS + 1))
fi

heading "Test 7: agent doesn't recognize /quit (e.g. a non-claude CLI) -> times out and fails safe"
# Same shape as Test 6's fixture, but this fake REPL never treats /quit as
# special — it just echoes it back like any other line, the way a CLI with
# no matching slash/exit command would. maybe_worker_deliver_brief must
# never escalate beyond the paste+Enter it already sent: it should simply
# time out, log the failure, and leave the session running untouched.
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]'
FAKE_REPL2="$TEST_DIR/fake-worker-repl-no-quit.sh"
cat > "$FAKE_REPL2" <<'REPL'
#!/usr/bin/env bash
render() { echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; }
render
while IFS= read -r line; do
    [ -z "$line" ] && continue
    clear
    echo "resumed: $line"
    render
done
REPL
chmod +x "$FAKE_REPL2"

: > "$EVENTS_LOG"
echo "another brief" > "$INBOX_DIR/20260826-150000-42.md"
set_current_task "t3" "done-no-pr"   # current task already finished
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "bash -c 'exec -a gemini bash $FAKE_REPL2'" Enter
check_eventually "fake non-quitting REPL foreground -> cli" "cli" "worker_pane_state '$WIN'"

WORKER_DELIVER_END_TIMEOUT_SECS=3 WORKER_DELIVER_POLL_SECS=1 maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.timeout' "$EVENTS_LOG"; then got=timedout; else got=nottimedout; fi
check "agent doesn't recognize /quit -> times out (fails safe)" "timedout" "$got"
check "pane still 'cli' -> the session was never actually ended" "cli" "$(worker_pane_state "$WIN")"

echo
green "All $PASS checks passed."
