#!/usr/bin/env bash
#
# test-shape-check-reuse.sh — issue #579: worker-listener.sh's post-dispatch
# run_check() must reuse a check-on-done result (coordinator-watch.sh's
# execute_check) already recorded for the same task_id against the same
# commit, instead of running a second, redundant $CHECK_CMD in the same
# worktree.
#
# No coordinator-watch.sh process is driven here — each test stands in for
# "the watcher already ran the check and won the race" by writing the exact
# artifacts maybe_run_check()/execute_check() would have left behind
# (.swarm/tasks/status/<task_id>.check.json, .swarm/tasks/done/<task_id>.check.log,
# and — for the in-flight case — .swarm/tasks/status/<task_id>.check-claim/)
# directly into the worktree, the same way test-worker-close-defers-active-check.sh
# stands in for an active check-claim. Covers the issue's five acceptance
# criteria:
#   1. recorded pass, same task+HEAD  → reused, no second run, worker.check.reused logged
#   2. recorded fail, same task+HEAD  → reused fail drives retry-once same as a fresh fail
#   3. still "checking" (in flight)   → listener waits, then reuses, never double-runs
#   4. HEAD mismatch (new commit)     → runs fresh, ignores the stale record
#   5. no check.json at all           → unchanged behavior (today's path)
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

