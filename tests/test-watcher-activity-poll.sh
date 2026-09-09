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

# activity_worktree_still_live (issue #392 self-review's skipped_worktree_
# live check) shells out to `git -C "$PROJECT_DIR" worktree list` — a real
# repo is needed so it can actually confirm "not registered" for a
# candidate rather than erroring. It deliberately fails CLOSED ("not
# confirmed live" -> proceed to announce) on a git error, the opposite of
# is_own_worktree_dir's fail-open elsewhere in this file — see that
# function's own header comment for why.
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init

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
# poll_secs=1 over this 3s sleep fires several ticks against the SAME
# static fixture (the fake gh stub ignores --search entirely) — a real gh
# would naturally stop returning an already-past merge once the cursor
# moves on, but this stub can't emulate that filtering. The
# ACTIVITY_ANNOUNCED_PR/_ISSUE dedup maps are what keep repeated ticks from
# re-waking the coordinator over the same PR/issue (issue #392 self-review:
# without them, ACTIVITY_POLL_OVERLAP_SECS's cursor overlap alone would
# cause exactly this repeat-wake bug) — asserted below via WAKE_COUNT.
sleep 3
stop_watcher

grep -q 'WAKE:' "$WAKE_LOG" || red "activity poll never woke the coordinator. Watch log:
$(cat "$TEST_DIR/watch-1.log")"
grep -q 'PR #1070 merged' "$WAKE_LOG" || red "wake prompt missing the merged-PR line: $(cat "$WAKE_LOG")"
grep -q 'Issue #1071 closed' "$WAKE_LOG" || red "wake prompt missing the closed-issue line: $(cat "$WAKE_LOG")"
green "activity poll detected an out-of-band PR merge + issue close and woke the coordinator naming both"

WAKE_COUNT=$(grep -c 'WAKE:' "$WAKE_LOG")
[ "$WAKE_COUNT" = "1" ] || red "expected exactly ONE wake despite several poll ticks against the same static PR/issue (dedup maps should have suppressed the rest); got $WAKE_COUNT. wake.log:
$(cat "$WAKE_LOG")"
green "the same PR/issue across multiple poll ticks produced exactly one wake (ACTIVITY_ANNOUNCED_PR/_ISSUE dedup)"

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
heading "Test 2b: a merged PR whose worktree is still live is not announced (issue #392 self-review finding)"
# ============================================================================
# The gap this closes: a swarm-driven merge doesn't get a reap.window event
# until pr_poll_pass's own next tick (up to WATCH_PR_POLL_SECS later) — a
# still-live $WORKSPACE/wt-issue-<N> worktree is evidence pr_poll_pass just
# hasn't gotten to it yet, not that an operator merged it out-of-band. Real
# `git worktree add` (not a fake directory) so activity_worktree_still_
# live's own `-d` + `git worktree list` checks both see it, mirroring
# pr_poll_pass's own test fixtures.
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-3000 "$TEST_DIR/wt-issue-3000" >/dev/null
printf '3000\tStill being reaped\tfix/issue-3000\n' > "$PR_FIXTURE"
printf '3000\tStill being reaped\n' > "$ISSUE_FIXTURE"

start_watcher "$TEST_DIR/watch-2b.log" 1
sleep 3
stop_watcher
git -C "$PROJECT_DIR" worktree remove -f "$TEST_DIR/wt-issue-3000" >/dev/null 2>&1 || true

grep -q 'WAKE:' "$WAKE_LOG" && red "activity poll woke the coordinator over a PR/issue whose worktree is still live: $(cat "$WAKE_LOG")"
green "activity poll did not announce a PR/issue whose worktree still exists"
grep -q 'watch.activity_poll .*reason=skipped_worktree_live pr=3000 issue=3000' "$EVENTS_LOG" \
    || red "expected the merged-PR loop's skipped_worktree_live (pr=3000 issue=3000) in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'watch.activity_poll .*reason=skipped_worktree_live issue=3000$' "$EVENTS_LOG" \
    || red "expected the closed-issue loop's skipped_worktree_live (issue=3000, no pr=) in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
green "events.log records the skip as reason=skipped_worktree_live for both the merged PR and the closed issue"

# ============================================================================
heading "Test 2c: a PRUNABLE worktree (directory gone, git metadata not yet pruned) is NOT treated as still live (issue #392 self-review finding)"
# ============================================================================
# The exact gap self-review flagged: `git worktree list --porcelain` keeps
# listing an entry until `git worktree prune` runs, even after its
# directory is `rm -rf`'d directly (which is how kill-worktree.sh actually
# reaps one, and how provision-worker.sh's own docs describe manual
# cleanup) — is_own_worktree_dir alone (no `-d` check) would report this
# as "still live" and this poll would skip announcing a real out-of-band
# merge forever. activity_worktree_still_live's own `[ -d ]` check must
# catch this even though `git worktree list` still lists the path.
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-3100 "$TEST_DIR/wt-issue-3100" >/dev/null
rm -rf "$TEST_DIR/wt-issue-3100"
git -C "$PROJECT_DIR" worktree list --porcelain | grep -qF "$TEST_DIR/wt-issue-3100" \
    || red "test setup bug: expected git to still list the prunable worktree entry after rm -rf"
