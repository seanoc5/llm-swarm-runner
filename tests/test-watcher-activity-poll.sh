#!/usr/bin/env bash
#
# test-watcher-activity-poll.sh — Non-LLM shape test for coordinator-watch.sh's
# activity_poll_pass / on_activity (issue #392).
#
# Background: every existing wake path either reacts to a file a WORKER
# wrote (outcome.json, an outbox message), or only looks at PRs/worktrees
# this swarm still has a live tmux window or worktree directory for
# (WATCH_PR_POLL_SECS's pr_poll_pass, WATCH_ORPHAN_SWEEP_SECS's
# orphan_sweep_pass). An operator who merges/closes a PR, or closes an
# issue, straight in the GitHub web UI for a worker that was reaped long
# ago produces none of those signals — the coordinator can sit there
# reporting a decision as "pending your call" indefinitely. This test
# exercises the fix: a periodic gh-search poll, independent of every reap
# pass, that wakes the coordinator when it finds PR merges / issue closes
# since its last check — with noise control so it doesn't wake itself over
# its own reap.window-logged actions.
#
# Strategy: stub gh + llm-start.sh, same technique as
# test-watcher-autoclose.sh's pr-poll tests, but with a dedicated gh stub
# shaped for THIS feature's two queries (gh pr list --state merged, gh
# issue list --state closed) rather than reusing that file's pr_poll_pass-
# shaped stub. Every other timer-loop pass (WATCH_PR_POLL_SECS,
# WATCH_ORPHAN_SWEEP_SECS, WATCH_BG_VIOLATION_SWEEP_SECS,
# WATCH_CHECK_ON_DONE) is disabled throughout so only activity_poll_pass is
# under test.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"