command -v jq >/dev/null 2>&1 || red "jq required for outcome JSON validation"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t shape-check-reuse-XXXXXX)
LISTENER_PIDS=()
cleanup() {
    for pid in "${LISTENER_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
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

drop_v2() {
    local dir="$1" task_id="$2" body="$3"
    local tmp
    tmp=$(mktemp -p "$dir/.swarm/tasks/inbox" .tmp.XXXX.md)
    printf '%s\n' "$body" > "$tmp"
    mv "$tmp" "$dir/.swarm/tasks/inbox/$task_id.md"
}

# new_worktree <dir> — a real git repo (worker-listener.sh needs `git
# rev-parse HEAD` to resolve to something real for the HEAD-match check) at
# its first commit. Echoes that commit's sha.
new_worktree() {
    local dir="$1"
    mkdir -p "$dir/.swarm/tasks/inbox" "$dir/.swarm/tasks/processing" \
             "$dir/.swarm/tasks/done" "$dir/.swarm/tasks/status"
    git -C "$dir" init -q
    git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    git -C "$dir" rev-parse HEAD
}

# stub_check_json <dir> <task_id> <state> <check_exit|null> <head_sha>
stub_check_json() {
    local dir="$1" task_id="$2" state="$3" check_exit="$4" head_sha="$5"
    printf '{"task_id":"%s","state":"%s","check_exit":%s,"head_sha":"%s","ts":"%s"}\n' \
        "$task_id" "$state" "$check_exit" "$head_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$dir/.swarm/tasks/status/$task_id.check.json"
}

start_listener() {   # $1 = dir; rest = env VAR=VAL pairs
    local dir="$1"; shift
    ( cd "$dir" && env WORKER_HEADLESS=1 "$@" "$LISTENER" bash > listener.log 2>&1 ) &
    LISTENER_PIDS+=($!)
    sleep 0.5
}

heading "Shape test: check-on-done reuse (issue #579)"
echo "test dir: $TEST_DIR"

# ============================================================================
heading "Test 1: recorded pass, same task_id + HEAD → reused, no second run"
# ============================================================================
WT1="$TEST_DIR/wt-1"
HEAD1="$(new_worktree "$WT1")"
# Marker command would, if actually run, append to ran.txt — asserting it
# never gets written is the proof the second run never happened.
stub_check_json "$WT1" c1 pass 0 "$HEAD1"
printf 'issue #579 check-on-done: already ran this commit, already passed\n' \
    > "$WT1/.swarm/tasks/done/c1.check.log"
start_listener "$WT1"
drop_v2 "$WT1" c1 'echo agent-ran > t1.txt
# <!-- SWARM_CHECK: echo ran >> ran.txt -->'
wait_for "c1 outcome" "[ -f '$WT1/.swarm/tasks/done/c1.ok.json' ]"
[ ! -f "$WT1/ran.txt" ] || red "c1: CHECK_CMD ran a second time — the reused pass should have skipped it entirely"
jq -e '.outcome == "ok" and .check_exit == 0 and .verification == "passed"' \
    "$WT1/.swarm/tasks/done/c1.ok.json" >/dev/null \
    || { cat "$WT1/.swarm/tasks/done/c1.ok.json"; red "c1: outcome JSON wrong"; }
grep -q "worker.check.reused" "$WT1/listener.log" \
    || red "c1: expected worker.check.reused in the listener's own log; got:
$(cat "$WT1/listener.log")"
green "recorded pass is reused: no second CHECK_CMD run, check_exit 0, verification passed, worker.check.reused logged"

# ============================================================================
heading "Test 2: recorded fail, same task_id + HEAD → reused fail drives retry-once"
# ============================================================================
WT2="$TEST_DIR/wt-2"
HEAD2="$(new_worktree "$WT2")"
stub_check_json "$WT2" c2 fail 7 "$HEAD2"
printf 'issue #579 check-on-done: already ran this commit, already FAILED\nsome failure detail\n' \
    > "$WT2/.swarm/tasks/done/c2.check.log"
start_listener "$WT2"
# The retry (second dispatch) appends a second line, which the marker needs
# to pass — proves the reused fail triggered the SAME retry-once machinery
# a fresh fail would, with no second run of the check on attempt 1.
drop_v2 "$WT2" c2 'echo try >> attempts.txt
# <!-- SWARM_CHECK: test "$(wc -l < attempts.txt)" -ge 2 -->'
wait_for "c2 outcome" "[ -f '$WT2/.swarm/tasks/done/c2.ok.json' ]"
jq -e '.outcome == "ok" and .check_exit == 0 and .retried == true' \
    "$WT2/.swarm/tasks/done/c2.ok.json" >/dev/null \
    || { cat "$WT2/.swarm/tasks/done/c2.ok.json"; red "c2: reused fail did not drive retry-once to a passing outcome"; }
[ "$(wc -l < "$WT2/attempts.txt")" -eq 2 ] || red "c2: expected exactly one retry dispatch (2 attempts total)"
[ -f "$WT2/.swarm/tasks/done/c2.check.attempt1.log" ] \
    || red "c2: attempt1 check log should be the reused check-on-done log, archived same as a fresh fail"
grep -q "worker.check.reused" "$WT2/listener.log" \
    || red "c2: expected worker.check.reused in the listener's own log"
green "recorded fail is reused and still drives retry-once exactly like a fresh fail"

# ============================================================================
heading "Test 3: still checking (in flight) → listener waits, then reuses"
# ============================================================================
WT3="$TEST_DIR/wt-3"
HEAD3="$(new_worktree "$WT3")"
stub_check_json "$WT3" c3 checking null "$HEAD3"
mkdir -p "$WT3/.swarm/tasks/status/c3.check-claim"
start_listener "$WT3"
drop_v2 "$WT3" c3 'echo agent-ran > t3.txt
# <!-- SWARM_CHECK: echo ran >> ran3.txt -->'
# Give the listener a moment to reach its wait loop before resolving the
# in-flight check — proves it actually waited rather than racing past.
sleep 2
[ ! -f "$WT3/.swarm/tasks/done/c3.ok.json" ] && [ ! -f "$WT3/.swarm/tasks/done/c3.err.json" ] \
    || red "c3: outcome was recorded before the in-flight check-on-done ever resolved — the listener didn't wait"
printf 'issue #579 check-on-done: resolved while the listener was waiting\n' \
    > "$WT3/.swarm/tasks/done/c3.check.log"
stub_check_json "$WT3" c3 pass 0 "$HEAD3"
rmdir "$WT3/.swarm/tasks/status/c3.check-claim"
wait_for "c3 outcome" "[ -f '$WT3/.swarm/tasks/done/c3.ok.json' ]"
[ ! -f "$WT3/ran3.txt" ] || red "c3: CHECK_CMD ran a second time despite the in-flight result resolving to pass"
jq -e '.outcome == "ok" and .check_exit == 0' "$WT3/.swarm/tasks/done/c3.ok.json" >/dev/null \
    || { cat "$WT3/.swarm/tasks/done/c3.ok.json"; red "c3: outcome JSON wrong"; }
green "in-flight check-on-done is waited out, then reused — no second CHECK_CMD run"

# ============================================================================
heading "Test 4: HEAD mismatch (a new commit landed since) → runs fresh"
# ============================================================================
WT4="$TEST_DIR/wt-4"
new_worktree "$WT4" >/dev/null
stub_check_json "$WT4" c4 pass 0 "0000000000000000000000000000000000000000"
printf 'stale check-on-done log for a commit this worktree is no longer at\n' \
    > "$WT4/.swarm/tasks/done/c4.check.log"
start_listener "$WT4"
drop_v2 "$WT4" c4 'echo agent-ran > t4.txt
# <!-- SWARM_CHECK: echo ran >> ran4.txt -->'
wait_for "c4 outcome" "[ -f '$WT4/.swarm/tasks/done/c4.ok.json' ]"
[ -f "$WT4/ran4.txt" ] || red "c4: CHECK_CMD should have run fresh (HEAD mismatch), but ran.txt was never written"
grep -q "worker.check.reused" "$WT4/listener.log" \
    && red "c4: should NOT have reused a check-on-done result recorded for a different commit"
green "a check.json recorded against a different HEAD is ignored — the check runs fresh"

# ============================================================================
heading "Test 5: no check.json at all → behavior unchanged"
# ============================================================================
WT5="$TEST_DIR/wt-5"
HEAD5="$(new_worktree "$WT5")"
start_listener "$WT5"
drop_v2 "$WT5" c5 'echo agent-ran > t5.txt
# <!-- SWARM_CHECK: echo ran >> ran5.txt -->'
wait_for "c5 outcome" "[ -f '$WT5/.swarm/tasks/done/c5.ok.json' ]"
[ -f "$WT5/ran5.txt" ] || red "c5: CHECK_CMD should have run (no check-on-done record exists at all)"
jq -e '.outcome == "ok" and .check_exit == 0' "$WT5/.swarm/tasks/done/c5.ok.json" >/dev/null \
    || { cat "$WT5/.swarm/tasks/done/c5.ok.json"; red "c5: outcome JSON wrong"; }
grep -q "worker.check.reused" "$WT5/listener.log" \
    && red "c5: should not log a reuse when no check-on-done record exists at all"
green "no check-on-done record at all: unchanged behavior — the listener runs its own check"
# run_check_claimed() (self-review finding on this same issue's first draft):
# even when the listener ends up running the check itself, it must leave
# behind the same claim/record shape coordinator-watch.sh would, so a
# watcher poll landing moments later backs off instead of starting its own
# concurrent run — the half of the race try_reuse_check_on_done() alone
# cannot close (the listener getting there before the watcher does).
[ ! -d "$WT5/.swarm/tasks/status/c5.check-claim" ] \
    || red "c5: the check-claim dir must be released (rmdir'd) once the listener's own run finishes, not left dangling"
jq -e --arg h "$HEAD5" '.state == "pass" and .check_exit == 0 and .head_sha == $h' \
    "$WT5/.swarm/tasks/status/c5.check.json" >/dev/null \
    || { cat "$WT5/.swarm/tasks/status/c5.check.json" 2>/dev/null || echo "(missing)"; \
         red "c5: the listener's own run must still record a watcher-shaped check.json (state/check_exit/head_sha) so a racing poll can see it was already done here"; }
green "a self-run check still leaves a correctly shaped check.json behind, claim released — visible to a racing watcher poll"

# ============================================================================
heading "Test 6: watcher claimed first but hasn't written checking yet → listener waits, doesn't double-run"
# ============================================================================
# The other half of the self-review's finding: the narrow window right after
# maybe_run_check()'s mkdir succeeds but before it writes the "checking"
# check.json. A listener reaching try_reuse_check_on_done() in that exact
# window must still wait for it, not read "no check.json" as "nothing to
# reuse" and start a second, concurrent run of its own.
WT6="$TEST_DIR/wt-6"
HEAD6="$(new_worktree "$WT6")"
mkdir -p "$WT6/.swarm/tasks/status/c6.check-claim"   # claimed — no check.json yet
start_listener "$WT6"
drop_v2 "$WT6" c6 'echo agent-ran > t6.txt
# <!-- SWARM_CHECK: echo ran >> ran6.txt -->'
sleep 2
[ ! -f "$WT6/.swarm/tasks/done/c6.ok.json" ] && [ ! -f "$WT6/.swarm/tasks/done/c6.err.json" ] \
    || red "c6: outcome was recorded before the watcher's claimed-but-not-yet-recorded check ever resolved — the listener raced ahead instead of waiting"
[ ! -f "$WT6/ran6.txt" ] || red "c6: CHECK_CMD ran a second time while the watcher's claim was still active with no check.json yet"
printf 'issue #579 check-on-done: resolved while the listener was waiting on the bare claim\n' \
    > "$WT6/.swarm/tasks/done/c6.check.log"
stub_check_json "$WT6" c6 pass 0 "$HEAD6"
rmdir "$WT6/.swarm/tasks/status/c6.check-claim"
wait_for "c6 outcome" "[ -f '$WT6/.swarm/tasks/done/c6.ok.json' ]"
[ ! -f "$WT6/ran6.txt" ] || red "c6: CHECK_CMD ran a second time despite the claimed check resolving to pass"
jq -e '.outcome == "ok" and .check_exit == 0' "$WT6/.swarm/tasks/done/c6.ok.json" >/dev/null \
    || { cat "$WT6/.swarm/tasks/done/c6.ok.json"; red "c6: outcome JSON wrong"; }
grep -q "worker.check.reused" "$WT6/listener.log" \
    || red "c6: expected worker.check.reused in the listener's own log"
green "a bare claim (watcher owns it, hasn't recorded checking yet) is waited out, then reused — no second CHECK_CMD run"

echo
green "ALL TESTS PASSED"