printf '3100\tPrunable worktree probe\tfix/issue-3100\n' > "$PR_FIXTURE"
: > "$ISSUE_FIXTURE"

start_watcher "$TEST_DIR/watch-2c.log" 1
sleep 3
stop_watcher
git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1 || true

grep -q 'WAKE:' "$WAKE_LOG" \
    || red "activity poll wrongly stayed silent on a PR whose worktree directory is gone (only git's prunable metadata remained). Watch log:
$(cat "$TEST_DIR/watch-2c.log")"
grep -q 'PR #3100 merged' "$WAKE_LOG" \
    || red "wake prompt missing the PR #3100 line: $(cat "$WAKE_LOG")"
green "a prunable (directory-gone) worktree entry does not silence the announcement"

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

# ============================================================================
heading "Test 5: COORD_WAKE_LOCK serializes on_activity against on_outcome (issue #392 self-review finding)"
# ============================================================================
# Before this issue, every NON_INTERACTIVE=1 "$LLM_START" call ran from the
# single main watcher process (on_outcome, on_message), so llm-start.sh's
# reprompt_inject — which pastes through one FIXED, otherwise-unlocked tmux
# buffer name — was implicitly serialized. on_activity breaks that: it runs
# from run_watch_timer_loop's own backgrounded subshell, a genuinely
# separate OS process, so a concurrent on_outcome wake and on_activity wake
# could both hit that buffer at once. This test doesn't spin up the real
# daemon (avoiding the outcome-detection backend entirely) — it extracts
# on_outcome/on_activity/log_event verbatim (sed, not a hand-retyped copy —
# same technique test-coordinator-auto-compact.sh uses for maybe_auto_compact)
# and fires them genuinely concurrently, each in its own subshell, against a
# deliberately slow LLM_START stub that records start/end timestamps —
# proving COORD_WAKE_LOCK keeps their two calls from overlapping in time.
extract_fn() {
    local fn="$1"
    sed -n "/^${fn}() {/,/^}/p" "$WATCH"
}
for fn in log_event on_outcome on_activity; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done
# on_outcome/on_activity both call maybe_auto_compact — stubbed to a no-op
# here since this test is only about the llm-start.sh serialization, not
# auto-compact behavior (which has its own dedicated test suite).
maybe_auto_compact() { :; }
# cleanup_eligible_workers is only reached when WATCHER_AUTOCLOSE=1 below;
# stubbed for the same reason (out of scope for this test).
cleanup_eligible_workers() { :; }

LOCK_TEST_DIR="$TEST_DIR/lock-test"
mkdir -p "$LOCK_TEST_DIR"
PROJECT_DIR="$LOCK_TEST_DIR"
EVENTS_LOG="$LOCK_TEST_DIR/events.log"
: > "$EVENTS_LOG"
COORD_WAKE_LOCK="$LOCK_TEST_DIR/coord-wake.lock"
COORD_WAKE_LOCK_TIMEOUT_SECS=10
DEBOUNCE_SECS=0
WATCHER_AUTOCLOSE=0
POST_OUTCOMES=0
DRY_RUN=0
ONCE=0
WAKE_PROMPT="outcome-wake-prompt"
ACTIVITY_WAKE_PROMPT="activity-wake-prompt"
LAST_WAKE=0
LAST_ACTIVITY_WAKE=0

CALL_TIMELINE="$LOCK_TEST_DIR/call-timeline.log"
: > "$CALL_TIMELINE"
LLM_START="$LOCK_TEST_DIR/fake-llm-start.sh"
cat > "$LLM_START" <<EOF
#!/usr/bin/env bash
printf 'START %s %s\n' "\$(date +%s%N)" "\$1" >> "$CALL_TIMELINE"
sleep 1
printf 'END   %s %s\n' "\$(date +%s%N)" "\$1" >> "$CALL_TIMELINE"
EOF
chmod +x "$LLM_START"

( on_outcome "$LOCK_TEST_DIR/wt-issue-42/.swarm/tasks/done/t42.ok.json" ) &
OUTCOME_PID=$!
( on_activity "PR #99 merged: concurrency probe" ) &
ACTIVITY_PID=$!
wait "$OUTCOME_PID" 2>/dev/null || true
wait "$ACTIVITY_PID" 2>/dev/null || true