TEST_DIR=$(mktemp -d -t watcher-activity-poll-XXXXXX)
cleanup() {
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
    [ -n "${WATCH_PID:-}" ] && wait "$WATCH_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR/.swarm"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"

# ────────────────────────── Stubs: gh + llm-start ──────────────────────────

WAKE_LOG="$TEST_DIR/wake.log"
: > "$WAKE_LOG"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<EOF
#!/usr/bin/env bash
printf '%s  WAKE: %s\n' "\$(date +%s%N)" "\$*" >> "$WAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LLM_START"

# activity_poll_pass's two queries land here, tab-separated matching its
# own --jq shapes: PR_FIXTURE is "number\ttitle\theadRefName", ISSUE_FIXTURE
# is "number\ttitle". Empty by default (no activity). GH_CALL_LOG records
# every invocation's $1 $2 so a test can assert a query fired (or, for the
# disabled-poll test, that it never did.
PR_FIXTURE="$TEST_DIR/gh-pr-merged.tsv"
ISSUE_FIXTURE="$TEST_DIR/gh-issue-closed.tsv"
GH_CALL_LOG="$TEST_DIR/gh-calls.log"
GH_FAIL_PR_LIST="$TEST_DIR/gh-fail-pr-list"
: > "$PR_FIXTURE"
: > "$ISSUE_FIXTURE"
: > "$GH_CALL_LOG"
rm -f "$GH_FAIL_PR_LIST"

mkdir -p "$TEST_DIR/bin"
FAKE_GH="$TEST_DIR/bin/gh"
cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$2" >> "$GH_CALL_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
    [ -f "$GH_FAIL_PR_LIST" ] && exit 1
    cat "$PR_FIXTURE"
    exit 0
fi
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
    cat "$ISSUE_FIXTURE"
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_GH"
export PATH="$TEST_DIR/bin:$PATH"

# Helper: start the watcher with only activity_poll_pass's timer enabled.
# ONCE is deliberately never used here — on_activity doesn't honor it (see
# its header comment: it runs in run_watch_timer_loop's own backgrounded
# subshell, where `exit 0` can't terminate the main process) — so every
# test starts the daemon with ONCE=0 and stops it explicitly.
start_watcher() {
    local logfile="$1" poll_secs="${2:-1}"
    LLM_START="$FAKE_LLM_START" \
        WORKSPACE="$TEST_DIR" \
        WATCHER_AUTOCLOSE=0 \
        WATCH_PR_POLL_SECS=0 \
        WATCH_ORPHAN_SWEEP_SECS=0 \
        WATCH_BG_VIOLATION_SWEEP_SECS=0 \
        WATCH_CHECK_ON_DONE=0 \
        WATCH_ACTIVITY_POLL_SECS="$poll_secs" \
        DRY_RUN=0 ONCE=0 POLL_SECS=1 DEBOUNCE_SECS=0 \
        "$WATCH" "$PROJECT_DIR" > "$logfile" 2>&1 &
    WATCH_PID=$!
    sleep 1
}

stop_watcher() {
    [ -n "${WATCH_PID:-}" ] || return 0
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    unset WATCH_PID
}

# ============================================================================
heading "Test 1: a merged PR + closed issue with no reap.window wakes the coordinator"
# ============================================================================
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
printf '1070\tFix the thing\tfix/issue-1070\n' > "$PR_FIXTURE"
printf '1071\tStale request\n' > "$ISSUE_FIXTURE"

start_watcher "$TEST_DIR/watch-1.log" 1
sleep 3
stop_watcher

grep -q 'WAKE:' "$WAKE_LOG" || red "activity poll never woke the coordinator. Watch log:
$(cat "$TEST_DIR/watch-1.log")"
grep -q 'PR #1070 merged' "$WAKE_LOG" || red "wake prompt missing the merged-PR line: $(cat "$WAKE_LOG")"
grep -q 'Issue #1071 closed' "$WAKE_LOG" || red "wake prompt missing the closed-issue line: $(cat "$WAKE_LOG")"
green "activity poll detected an out-of-band PR merge + issue close and woke the coordinator naming both"

grep -q 'watch.activity_poll .*reason=detected' "$EVENTS_LOG" \
    || red "expected watch.activity_poll reason=detected in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'coord.wake .*trigger=activity_poll' "$EVENTS_LOG" \
    || red "expected coord.wake trigger=activity_poll in events.log"
green "events.log records watch.activity_poll(reason=detected) + coord.wake(trigger=activity_poll)"

# ============================================================================
heading "Test 2: a merged PR (and its same-numbered closed issue) already covered by this swarm's own reap.window is not re-announced"
# ============================================================================
# A merged PR with "Closes #N" auto-closes issue #N too — both the PR and
# issue fixtures use 2000 here to exercise BOTH dedup checks
# (swarm_already_reaped is applied to both the merged-PR loop and the
# closed-issue loop; see activity_poll_pass) with a single reap.window entry.
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
printf '2000\tAlready reaped by us\tfix/issue-2000\n' > "$PR_FIXTURE"
printf '2000\tAlready reaped by us\n' > "$ISSUE_FIXTURE"

start_watcher "$TEST_DIR/watch-2.log" 1
# Log the swarm's own reap.window event for issue 2000 AFTER the watcher's
# boot cursor (LAST_ACTIVITY_POLL_TS starts at boot time) so the dedup
# check's "at/after cursor" predicate matches it.
printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "reap.window" \
    "issue=2000 window=iss-2000 branch=fix/issue-2000 reasons=merged capture=none" >> "$EVENTS_LOG"
sleep 3
stop_watcher

grep -q 'WAKE:' "$WAKE_LOG" && red "activity poll woke the coordinator over a PR/issue this swarm's own pipeline already reaped: $(cat "$WAKE_LOG")"
green "activity poll did not re-announce a PR or issue already covered by a reap.window event"
# Two separate dedup checks in activity_poll_pass: the merged-PR loop logs
# "pr=2000 issue=2000", the closed-issue loop logs "issue=2000" (no pr=) —
# assert both fired at least once (poll_secs=1 may tick more than once in
# the 3s sleep above, so this checks presence, not an exact count).
grep -q 'watch.activity_poll .*reason=skipped_self_reaped pr=2000 issue=2000' "$EVENTS_LOG" \
    || red "expected the merged-PR loop's skipped_self_reaped (pr=2000 issue=2000) in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'watch.activity_poll .*reason=skipped_self_reaped issue=2000$' "$EVENTS_LOG" \
    || red "expected the closed-issue loop's skipped_self_reaped (issue=2000, no pr=) in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "events.log records the skip as reason=skipped_self_reaped for both the merged PR and the closed issue"

# ============================================================================
heading "Test 3: WATCH_ACTIVITY_POLL_SECS=0 disables the poll entirely"
# ============================================================================
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
: > "$GH_CALL_LOG"
printf '3000\tShould never be seen\tfix/issue-3000\n' > "$PR_FIXTURE"

start_watcher "$TEST_DIR/watch-3.log" 0
sleep 3
stop_watcher

grep -q '^pr list$' "$GH_CALL_LOG" && red "gh pr list was called despite WATCH_ACTIVITY_POLL_SECS=0: $(cat "$GH_CALL_LOG")"
grep -q 'WAKE:' "$WAKE_LOG" && red "coordinator was woken despite WATCH_ACTIVITY_POLL_SECS=0: $(cat "$WAKE_LOG")"
green "WATCH_ACTIVITY_POLL_SECS=0 disables activity_poll_pass entirely (no gh calls, no wake)"

# ============================================================================
heading "Test 4: a gh failure logs activity_poll.error and doesn't crash the daemon"
# ============================================================================
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
printf '4000\tUnreachable due to gh failure\tfix/issue-4000\n' > "$PR_FIXTURE"
: > "$ISSUE_FIXTURE"
touch "$GH_FAIL_PR_LIST"

start_watcher "$TEST_DIR/watch-4.log" 1
sleep 3
kill -0 "$WATCH_PID" 2>/dev/null || red "watcher process died after a gh failure — should have continued running"
stop_watcher
rm -f "$GH_FAIL_PR_LIST"

grep -q 'activity_poll.error .*reason=gh_pr_list_failed' "$EVENTS_LOG" \
    || red "expected activity_poll.error reason=gh_pr_list_failed in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'WAKE:' "$WAKE_LOG" && red "coordinator was woken despite the gh pr list failure: $(cat "$WAKE_LOG")"
green "a gh pr list failure logs activity_poll.error, skips the wake, and leaves the daemon running"

echo
green "All activity-poll tests passed."
