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
#
# (issue #430) on_activity no longer calls llm-start.sh at all — an
# activity-poll finding is now INBOX-ONLY: it's written straight to
# <project>/.swarm/coord-inbox/ with no accompanying doorbell/coord.wake,
# since it's never urgent enough to interrupt a coordinator turn. Every
# assertion below that used to check $WAKE_LOG for the finding now checks
# coord-inbox/*.md instead; $WAKE_LOG (and the FAKE_LLM_START stub) is kept
# only to assert the NEGATIVE — that llm-start.sh is never invoked for this
# path at all.
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

INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
inbox_files() { find "$INBOX_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null; }
inbox_count() { inbox_files | grep -c . || true; }

# ============================================================================
heading "Test 1: a merged PR + closed issue with no reap.window is recorded in the coordinator inbox (issue #430: inbox-only, no doorbell)"
# ============================================================================
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
rm -rf "$INBOX_DIR"
printf '1070\tFix the thing\tfix/issue-1070\n' > "$PR_FIXTURE"
printf '1071\tStale request\n' > "$ISSUE_FIXTURE"

start_watcher "$TEST_DIR/watch-1.log" 1
# poll_secs=1 over this 3s sleep fires several ticks against the SAME
# static fixture (the fake gh stub ignores --search entirely) — a real gh
# would naturally stop returning an already-past merge once the cursor
# moves on, but this stub can't emulate that filtering. The
# ACTIVITY_ANNOUNCED_PR/_ISSUE dedup maps are what keep repeated ticks from
# re-recording the same PR/issue (issue #392 self-review: without them,
# ACTIVITY_POLL_OVERLAP_SECS's cursor overlap alone would cause exactly
# this repeat-write bug) — asserted below via the inbox file count.
sleep 3
stop_watcher

FILES="$(inbox_files)"
[ -n "$FILES" ] || red "activity poll never wrote to the coordinator inbox. Watch log:
$(cat "$TEST_DIR/watch-1.log")"
grep -l 'PR #1070 merged' $FILES >/dev/null 2>&1 || red "inbox entry missing the merged-PR line"
grep -l 'Issue #1071 closed' $FILES >/dev/null 2>&1 || red "inbox entry missing the closed-issue line"
green "activity poll detected an out-of-band PR merge + issue close and recorded both in the coordinator inbox"

INBOX_COUNT=$(inbox_count)
[ "$INBOX_COUNT" = "1" ] || red "expected exactly ONE inbox entry despite several poll ticks against the same static PR/issue (dedup maps should have suppressed the rest); got $INBOX_COUNT"
green "the same PR/issue across multiple poll ticks produced exactly one inbox entry (ACTIVITY_ANNOUNCED_PR/_ISSUE dedup)"

grep -q 'WAKE:' "$WAKE_LOG" && red "issue #430: an activity-poll finding must never call llm-start.sh (inbox-only, no doorbell): $(cat "$WAKE_LOG")"
green "no llm-start.sh call was made for the activity-poll finding"

grep -q 'watch.activity_poll .*reason=detected' "$EVENTS_LOG" \
    || red "expected watch.activity_poll reason=detected in events.log; got:
$(cat "$EVENTS_LOG" 2>/dev/null || echo '(missing)')"
grep -q 'coord.inbox.write .*trigger=activity_poll' "$EVENTS_LOG" \
    || red "expected coord.inbox.write trigger=activity_poll in events.log"
grep -q 'coord.wake ' "$EVENTS_LOG" 2>/dev/null && red "issue #430: no coord.wake event should ever accompany an activity-poll finding: $(cat "$EVENTS_LOG")"
green "events.log records watch.activity_poll(reason=detected) + coord.inbox.write(trigger=activity_poll), never coord.wake"

# ============================================================================
heading "Test 2: a merged PR (and its same-numbered closed issue) already covered by this swarm's own reap.window is not re-announced"
# ============================================================================
# A merged PR with "Closes #N" auto-closes issue #N too — both the PR and
# issue fixtures use 2000 here to exercise BOTH dedup checks
# (swarm_already_reaped is applied to both the merged-PR loop and the
# closed-issue loop; see activity_poll_pass) with a single reap.window entry.
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
rm -rf "$INBOX_DIR"
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
[ "$(inbox_count)" = "0" ] || red "activity poll recorded a PR/issue in the inbox that this swarm's own pipeline already reaped: $(inbox_files)"
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
rm -rf "$INBOX_DIR"
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-3000 "$TEST_DIR/wt-issue-3000" >/dev/null
printf '3000\tStill being reaped\tfix/issue-3000\n' > "$PR_FIXTURE"
printf '3000\tStill being reaped\n' > "$ISSUE_FIXTURE"

start_watcher "$TEST_DIR/watch-2b.log" 1
sleep 3
stop_watcher
git -C "$PROJECT_DIR" worktree remove -f "$TEST_DIR/wt-issue-3000" >/dev/null 2>&1 || true

grep -q 'WAKE:' "$WAKE_LOG" && red "activity poll woke the coordinator over a PR/issue whose worktree is still live: $(cat "$WAKE_LOG")"
[ "$(inbox_count)" = "0" ] || red "activity poll recorded a PR/issue in the inbox whose worktree is still live: $(inbox_files)"
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
rm -rf "$INBOX_DIR"
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

FILES="$(inbox_files)"
[ -n "$FILES" ] \
    || red "activity poll wrongly stayed silent on a PR whose worktree directory is gone (only git's prunable metadata remained). Watch log:
$(cat "$TEST_DIR/watch-2c.log")"
grep -l 'PR #3100 merged' $FILES >/dev/null 2>&1 \
    || red "inbox entry missing the PR #3100 line"
green "a prunable (directory-gone) worktree entry does not silence the announcement"

# ============================================================================
heading "Test 3: WATCH_ACTIVITY_POLL_SECS=0 disables the poll entirely"
# ============================================================================
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
: > "$GH_CALL_LOG"
rm -rf "$INBOX_DIR"
printf '3000\tShould never be seen\tfix/issue-3000\n' > "$PR_FIXTURE"

start_watcher "$TEST_DIR/watch-3.log" 0
sleep 3
stop_watcher

grep -q '^pr list$' "$GH_CALL_LOG" && red "gh pr list was called despite WATCH_ACTIVITY_POLL_SECS=0: $(cat "$GH_CALL_LOG")"
grep -q 'WAKE:' "$WAKE_LOG" && red "coordinator was woken despite WATCH_ACTIVITY_POLL_SECS=0: $(cat "$WAKE_LOG")"
[ "$(inbox_count)" = "0" ] || red "coord-inbox got an entry despite WATCH_ACTIVITY_POLL_SECS=0: $(inbox_files)"
green "WATCH_ACTIVITY_POLL_SECS=0 disables activity_poll_pass entirely (no gh calls, no wake, no inbox write)"

# ============================================================================
heading "Test 4: a gh failure logs activity_poll.error and doesn't crash the daemon"
# ============================================================================
: > "$WAKE_LOG"
: > "$EVENTS_LOG"
rm -rf "$INBOX_DIR"
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
[ "$(inbox_count)" = "0" ] || red "coord-inbox got an entry despite the gh pr list failure: $(inbox_files)"
green "a gh pr list failure logs activity_poll.error, skips the wake/inbox-write, and leaves the daemon running"

# ============================================================================
heading "Test 5: COORD_WAKE_LOCK serializes on_outcome against coord_wake_hold_retry_pass (issue #430, successor to #392's on_activity pairing)"
# ============================================================================
# Before issue #430, on_activity was the OTHER process that could call
# llm-start.sh concurrently with on_outcome/on_message (it ran from
# run_watch_timer_loop's own backgrounded subshell, a genuinely separate OS
# process — see the old version of this test for the full history). #430
# makes on_activity inbox-only (it never calls llm-start.sh at all
# anymore — Test 1 above covers that), which retires that specific
# pairing — but does NOT retire the underlying race: coord_wake_busy_retry_
# pass (issue #430's busy-pane doorbell retry) now runs from that exact
# same backgrounded subshell and DOES call llm-start.sh, so the identical
# concern applies to the new pairing. This test extracts on_outcome/
# coord_wake_hold_retry_pass/coordinator_pane_busy/log_event verbatim (sed,
# not a hand-retyped copy — same technique test-coordinator-auto-compact.sh
# uses for maybe_auto_compact) and fires them genuinely concurrently, each
# in its own subshell, against a deliberately slow LLM_START stub that
# records start/end timestamps — proving COORD_WAKE_LOCK keeps their two
# calls from overlapping in time.
extract_fn() {
    local fn="$1"
    sed -n "/^${fn}() {/,/^}/p" "$WATCH"
}
for fn in log_event on_outcome outcome_path_issue outcome_path_task_id coord_wake_set_pending coord_wake_clear_pending \
          coord_inbox_write coord_inbox_count coord_inbox_nudge_text coord_inbox_nudge_pattern \
          coord_wake_hold_mark_pending coord_wake_hold_clear_pending coord_wake_hold_retry_pass \
          coord_wake_retry_pass coord_wake_already_submitted \
          coord_wake_hold_reason coord_human_present worker_human_present swarm_busy \
          human_typed_since transcript_dir_for watcher_paste_epochs coord_paste_epochs \
          wake_clock_get wake_clock_set wake_debounced \
          coordinator_pane_busy mtime_epoch; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done
# on_outcome calls maybe_auto_compact — stubbed to a no-op here since this
# test is only about the llm-start.sh serialization, not auto-compact
# behavior (which has its own dedicated test suite).
maybe_auto_compact() { :; }
# cleanup_eligible_workers is only reached when WATCHER_AUTOCLOSE=1 below;
# stubbed for the same reason (out of scope for this test).
cleanup_eligible_workers() { :; }
# on_outcome's retry-correction dedup (issue #468) keys this associative
# array; the watcher declares it at top level, which function extraction
# never copies — without the declare, bash treats the non-numeric task_id
# subscript arithmetically and the eval'd on_outcome dies under set -u.
declare -A OUTCOME_TASK_ANNOUNCED=()

LOCK_TEST_DIR="$TEST_DIR/lock-test"
mkdir -p "$LOCK_TEST_DIR"
PROJECT_DIR="$LOCK_TEST_DIR"
EVENTS_LOG="$LOCK_TEST_DIR/events.log"
: > "$EVENTS_LOG"
COORD_WAKE_LOCK="$LOCK_TEST_DIR/coord-wake.lock"
COORD_WAKE_LOCK_TIMEOUT_SECS=10
# issue #422: on_outcome's success path calls coord_wake_clear_pending
# (drops a stale deferred prompt once a fresh wake lands directly) — needs
# these two paths even though this test's fake LLM_START always exits 0,
# never exercising a pending prompt.
COORD_WAKE_PENDING_FILE="$LOCK_TEST_DIR/coord-wake-pending.prompt"
COORD_WAKE_PENDING_WARNED_FILE="$LOCK_TEST_DIR/coord-wake-pending.warned"
# issue #430: this test's busy-pane pairing needs its own pending marker
# and inbox dir; every hold gate is switched OFF below so on_outcome's own
# coord_wake_hold_reason check is a no-op (it always proceeds straight to
# llm-start.sh, exercising the exact same race the old on_outcome/on_activity
# pairing had) — the retry side of the race comes entirely from the
# separately invoked coord_wake_hold_retry_pass call below, which is
# unconditional.
COORD_WAKE_HOLD_PENDING_FILE="$LOCK_TEST_DIR/coord-wake-busy-pending"
COORD_WAKE_LAST_FILE="$LOCK_TEST_DIR/coord-wake-last"
COORD_WAKE_BUSY_RETRY_SECS=0
COORD_WAKE_BUSY_CEILING_SECS=900
# issue #459/#456: the rest of the hold vocabulary, all disabled here.
COORD_HUMAN_IDLE_SECS=0
WORKER_HUMAN_IDLE_SECS=0
# issue #497: coord_wake_already_submitted (now consulted unconditionally by
# both retry passes, ahead of every other gate) reads HAVE_JQ under this
# script's `set -u` — the real script always initializes it at boot, which
# this extracted-function harness never runs, so it must be set here too.
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
COORD_HUMAN_PASTE_GRACE_SECS=15
WORKER_HUMAN_PASTE_GRACE_SECS=15
WATCHER_PASTE_SCAN_LINES=2000
WAKE_DEFER_ON_SWARM_BUSY=0
DEBOUNCE_SECS=0
COORD_INBOX_DIR="$LOCK_TEST_DIR/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_NUDGE_TEMPLATE="Inbox: %N item(s) probe"
# coordinator_pane_busy needs these two even though there's no real tmux
# session behind SESSION_NAME here — its own `tmux capture-pane ... ||
# return 1` fails closed to "idle" the moment the session lookup itself
# fails, which is exactly the "idle" behavior this test wants from it, via
# the REAL function rather than a hand-written stub.
SESSION_NAME="test-inbox-lock-$$-nonexistent"
AUTO_COMPACT_BUSY_PATTERN='\(esc to interrupt\)|Press Ctrl-C again to .xit|Compacting conversation'
DEBOUNCE_SECS=0
WATCHER_AUTOCLOSE=0
POST_OUTCOMES=0
DRY_RUN=0
ONCE=0
WAKE_PROMPT="outcome-wake-prompt-probe"

CALL_TIMELINE="$LOCK_TEST_DIR/call-timeline.log"
: > "$CALL_TIMELINE"
LLM_START="$LOCK_TEST_DIR/fake-llm-start.sh"
cat > "$LLM_START" <<EOF
#!/usr/bin/env bash
printf 'START %s\n' "\$(date +%s%N)" >> "$CALL_TIMELINE"
sleep 1
printf 'END   %s\n' "\$(date +%s%N)" >> "$CALL_TIMELINE"
EOF
chmod +x "$LLM_START"

# Simulate "already held" for the retry side of the race. The marker's
# CONTENT is the hold reason since issue #459 — "pane_busy" here, matching
# what the pre-#459 empty marker always meant. A real hold is only ever
# raised after the triggering wake's own payload already landed in
# coord-inbox/ (issue #430's write-before-hold ordering) — issue #497's
# inbox_empty guard means an empty inbox here would make
# coord_wake_hold_retry_pass skip the paste outright, so give it one file to
# stay realistic to that ordering.
mkdir -p "$COORD_INBOX_DIR"
touch "$COORD_INBOX_DIR/probe.md"
printf 'pane_busy\n' > "$COORD_WAKE_HOLD_PENDING_FILE"

( on_outcome "$LOCK_TEST_DIR/wt-issue-42/.swarm/tasks/done/t42-42.ok.json" ) &
OUTCOME_PID=$!
( coord_wake_hold_retry_pass ) &
RETRY_PID=$!
wait "$OUTCOME_PID" 2>/dev/null || true
wait "$RETRY_PID" 2>/dev/null || true

[ "$(grep -c '^START' "$CALL_TIMELINE")" = "2" ] \
    || red "expected both on_outcome and coord_wake_hold_retry_pass to reach llm-start.sh; call timeline:
$(cat "$CALL_TIMELINE")"

# Both calls now paste the SAME generic inbox nudge (issue #430), so
# there's no per-call label left to match START/END pairs by (the old
# version of this test matched on a distinct wake-prompt string per call —
# see its history for why that mattered). Instead: sort ALL timestamped
# lines chronologically and assert they strictly alternate START,END,
# START,END — any overlap between the two calls would produce START,START,
# END,END (or an interleaving) instead.
sort -k2,2n "$CALL_TIMELINE" > "$CALL_TIMELINE.sorted"
mapfile -t TYPES < <(awk '{print $1}' "$CALL_TIMELINE.sorted")
if [ "${#TYPES[@]}" = "4" ] && [ "${TYPES[0]}" = "START" ] && [ "${TYPES[1]}" = "END" ] \
        && [ "${TYPES[2]}" = "START" ] && [ "${TYPES[3]}" = "END" ]; then
    green "on_outcome and coord_wake_hold_retry_pass's llm-start.sh calls did not overlap — COORD_WAKE_LOCK serialized them"
else
    red "on_outcome and coord_wake_hold_retry_pass's llm-start.sh calls OVERLAPPED — COORD_WAKE_LOCK did not serialize them. Timeline (sorted):
$(cat "$CALL_TIMELINE.sorted")"
fi

# ============================================================================
heading "Test 5b (issue #497): coord_wake_hold_retry_pass clears a pending hold without pasting once the inbox is empty"
# ============================================================================
# A held doorbell (pane_busy here, but the guard doesn't care which reason)
# whose coord-inbox has been fully triaged by the time the retry tick runs —
# every item it would have announced already handled some other way — has
# nothing left to paste. Reuses Test 5's extracted functions/env verbatim;
# resets only what this test itself needs to control.
: > "$CALL_TIMELINE"
: > "$EVENTS_LOG"
rm -rf "$COORD_INBOX_DIR"; mkdir -p "$COORD_INBOX_DIR"   # empty inbox
printf 'pane_busy\n' > "$COORD_WAKE_HOLD_PENDING_FILE"

coord_wake_hold_retry_pass

[ ! -e "$COORD_WAKE_HOLD_PENDING_FILE" ] \
    || red "COORD_WAKE_HOLD_PENDING_FILE should have been cleared by the inbox_empty guard"
grep -q '^START' "$CALL_TIMELINE" 2>/dev/null \
    && red "llm-start.sh must not be invoked when the inbox is empty; call timeline:
$(cat "$CALL_TIMELINE")"
grep -q 'coord\.wake\.skip reason=inbox_empty' "$EVENTS_LOG" \
    || red "expected coord.wake.skip reason=inbox_empty; events:
$(cat "$EVENTS_LOG")"
green "coord_wake_hold_retry_pass skips the paste and clears pending on an empty inbox (reason=inbox_empty)"

# Same guard, same outcome, on the OTHER retry pass (coord_wake_set_pending's
# dirty-composer path) — COORD_WAKE_PENDING_FILE, not the hold marker.
: > "$CALL_TIMELINE"
: > "$EVENTS_LOG"
printf 'outcome-wake-prompt-probe\n' > "$COORD_WAKE_PENDING_FILE"

coord_wake_retry_pass

[ ! -e "$COORD_WAKE_PENDING_FILE" ] \
    || red "COORD_WAKE_PENDING_FILE should have been cleared by the inbox_empty guard"
grep -q '^START' "$CALL_TIMELINE" 2>/dev/null \
    && red "llm-start.sh must not be invoked when the inbox is empty; call timeline:
$(cat "$CALL_TIMELINE")"
grep -q 'coord\.wake\.skip reason=inbox_empty' "$EVENTS_LOG" \
    || red "expected coord.wake.skip reason=inbox_empty; events:
$(cat "$EVENTS_LOG")"
green "coord_wake_retry_pass skips the paste and clears pending on an empty inbox (reason=inbox_empty)"

# ============================================================================
heading "Test 5c (issue #497): both retry passes clear pending, without pasting, once the operator already submitted the nudge themselves"
# ============================================================================
command -v jq >/dev/null 2>&1 || { yellow "jq not found — skipping Test 5c (coord_wake_already_submitted is inert without it)"; SKIP_5C=1; }
if [ "${SKIP_5C:-0}" != "1" ]; then
    # coord_wake_already_submitted derives the coordinator's transcript dir
    # from $HOME + $PROJECT_DIR via transcript_dir_for — point HOME at a
    # fixture tree and write one there, same technique
    # test-wake-presence-gate.sh uses for the daemon-level version of this.
    FIXTURE_HOME="$LOCK_TEST_DIR/home"
    FIXTURE_TRANSCRIPT_DIR="$FIXTURE_HOME/.claude/projects/$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
    mkdir -p "$FIXTURE_TRANSCRIPT_DIR"
    REAL_HOME="$HOME"
    HAVE_JQ=1
    HOME="$FIXTURE_HOME"

    : > "$CALL_TIMELINE"
    : > "$EVENTS_LOG"
    rm -f "$FIXTURE_TRANSCRIPT_DIR"/*.jsonl
    mkdir -p "$COORD_INBOX_DIR"
    touch "$COORD_INBOX_DIR/probe.md"   # non-empty, so the inbox_empty guard above doesn't fire first
    printf 'pane_busy\n' > "$COORD_WAKE_HOLD_PENDING_FILE"
    PENDING_MTIME=$(mtime_epoch "$COORD_WAKE_HOLD_PENDING_FILE")

    # A typed turn, timestamped AFTER the pending marker, that CONTAINS the
    # rendered nudge line alongside the operator's own text — exactly the
    # "finished the draft the paste landed in, then hit Enter" case.
    SUBMIT_TS="$(date -u -d "@$((PENDING_MTIME + 5))" +%Y-%m-%dT%H:%M:%S.000Z)"
    jq -cn --arg ts "$SUBMIT_TS" \
        --arg text "$(printf 'Inbox: 3 item(s) probe\n\nand also please rebase PR 512')" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        >> "$FIXTURE_TRANSCRIPT_DIR/session.jsonl"
    touch -d "@$((PENDING_MTIME + 10))" "$FIXTURE_TRANSCRIPT_DIR/session.jsonl"

    coord_wake_hold_retry_pass

    [ ! -e "$COORD_WAKE_HOLD_PENDING_FILE" ] \
        || red "COORD_WAKE_HOLD_PENDING_FILE should have been cleared by the already_submitted guard"
    grep -q '^START' "$CALL_TIMELINE" 2>/dev/null \
        && red "llm-start.sh must not be invoked once the operator already submitted the nudge; call timeline:
$(cat "$CALL_TIMELINE")"
    grep -q 'coord\.wake\.skip reason=already_submitted' "$EVENTS_LOG" \
        || red "expected coord.wake.skip reason=already_submitted; events:
$(cat "$EVENTS_LOG")"
    green "coord_wake_hold_retry_pass skips the paste and clears pending once the operator's own submitted turn already carries the nudge"

    # Same fixture, same outcome, on the dirty-composer retry pass.
    : > "$CALL_TIMELINE"
    : > "$EVENTS_LOG"
    printf 'outcome-wake-prompt-probe\n' > "$COORD_WAKE_PENDING_FILE"
    PENDING_MTIME=$(mtime_epoch "$COORD_WAKE_PENDING_FILE")
    SUBMIT_TS="$(date -u -d "@$((PENDING_MTIME + 5))" +%Y-%m-%dT%H:%M:%S.000Z)"
    rm -f "$FIXTURE_TRANSCRIPT_DIR"/*.jsonl
    jq -cn --arg ts "$SUBMIT_TS" \
        --arg text "$(printf 'Inbox: 3 item(s) probe\n\nand also please rebase PR 512')" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        >> "$FIXTURE_TRANSCRIPT_DIR/session.jsonl"
    touch -d "@$((PENDING_MTIME + 10))" "$FIXTURE_TRANSCRIPT_DIR/session.jsonl"

    coord_wake_retry_pass

    [ ! -e "$COORD_WAKE_PENDING_FILE" ] \
        || red "COORD_WAKE_PENDING_FILE should have been cleared by the already_submitted guard"
    grep -q '^START' "$CALL_TIMELINE" 2>/dev/null \
        && red "llm-start.sh must not be invoked once the operator already submitted the nudge; call timeline:
$(cat "$CALL_TIMELINE")"
    grep -q 'coord\.wake\.skip reason=already_submitted' "$EVENTS_LOG" \
        || red "expected coord.wake.skip reason=already_submitted; events:
$(cat "$EVENTS_LOG")"
    green "coord_wake_retry_pass skips the paste and clears pending once the operator's own submitted turn already carries the nudge"

    HOME="$REAL_HOME"
fi

# ============================================================================
heading "Test 5d (issue #497 self-review finding): coord_wake_already_submitted does not fire when a NEWER inbox item arrived after the operator's confirming turn"
# ============================================================================
command -v jq >/dev/null 2>&1 || { yellow "jq not found — skipping Test 5d (coord_wake_already_submitted is inert without it)"; SKIP_5D=1; }
if [ "${SKIP_5D:-0}" != "1" ]; then
    FIXTURE_HOME="$LOCK_TEST_DIR/home5d"
    FIXTURE_TRANSCRIPT_DIR="$FIXTURE_HOME/.claude/projects/$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
    mkdir -p "$FIXTURE_TRANSCRIPT_DIR"
    REAL_HOME="$HOME"
    HAVE_JQ=1
    HOME="$FIXTURE_HOME"

    SINCE=$(date +%s)
    TURN_EPOCH=$((SINCE + 5))
    SUBMIT_TS="$(date -u -d "@$TURN_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
    jq -cn --arg ts "$SUBMIT_TS" \
        --arg text "$(printf 'Inbox: 1 item(s) probe\n\nthanks, already looked at that one')" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        > "$FIXTURE_TRANSCRIPT_DIR/session.jsonl"
    touch -d "@$((TURN_EPOCH + 5))" "$FIXTURE_TRANSCRIPT_DIR/session.jsonl"

    # A coord-inbox payload that arrived AFTER the operator's confirming
    # turn: genuinely new work the operator has not acknowledged, even
    # though an older turn already contains the (count-agnostic) nudge
    # text. Must NOT be swept into already_submitted.
    rm -rf "$COORD_INBOX_DIR"
    mkdir -p "$COORD_INBOX_DIR"
    touch -d "@$((TURN_EPOCH + 20))" "$COORD_INBOX_DIR/newer-than-turn.md"

    if coord_wake_already_submitted "$SINCE"; then
        red "coord_wake_already_submitted must not fire: a coord-inbox item arrived after the operator's confirming turn"
    fi
    green "coord_wake_already_submitted stays false open when a newer coord-inbox item postdates the confirming turn"

    # Sanity check the other direction: once every current inbox file
    # predates the confirming turn, the same fixture DOES count as
    # already-submitted (the case Test 5c exercises end-to-end).
    rm -rf "$COORD_INBOX_DIR"
    mkdir -p "$COORD_INBOX_DIR"
    touch -d "@$((TURN_EPOCH - 5))" "$COORD_INBOX_DIR/older-than-turn.md"
    coord_wake_already_submitted "$SINCE" \
        || red "coord_wake_already_submitted should fire once every current inbox item predates the confirming turn"
    green "coord_wake_already_submitted still fires once the confirming turn covers every current inbox item"

    HOME="$REAL_HOME"
fi

# ============================================================================
heading "Test 5e (issue #497 self-review finding): a worker's initial brief (worker.start) is excluded from human_typed_since via the paste-grace window"
# ============================================================================
command -v jq >/dev/null 2>&1 || { yellow "jq not found — skipping Test 5e (human_typed_since's jq path is inert without it)"; SKIP_5E=1; }
if [ "${SKIP_5E:-0}" != "1" ]; then
    FIXTURE_TDIR5E="$LOCK_TEST_DIR/worker-transcript-5e"
    mkdir -p "$FIXTURE_TDIR5E"

    # Before this issue's COORD_HUMAN_MAX_TYPED_CHARS removal, a long
    # machine-pasted brief was (accidentally) excluded by its length alone.
    # Dropping that cutoff means watcher_paste_epochs' worker.start entry is
    # now the ONLY thing standing between a freshly spawned worker's own
    # brief and a false "human present" read.
    : > "$EVENTS_LOG"
    log_event worker.start "issue=999 task_id=t999 window=iss-999 alive=1/5 total_windows=1/10"
    WSTART_EPOCH=$(date +%s)
    CUTOFF=$((WSTART_EPOCH - 5))

    BRIEF_EPOCH=$((WSTART_EPOCH + 2))
    BRIEF_TS="$(date -u -d "@$BRIEF_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
    LONG_BRIEF="$(head -c 4000 < /dev/zero | tr '\0' 'x')"
    jq -cn --arg ts "$BRIEF_TS" --arg text "## Task

$LONG_BRIEF" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        > "$FIXTURE_TDIR5E/session.jsonl"

    PASTES="$(watcher_paste_epochs)"
    if human_typed_since "$FIXTURE_TDIR5E" "$CUTOFF" "$PASTES" "$WORKER_HUMAN_PASTE_GRACE_SECS"; then
        red "a freshly spawned worker's own initial brief must not read as a human turn — worker.start is missing from watcher_paste_epochs' pattern"
    fi
    green "a worker's initial brief lands inside the paste-grace window around its own worker.start event and is correctly excluded, not misread as human"

    # Contrast: a genuine operator reply in that SAME worker pane, well
    # outside the paste-grace window, must still count as human — this
    # fix must not blanket-exclude everything near a worker.start event.
    REPLY_EPOCH=$((WSTART_EPOCH + WORKER_HUMAN_PASTE_GRACE_SECS + 30))
    REPLY_TS="$(date -u -d "@$REPLY_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
    jq -cn --arg ts "$REPLY_TS" --arg text "actually let's take a different approach here" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        >> "$FIXTURE_TDIR5E/session.jsonl"
    human_typed_since "$FIXTURE_TDIR5E" "$CUTOFF" "$PASTES" "$WORKER_HUMAN_PASTE_GRACE_SECS" \
        || red "a genuine operator reply well outside the paste-grace window must still count as human"
    green "a genuine operator reply in the same worker pane still counts as human once outside the paste-grace window"
fi

# ============================================================================
heading "Test 5f (issue #497 self-review finding): a slow worker spawn (brief lands 22s after worker.start, this project's own observed worst case) is still excluded at the production default"
# ============================================================================
if [ "${SKIP_5E:-0}" != "1" ]; then
    # This test alone runs at the real production default (45s), not this
    # file's 15s override for every other test, to prove the wider window
    # self-review's live-log finding motivated actually covers the worst
    # case it found.
    SAVED_GRACE="$WORKER_HUMAN_PASTE_GRACE_SECS"
    WORKER_HUMAN_PASTE_GRACE_SECS=45

    FIXTURE_TDIR5F="$LOCK_TEST_DIR/worker-transcript-5f"
    mkdir -p "$FIXTURE_TDIR5F"
    : > "$EVENTS_LOG"
    log_event worker.start "issue=998 task_id=t998 window=iss-998 alive=1/5 total_windows=1/10"
    WSTART_EPOCH=$(date +%s)
    CUTOFF=$((WSTART_EPOCH - 5))

    SLOW_BRIEF_EPOCH=$((WSTART_EPOCH + 22))
    SLOW_BRIEF_TS="$(date -u -d "@$SLOW_BRIEF_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
    jq -cn --arg ts "$SLOW_BRIEF_TS" --arg text "## Task

$(head -c 4000 < /dev/zero | tr '\0' 'x')" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        > "$FIXTURE_TDIR5F/session.jsonl"

    PASTES="$(watcher_paste_epochs)"
    if human_typed_since "$FIXTURE_TDIR5F" "$CUTOFF" "$PASTES" "$WORKER_HUMAN_PASTE_GRACE_SECS"; then
        red "a 22s-delayed worker brief must still be excluded at the production 45s default (this repo's own observed worst case)"
    fi
    green "a 22s-delayed worker brief (this project's own observed worst case) is still excluded at the production 45s default"

    WORKER_HUMAN_PASTE_GRACE_SECS="$SAVED_GRACE"
fi

# ============================================================================
heading "Test 5g (issue #497 self-review finding, round 7): a worker spawn must not excuse a genuine operator turn in the COORDINATOR's own transcript"
# ============================================================================
# human_typed_since's paste-grace exclusion is pure timestamp proximity, no
# text check — so before coord_human_present had its own coord_paste_epochs,
# it shared worker_human_present's full list (including worker.start), and a
# worker spawn is typically the direct, near-immediate result of an operator
# turn in the coordinator's own transcript. Proves that fix: a real operator
# reply landing seconds after a worker.start still reads as human when
# checked via coord_human_present, even though the identical scenario
# correctly excludes the WORKER's own brief via worker_human_present (5e).
command -v jq >/dev/null 2>&1 || { yellow "jq not found — skipping Test 5g (needs jq fixtures)"; SKIP_5G=1; }
if [ "${SKIP_5G:-0}" != "1" ]; then
    FIXTURE_HOME5G="$LOCK_TEST_DIR/home5g"
    FIXTURE_COORD_TDIR="$FIXTURE_HOME5G/.claude/projects/$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
    mkdir -p "$FIXTURE_COORD_TDIR"
    REAL_HOME="$HOME"
    HAVE_JQ=1
    HOME="$FIXTURE_HOME5G"

    : > "$EVENTS_LOG"
    log_event worker.start "issue=997 task_id=t997 window=iss-997 alive=1/5 total_windows=1/10"
    WSTART_EPOCH=$(date +%s)

    # A genuine, short operator reply in the COORDINATOR's own transcript,
    # 5s after the worker.start this same operator turn presumably caused —
    # well within COORD_HUMAN_PASTE_GRACE_SECS, and nothing like the nudge
    # or wake-prompt text.
    REPLY_EPOCH=$((WSTART_EPOCH + 5))
    REPLY_TS="$(date -u -d "@$REPLY_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
    jq -cn --arg ts "$REPLY_TS" --arg text "sounds good, go ahead and also check the flaky test while you're at it" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        > "$FIXTURE_COORD_TDIR/session.jsonl"

    SAVED_COORD_HUMAN_IDLE_SECS="$COORD_HUMAN_IDLE_SECS"
    COORD_HUMAN_IDLE_SECS=600
    coord_human_present \
        || red "a genuine operator reply in the coordinator's own transcript, seconds after an unrelated worker.start, must still count as human present — coord_human_present wrongly excluded it"
    COORD_HUMAN_IDLE_SECS="$SAVED_COORD_HUMAN_IDLE_SECS"
    green "a worker spawn no longer excuses a genuine operator turn in the coordinator's own transcript"

    # Contrast: the SAME worker.start, checked the worker-side way, still
    # correctly excludes that worker's own brief (regression guard for 5e —
    # confirms the split didn't just move the bug, it scoped it correctly).
    FIXTURE_WORKER_TDIR5G="$LOCK_TEST_DIR/worker-transcript-5g"
    mkdir -p "$FIXTURE_WORKER_TDIR5G"
    BRIEF_EPOCH=$((WSTART_EPOCH + 2))
    BRIEF_TS="$(date -u -d "@$BRIEF_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
    jq -cn --arg ts "$BRIEF_TS" --arg text "## Task

$(head -c 4000 < /dev/zero | tr '\0' 'x')" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        > "$FIXTURE_WORKER_TDIR5G/session.jsonl"
    PASTES="$(watcher_paste_epochs)"
    if human_typed_since "$FIXTURE_WORKER_TDIR5G" "$((WSTART_EPOCH - 5))" "$PASTES" "$WORKER_HUMAN_PASTE_GRACE_SECS"; then
        red "the worker's own brief must still be excluded via the full watcher_paste_epochs list — the coord-side fix must not have broken the worker-side one"
    fi
    green "the worker-side exclusion (worker_human_present's own path) is untouched by the coordinator-side fix"

    HOME="$REAL_HOME"
fi

# ============================================================================
heading "Test 5h (issue #497 self-review finding, round 10): the coordinator's own paste-grace window stays tight (15s), not the worker-spawn width (45s)"
# ============================================================================
# Before this fix, COORD_HUMAN_PASTE_GRACE_SECS and the worker-spawn-latency
# window were the SAME constant — widening it to 45s for worker spawns (5f)
# also widened the coordinator's own doorbell-paste correlation, even though
# a coord.wake paste is near-instant and never needed widening. A genuine
# operator reply 15-45s after their own just-delivered doorbell is a normal
# human timescale, not an edge case, so this directly proves the split:
# the SAME reply reads as human at the real 15s coordinator default, but
# would have wrongly read as machine at the old shared 45s width.
command -v jq >/dev/null 2>&1 || { yellow "jq not found — skipping Test 5h (needs jq fixtures)"; SKIP_5H=1; }
if [ "${SKIP_5H:-0}" != "1" ]; then
    FIXTURE_HOME5H="$LOCK_TEST_DIR/home5h"
    FIXTURE_COORD_TDIR5H="$FIXTURE_HOME5H/.claude/projects/$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
    mkdir -p "$FIXTURE_COORD_TDIR5H"
    REAL_HOME="$HOME"
    HAVE_JQ=1
    HOME="$FIXTURE_HOME5H"

    : > "$EVENTS_LOG"
    log_event coord.wake "reason=probe"
    WAKE_EPOCH=$(date +%s)

    # A genuine operator reply 30s later: outside the real 15s coordinator
    # window, but inside the old shared 45s one.
    REPLY_EPOCH=$((WAKE_EPOCH + 30))
    REPLY_TS="$(date -u -d "@$REPLY_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)"
    jq -cn --arg ts "$REPLY_TS" --arg text "thanks, that makes sense — go ahead and merge it" \
        '{type:"user", timestamp:$ts, promptSource:"typed", origin:{kind:"human"}, message:{role:"user", content:$text}}' \
        > "$FIXTURE_COORD_TDIR5H/session.jsonl"

    SAVED_COORD_HUMAN_IDLE_SECS="$COORD_HUMAN_IDLE_SECS"
    COORD_HUMAN_IDLE_SECS=600

    coord_human_present \
        || red "a 30s-later genuine operator reply must count as human at the real 15s coordinator paste-grace default"
    green "a 30s-later operator reply correctly counts as human at the real 15s coordinator default"

    # Contrast: at the OLD shared 45s width, the exact same reply would have
    # been wrongly excluded — proves this test actually discriminates
    # between the fixed and unfixed behavior, not just trivially passing.
    SAVED_COORD_GRACE="$COORD_HUMAN_PASTE_GRACE_SECS"
    COORD_HUMAN_PASTE_GRACE_SECS=45
    if coord_human_present; then
        red "test fixture error: expected the old 45s-wide window to wrongly exclude this reply (if it didn't, this test proves nothing)"
    fi
    COORD_HUMAN_PASTE_GRACE_SECS="$SAVED_COORD_GRACE"
    green "confirmed: the same reply would have been wrongly excluded at the old, unsplit 45s width — the split is what fixes it"

    COORD_HUMAN_IDLE_SECS="$SAVED_COORD_HUMAN_IDLE_SECS"
    HOME="$REAL_HOME"
fi

# ============================================================================
heading "Test 6: a debounced activity finding is retried on a later tick, not lost (issue #392 self-review finding, now via the coordinator inbox)"
# ============================================================================
# activity_poll_pass only marks ACTIVITY_ANNOUNCED_PR/_ISSUE (and
# on_activity only advances LAST_ACTIVITY_WAKE) on a NON-debounced
# on_activity call (return 0) — marking them unconditionally, before
# checking whether on_activity actually recorded anything, would
# permanently drop an item that happened to land inside another finding's
# debounce window. Extracts activity_poll_pass/swarm_already_reaped/
# activity_worktree_still_live/on_activity/coord_inbox_write on top of the
# log_event already extracted for Test 5 above, and drives it directly
# (not through the daemon) so the debounce timing is exact.
for fn in swarm_already_reaped activity_worktree_still_live activity_poll_pass on_activity; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done

PROJECT_DIR="$TEST_DIR/myproject"          # the original git-initialized repo, not lock-test's
WORKSPACE="$TEST_DIR"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
ACTIVITY_WAKE_PROMPT=""                    # so on_activity builds its default body (embeds $lines)
: > "$EVENTS_LOG"
rm -rf "$COORD_INBOX_DIR"
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
[ "$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | grep -c .)" = "0" ] \
    || red "a debounced activity finding must not write to the coordinator inbox"
green "a debounced activity finding does NOT mark its items as announced, and writes nothing to the inbox"
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
# it, this call must still detect and record it.
sleep 3
activity_poll_pass
FILES="$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null)"
[ -n "$FILES" ] \
    || red "expected PR 4000 to be retried and recorded once the debounce window cleared"
grep -l 'PR #4000 merged' $FILES >/dev/null 2>&1 \
    || red "inbox entry missing the retried PR #4000 line"
[ -n "${ACTIVITY_ANNOUNCED_PR[4000]:-}" ] \
    || red "PR 4000 should now be marked ACTIVITY_ANNOUNCED_PR after a successful (non-debounced) wake"
[ "$LAST_ACTIVITY_POLL_TS" != "$CURSOR_BEFORE" ] \
    || red "cursor should have advanced past PR 4000's window once it was actually announced"
green "the same item is retried and recorded once the debounce window clears, and the cursor advances only now — nothing was permanently lost"

# ============================================================================
heading "Test 7: a failed coord-inbox write is retried too, not just a debounced one (issue #392 self-review finding, now via the coordinator inbox)"
# ============================================================================
# Same shape as Test 6, but the write fails for a DIFFERENT reason: the
# lock/debounce clears fine, but coord_inbox_write itself fails (e.g. a
# permissions problem, or here, a plain FILE sitting where the inbox dir
# needs to go so mkdir -p/mktemp can't create it) — on_activity must still
# return 1 here, not fall through to a "success" return 0, or
# activity_poll_pass would mark the item as announced for a write that
# never actually landed.
: > "$EVENTS_LOG"
declare -A ACTIVITY_ANNOUNCED_PR=()
declare -A ACTIVITY_ANNOUNCED_ISSUE=()
LAST_ACTIVITY_POLL_TS="1970-01-01T00:00:00Z"
LAST_ACTIVITY_WAKE=0
DEBOUNCE_SECS=0
printf '5000\tFailed-write probe\tfix/issue-5000\n' > "$PR_FIXTURE"
: > "$ISSUE_FIXTURE"

rm -rf "$COORD_INBOX_DIR"
touch "$COORD_INBOX_DIR"   # a FILE where the inbox dir must go — mkdir -p/mktemp fail deterministically

CURSOR_BEFORE="$LAST_ACTIVITY_POLL_TS"
activity_poll_pass
[ -z "${ACTIVITY_ANNOUNCED_PR[5000]:-}" ] \
    || red "PR 5000 was marked ACTIVITY_ANNOUNCED_PR despite its inbox write failing"
green "a failed coord-inbox write does NOT mark its items as announced"
# See Test 6's identical check for why this (not just the dedup map) is
# the check that actually proves nothing was lost against a real gh.
[ "$LAST_ACTIVITY_POLL_TS" = "$CURSOR_BEFORE" ] \
    || red "LAST_ACTIVITY_POLL_TS advanced despite a failed (unannounced) pending item — PR 5000 would be permanently unreachable by a real gh query. before=$CURSOR_BEFORE after=$LAST_ACTIVITY_POLL_TS"
green "the cursor did NOT advance past the failed, still-unannounced PR"

# Clear the blocker and retry with the SAME fixture — since it was never
# marked as announced above AND the cursor never moved past it, this call
# must still record it.
rm -f "$COORD_INBOX_DIR"
activity_poll_pass
FILES="$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null)"
[ -n "$FILES" ] \
    || red "expected PR 5000 to be retried and recorded once the inbox write started working"
grep -l 'PR #5000 merged' $FILES >/dev/null 2>&1 \
    || red "inbox entry missing the retried PR #5000 line"
[ -n "${ACTIVITY_ANNOUNCED_PR[5000]:-}" ] \
    || red "PR 5000 should now be marked ACTIVITY_ANNOUNCED_PR after a successful write"
[ "$LAST_ACTIVITY_POLL_TS" != "$CURSOR_BEFORE" ] \
    || red "cursor should have advanced past PR 5000's window once it was actually announced"
green "the same item is retried and recorded once the inbox write succeeds, and the cursor advances only now — a write failure didn't lose it either"

echo
green "All activity-poll tests passed."