[ "$(grep -c '^START' "$CALL_TIMELINE")" = "2" ] \
    || red "expected both on_outcome and on_activity to reach llm-start.sh; call timeline:
$(cat "$CALL_TIMELINE")"

# Parse the two [start,end] intervals (nanosecond epoch) and assert they do
# NOT overlap — i.e. one call's start is at/after the other's end. Matched
# by the wake-prompt label (3rd field), NOT by line position: with the lock
# NOT held, both START lines can land before either END line, and reading
# by fixed line number would silently pair a START with the WRONG call's
# line — exactly the bug an earlier version of this test had (it reported
# "no overlap" even with COORD_WAKE_LOCK's flock removed entirely).
start1=$(awk '$1=="START" && $3=="outcome-wake-prompt" {print $2}' "$CALL_TIMELINE")
end1=$(awk '$1=="END" && $3=="outcome-wake-prompt" {print $2}' "$CALL_TIMELINE")
start2=$(awk '$1=="START" && $3=="activity-wake-prompt" {print $2}' "$CALL_TIMELINE")
end2=$(awk '$1=="END" && $3=="activity-wake-prompt" {print $2}' "$CALL_TIMELINE")
[ -n "$start1" ] && [ -n "$end1" ] && [ -n "$start2" ] && [ -n "$end2" ] \
    || red "could not parse both calls' start/end timestamps from call timeline:
$(cat "$CALL_TIMELINE")"
if [ "$start2" -ge "$end1" ] || [ "$start1" -ge "$end2" ]; then
    green "on_outcome and on_activity's llm-start.sh calls did not overlap — COORD_WAKE_LOCK serialized them"
else
    red "on_outcome and on_activity's llm-start.sh calls OVERLAPPED — COORD_WAKE_LOCK did not serialize them. Timeline:
$(cat "$CALL_TIMELINE")"
fi

# ============================================================================
heading "Test 6: a debounced activity wake is retried on a later tick, not lost (issue #392 self-review finding)"
# ============================================================================
# activity_poll_pass only marks ACTIVITY_ANNOUNCED_PR/_ISSUE (and on_activity
# only advances LAST_ACTIVITY_WAKE) on a NON-debounced on_activity call
# (return 0) — marking them unconditionally, before checking whether
# on_activity actually woke anyone, would permanently drop an item that
# happened to land inside another wake's debounce window. Extracts
# activity_poll_pass/swarm_already_reaped/activity_worktree_still_live on
# top of the on_activity/log_event already extracted for Test 5 above, and
# drives it directly (not through the daemon) so the debounce timing is
# exact.
for fn in swarm_already_reaped activity_worktree_still_live activity_poll_pass; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done

PROJECT_DIR="$TEST_DIR/myproject"          # the original git-initialized repo, not lock-test's
WORKSPACE="$TEST_DIR"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
LLM_START="$FAKE_LLM_START"                # back to the "WAKE:"-into-$WAKE_LOG stub, not lock-test's
ACTIVITY_WAKE_PROMPT=""                    # so on_activity builds its default prompt (embeds $lines)
: > "$EVENTS_LOG"
: > "$WAKE_LOG"
declare -A ACTIVITY_ANNOUNCED_PR=()
declare -A ACTIVITY_ANNOUNCED_ISSUE=()
LAST_ACTIVITY_POLL_TS="1970-01-01T00:00:00Z"
ACTIVITY_POLL_OVERLAP_SECS=30
DEBOUNCE_SECS=2
printf '4000\tDebounce probe\tfix/issue-4000\n' > "$PR_FIXTURE"
: > "$ISSUE_FIXTURE"

# Simulate "another wake fired 1s ago" — well inside the 2s debounce window
# — so this call's on_activity is debounced (returns 1).
LAST_ACTIVITY_WAKE=$(( $(date +%s) - 1 ))
CURSOR_BEFORE="$LAST_ACTIVITY_POLL_TS"
activity_poll_pass
[ -z "${ACTIVITY_ANNOUNCED_PR[4000]:-}" ] \
    || red "PR 4000 was marked ACTIVITY_ANNOUNCED_PR despite its only on_activity call being debounced"
grep -q 'WAKE:' "$WAKE_LOG" \
    && red "coordinator was woken despite debounce; wake.log: $(cat "$WAKE_LOG")"
green "a debounced activity wake does NOT mark its items as announced"
# The critical check (issue #392 self-review, second finding): a real `gh`
# would stop returning PR 4000 once the cursor moves past its merge time,
# REGARDLESS of the ACTIVITY_ANNOUNCED_PR dedup map — so it's not enough to
# check the dedup map here, the cursor itself must not have moved. (An
# earlier version of this test only checked the dedup map + wake.log
# against a `gh` stub that ignores --search entirely, which made a broken
# fix look like it retried correctly — this is what actually proves it.)
[ "$LAST_ACTIVITY_POLL_TS" = "$CURSOR_BEFORE" ] \
    || red "LAST_ACTIVITY_POLL_TS advanced despite a debounced (unannounced) pending item — PR 4000 would be permanently unreachable by a real gh query. before=$CURSOR_BEFORE after=$LAST_ACTIVITY_POLL_TS"
green "the cursor did NOT advance past the debounced, still-unannounced PR"

# Let the debounce window clear, then retry with the SAME fixture — since
# it was never marked as announced above AND the cursor never moved past
# it, this call must still detect and announce it.
sleep 3
activity_poll_pass
grep -q 'WAKE:' "$WAKE_LOG" \
    || red "expected PR 4000 to be retried and woken once the debounce window cleared; wake.log:
$(cat "$WAKE_LOG")"
grep -q 'PR #4000 merged' "$WAKE_LOG" \
    || red "wake prompt missing the retried PR #4000 line: $(cat "$WAKE_LOG")"
[ -n "${ACTIVITY_ANNOUNCED_PR[4000]:-}" ] \
    || red "PR 4000 should now be marked ACTIVITY_ANNOUNCED_PR after a successful (non-debounced) wake"
[ "$LAST_ACTIVITY_POLL_TS" != "$CURSOR_BEFORE" ] \
    || red "cursor should have advanced past PR 4000's window once it was actually announced"
green "the same item is retried and announced once the debounce window clears, and the cursor advances only now — nothing was permanently lost"

# ============================================================================
heading "Test 7: a failed llm-start.sh call is retried too, not just a debounced one (issue #392 self-review finding)"
# ============================================================================
# Same shape as Test 6, but the wake path fails for a DIFFERENT reason: the
# lock is acquired fine and DEBOUNCE_SECS clears, but llm-start.sh itself
# exits non-zero (e.g. a COORD_WAKE_LOCK_TIMEOUT_SECS lock timeout, or a
# genuine llm-start.sh crash) — on_activity must still return 1 here, not
# fall through to a "success" return 0, or activity_poll_pass would mark
# the item as announced for a wake that never actually landed.
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
declare -A ACTIVITY_ANNOUNCED_PR=()
declare -A ACTIVITY_ANNOUNCED_ISSUE=()
LAST_ACTIVITY_POLL_TS="1970-01-01T00:00:00Z"
LAST_ACTIVITY_WAKE=0
DEBOUNCE_SECS=0
printf '5000\tFailed-wake probe\tfix/issue-5000\n' > "$PR_FIXTURE"
: > "$ISSUE_FIXTURE"

FAILING_LLM_START="$TEST_DIR/failing-llm-start.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILING_LLM_START"
chmod +x "$FAILING_LLM_START"
LLM_START="$FAILING_LLM_START"

CURSOR_BEFORE="$LAST_ACTIVITY_POLL_TS"
activity_poll_pass
[ -z "${ACTIVITY_ANNOUNCED_PR[5000]:-}" ] \
    || red "PR 5000 was marked ACTIVITY_ANNOUNCED_PR despite its llm-start.sh call failing"
green "a failed llm-start.sh call does NOT mark its items as announced"
# See Test 6's identical check for why this (not just the dedup map) is
# the check that actually proves nothing was lost against a real gh.
[ "$LAST_ACTIVITY_POLL_TS" = "$CURSOR_BEFORE" ] \
    || red "LAST_ACTIVITY_POLL_TS advanced despite a failed (unannounced) pending item — PR 5000 would be permanently unreachable by a real gh query. before=$CURSOR_BEFORE after=$LAST_ACTIVITY_POLL_TS"
green "the cursor did NOT advance past the failed, still-unannounced PR"

# Swap in a working LLM_START and retry with the SAME fixture — since it
# was never marked as announced above AND the cursor never moved past it,
# this call must still announce it.
LLM_START="$FAKE_LLM_START"
activity_poll_pass
grep -q 'WAKE:' "$WAKE_LOG" \
    || red "expected PR 5000 to be retried and woken once llm-start.sh started working; wake.log:
$(cat "$WAKE_LOG")"
grep -q 'PR #5000 merged' "$WAKE_LOG" \
    || red "wake prompt missing the retried PR #5000 line: $(cat "$WAKE_LOG")"
[ -n "${ACTIVITY_ANNOUNCED_PR[5000]:-}" ] \
    || red "PR 5000 should now be marked ACTIVITY_ANNOUNCED_PR after a successful wake"
[ "$LAST_ACTIVITY_POLL_TS" != "$CURSOR_BEFORE" ] \
    || red "cursor should have advanced past PR 5000's window once it was actually announced"
green "the same item is retried and announced once llm-start.sh succeeds, and the cursor advances only now — a wake failure didn't lose it either"

echo
green "All activity-poll tests passed."
