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
for fn in worker_pane_state worker_pane_busy worker_pane_ctx_used worker_pending_brief_path worker_pending_brief \
          worker_current_task_terminal mtime_epoch ctime_epoch compact_last_pane_line compact_composer_clear \
          compact_confirm_submitted compact_retract_queued worker_deliver_record_failure \
          worker_deliver_record_success worker_deliver_detect_claim maybe_worker_deliver_brief log_event \
          is_own_worktree_dir own_wt_dir_for_issue worker_deliver_composer_stall_clear \
          worker_deliver_record_composer_stall worker_deliver_record_shell_stall coord_inbox_write \
          worker_deliver_terminal_stall_clear worker_deliver_record_terminal_stall \
          worker_deliver_gave_up_stall_clear worker_deliver_record_gave_up_stall; do
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
WORKER_DELIVER_COMPOSER_STALL_THRESHOLD=20
WORKER_DELIVER_SHELL_STALL_THRESHOLD=20
WORKER_DELIVER_TERMINAL_STALL_THRESHOLD=20
WORKER_DELIVER_GAVE_UP_STALL_THRESHOLD=20
COMPACT_QUEUED_MARKER_PATTERN='Press up to edit queued messages'
COMPACT_RETRACT_BACKSPACES=3
COMPACT_SUBMIT_SETTLE_SECS=0
# issue #436: must match coordinator-watch.sh's own default — see the
# WORKER_COMPACT_BUSY_PATTERN comment just above for why these fixtures
# copy real defaults instead of leaving the var unset (this file's own
# `set -u` would otherwise abort the moment compact_last_pane_line
# references it).
COMPACT_COMPOSER_CHROME_PATTERN='^※ recap:|^[[:space:]]*(✻|✶)[[:space:]]*(Considering…|Sautéed for|Cooked for|Baked for|Simmered for|Brewed for|Crunched for)?|/clear to save [0-9.]+k tokens'
declare -A WORKER_DELIVER_LAST_FAIL=()
declare -A WORKER_DELIVER_FAIL_COUNT=()
declare -A WORKER_DELIVER_GAVE_UP=()
declare -A WORKER_DELIVER_PENDING_SEEN=()
declare -A WORKER_DELIVER_COMPOSER_STALL_BRIEF=()
declare -A WORKER_DELIVER_COMPOSER_STALL_COUNT=()
declare -A WORKER_DELIVER_COMPOSER_STALL_ESCALATED=()
declare -A WORKER_DELIVER_SHELL_STALL_BRIEF=()
declare -A WORKER_DELIVER_SHELL_STALL_COUNT=()
declare -A WORKER_DELIVER_SHELL_STALL_ESCALATED=()
declare -A WORKER_DELIVER_TERMINAL_STALL_BRIEF=()
declare -A WORKER_DELIVER_TERMINAL_STALL_COUNT=()
declare -A WORKER_DELIVER_TERMINAL_STALL_ESCALATED=()
declare -A WORKER_DELIVER_GAVE_UP_STALL_BRIEF=()
declare -A WORKER_DELIVER_GAVE_UP_STALL_COUNT=()
declare -A WORKER_DELIVER_GAVE_UP_STALL_ESCALATED=()
# coord_inbox_write (issue #430) is exercised by worker_deliver_record_
# composer_stall's escalation path (Test 10 below) — same fixture
# convention as test-watcher-activity-poll.sh's copy of these two vars.
COORD_INBOX_DIR="$TEST_DIR/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$COORD_INBOX_DIR/.self"

# own_wt_dir_for_issue (issue #357/#388) resolves wt_dir via
# is_own_worktree_dir(), which needs $PROJECT_DIR set to do its `git -C
# "$PROJECT_DIR" worktree list` check. This fixture has no real git repo —
# is_own_worktree_dir's fail-open policy (a non-git PROJECT_DIR treats
# every dir as ours) covers that, so any non-empty path works here.
PROJECT_DIR="$TEST_DIR/not-a-git-repo"
WORKSPACE="$TEST_DIR/workspace"
WT_DIR="$WORKSPACE/wt-issue-42"
INBOX_DIR="$WT_DIR/.swarm/tasks/inbox"
PROCESSING_DIR="$WT_DIR/.swarm/tasks/processing"
STATUS_DIR="$WT_DIR/.swarm/tasks/status"
DONE_DIR="$WT_DIR/.swarm/tasks/done"
mkdir -p "$INBOX_DIR" "$PROCESSING_DIR" "$STATUS_DIR" "$DONE_DIR"
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
check "status=blocked -> rc0 (issue #578: write_outcome() already forces outcome=err for a blocked session, so ending it to deliver a requeue.sh unblock brief is now safe)" "0" "$rc"

set_current_task "t1" "in-progress"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "status=in-progress -> rc1 (genuinely still in flight, not confirmed terminal)" "1" "$rc"

set_current_task "t1" "ready-for-review"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "status=ready-for-review -> rc0 (genuinely terminal)" "0" "$rc"

set_current_task "t1" "done-no-pr"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "status=done-no-pr -> rc0 (genuinely terminal)" "0" "$rc"

heading "Test 2b: worker_current_task_terminal — issue #370 mismatched task_id fallback"
# The wedge this closes: a worker session wrote its status record under a
# DIFFERENT name than the current processing/ entry's basename (didn't echo
# its brief's own inbox filename back as $TASK_ID) — observed in the wild as
# status/issue-517.json sitting next to processing/20260906-230823-517.md.
# Without a fallback, the exact-name miss blocks delivery FOREVER (unlike
# every other worker.deliver.skip reason, this one never self-heals).
#
# Timestamps here use real wall-clock ordering (sleep), not `touch -d`:
# the fix keys off proc_file's CTIME (bumped by rename(2)/creation, always
# "now" at the moment of the operation — see the ctime_epoch/mtime_epoch
# split in worker_current_task_terminal()'s header comment), which can't be
# backdated the way `touch -d` backdates mtime.
rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
echo "the current task brief" > "$PROCESSING_DIR/20260906-230823-517.md"
sleep 1.1
printf '{"task_id":"issue-517","state":"ready-for-review","pr":123,"ts":"2026-09-06T23:10:00Z","note":""}' \
    > "$STATUS_DIR/issue-517.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "mismatched task_id, status written AFTER the current claim -> rc0 (fallback trusts it)" "0" "$rc"

# The staleness guard this fallback needs: a status file surviving from an
# EARLIER, already-concluded task in the same (requeued) worktree — which
# per worker_task_done()'s header comment never gets deleted — must NOT be
# mistaken for the CURRENT, still-genuinely-in-flight task's own record just
# because its name happens to collide with a plausible fallback key. Here
# the stale record is written FIRST, and the current brief is only claimed
# (echoed into processing/) afterward — mirroring requeue.sh dropping a
# follow-up brief that then sits queued until claimed, well after some
# earlier task already concluded and wrote this leftover status file.
rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
printf '{"task_id":"issue-517","state":"ready-for-review","pr":99,"ts":"2026-09-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/issue-517.json"
sleep 1.1
echo "a brand new follow-up brief, still genuinely in flight" > "$PROCESSING_DIR/20260906-230823-517.md"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "mismatched task_id, but status predates the current claim -> rc1 (stale record rejected)" "1" "$rc"

# Self-review finding: among multiple post-claim candidates, trust the
# NEWEST by mtime, not just the first terminal one a glob happens to visit.
# Simulates the same anomalous worker session writing under two different
# mismatched names at different points — first a (wrong) ready-for-review,
# then genuinely going back in-progress again and recording THAT under
# another name. Picking the first terminal match in glob order would
# wrongly select the stale ready-for-review file and miss the newer,
# authoritative non-terminal state — the exact false-completion bug this
# whole function exists to prevent. (Using "in-progress" here rather than
# "blocked": since issue #578, blocked is itself terminal-for-delivery, so
# it no longer exercises this "newer state overrides" path — any other
# genuinely non-terminal state does.) "aaa-*"/"zzz-*" prefixes force the
# stale terminal record to sort first alphabetically, so this only passes
# if recency (not glob order) decides the outcome.
rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
echo "the current task brief" > "$PROCESSING_DIR/20260906-230823-517.md"
sleep 1.1
printf '{"task_id":"aaa-517","state":"ready-for-review","pr":123,"ts":"2026-09-06T23:09:00Z","note":""}' \
    > "$STATUS_DIR/aaa-517.json"
sleep 1.1
printf '{"task_id":"zzz-517","state":"in-progress","pr":123,"ts":"2026-09-06T23:11:00Z","note":"still working"}' \
    > "$STATUS_DIR/zzz-517.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "newer mismatched-name record is in-progress (supersedes an older stale ready-for-review) -> rc1" "1" "$rc"

# Self-review finding: mtime_epoch/ctime_epoch resolve to whole seconds, so
# the "newest wins" tie-break above needs its OWN tie-break for two
# mismatched-name records landing in the same epoch second — deterministic
# here via `touch -r` (copies aaa-517.json's exact mtime onto zzz-517.json)
# rather than relying on two real writes happening to land in the same wall-
# clock second. On a genuine tie, a non-terminal record must win (fail
# closed) regardless of which file a glob happens to visit first — reversed
# alphabetical order from the "newest wins" case above (in-progress=aaa-,
# ready-for-review=zzz-) so this only passes if the tie-break — not glob
# order — decides the outcome. ("in-progress" rather than "blocked": since
# issue #578, blocked is itself terminal, so it can no longer stand in for
# the non-terminal side of this tie.)
rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
echo "the current task brief" > "$PROCESSING_DIR/20260906-230823-517.md"
sleep 1.1
printf '{"task_id":"aaa-517","state":"in-progress","pr":123,"ts":"2026-09-06T23:09:00Z","note":"still working"}' \
    > "$STATUS_DIR/aaa-517.json"
printf '{"task_id":"zzz-517","state":"ready-for-review","pr":123,"ts":"2026-09-06T23:09:00Z","note":""}' \
    > "$STATUS_DIR/zzz-517.json"
touch -r "$STATUS_DIR/aaa-517.json" "$STATUS_DIR/zzz-517.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "same-second tie between in-progress and ready-for-review records -> rc1 (non-terminal wins, fail closed)" "1" "$rc"

# Self-review finding: the tie-break's second pass must not read "nothing
# confirmed" as an implicit terminal default. Simulates the newest
# candidate being mid-write (worker truncates with `>` then writes, or the
# JSON is simply corrupted) — jq fails to parse it, so the loop's only
# tied-mtime candidate is skipped via `continue` without ever setting
# saw_terminal. Without that guard this fell through to a bare `return 0`
# — fail-OPEN on the gate's single most likely race (the current task's own
# status write, landing right as this sweep runs).
rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
echo "the current task brief" > "$PROCESSING_DIR/20260906-230823-517.md"
sleep 1.1
printf 'not valid json{' > "$STATUS_DIR/issue-517.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "newest post-claim candidate is unparseable -> rc1 (nothing confirmed, fails closed, never a bare return-0 default)" "1" "$rc"

rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true

heading "Test 2c: worker_current_task_terminal — processing/ already emptied by scripts/task-done.sh (issue #451 self-review finding)"
# The regression this guards: scripts/task-done.sh (the worker's own
# mandatory last step, prompts/worker.md § "Task completion") moves
# processing/<id>.md into done/ WHILE the dispatched agent process may
# still be alive — that's the entire point of task-done.sh. Before this
# fix, an empty processing/ always meant "no task in flight" and this
# function correctly returned 1; now it doesn't, and every worker that
# correctly calls task-done.sh would wedge WORKER_AUTO_DELIVER forever
# (task_not_terminal never self-heals on its own — see this function's
# own #370 comment above).
rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json "$DONE_DIR"/*.md "$DONE_DIR"/*.json 2>/dev/null || true
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "empty processing/, nothing archived in done/ either -> rc1 (nothing to check)" "1" "$rc"

# task-done.sh's own archive move + a matching status file.
echo "the current task brief" > "$DONE_DIR/t451.md"
printf '{"task_id":"t451","state":"blocked","pr":null,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t451.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "processing/ empty, archived brief's OWN status file says blocked -> rc0 (issue #578: terminal-for-delivery)" "0" "$rc"

printf '{"task_id":"t451","state":"ready-for-review","pr":null,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t451.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "processing/ empty, archived brief's status says ready-for-review -> rc0 (task-done.sh's worker genuinely finished)" "0" "$rc"

# No status file at all under the archived task_id's name — task-done.sh's
# own outcome record (which it always writes as part of the same action
# that empties processing/) is sufficient on its own.
rm -f "$STATUS_DIR"/*.json
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "processing/ empty, archived brief but no status file and no outcome record yet -> rc1 (can't confirm)" "1" "$rc"

printf '{"task_id":"t451","outcome":"ok","finished":"2026-01-01T00:00:00Z","source":"task-done.sh"}' \
    > "$DONE_DIR/t451.ok.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "processing/ empty, archived brief, done/t451.ok.json exists (task-done.sh's own record) -> rc0" "0" "$rc"

# issue #601's actual root cause, isolated: task-done.sh --force's BRIEF-LESS
# completion (a no-PR ruling/research task, or a v1 legacy task — see
# task-done.sh's own --force comment) has no matching processing/<id>.md to
# move, so done/*.md NEVER gets written at all — only the .ok.json/.err.json
# outcome record. Before this fix, the processing/-empty fallback scanned
# ONLY done/*.md to recover a task_id, so this exact shape (no .md anywhere
# in done/) found nothing and fell through to rc1 forever — the iss-1175
# stall. Must still resolve via the matching status file alone.
rm -f "$DONE_DIR"/*.md "$STATUS_DIR"/*.json 2>/dev/null || true
printf '{"task_id":"t451","state":"blocked","pr":null,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t451.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "brief-less completion (no done/*.md at all, only .ok.json), status=blocked -> rc0 (issue #578: terminal-for-delivery)" "0" "$rc"

printf '{"task_id":"t451","state":"ready-for-review","pr":null,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t451.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "brief-less completion (no done/*.md at all, only .ok.json), status=ready-for-review -> rc0 (issue #601 fix)" "0" "$rc"

# Same shape again for a failed brief-less run (.err.json instead of .ok.json).
rm -f "$DONE_DIR"/*.ok.json "$STATUS_DIR"/*.json 2>/dev/null || true
printf '{"task_id":"t452","outcome":"err","finished":"2026-01-01T00:00:00Z","source":"task-done.sh"}' \
    > "$DONE_DIR/t452.err.json"
printf '{"task_id":"t452","state":"done-no-pr","pr":null,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t452.json"
rc=0; worker_current_task_terminal "$WT_DIR" || rc=$?
check "brief-less completion, no done/*.md at all, only .err.json, status=done-no-pr -> rc0 (issue #601 fix, .err.json shape)" "0" "$rc"

rm -f "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json "$DONE_DIR"/*.md "$DONE_DIR"/*.json 2>/dev/null || true

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

# The issue #578 regression case: a real brief IS pending (the requeue.sh
# follow-up meant to unblock this worker), and the CURRENT task is "blocked"
# (a decision-needed worker awaiting the coordinator's answer — the exact
# incident prompts/coordinator.md's "unblock it with requeue.sh" line
# describes). Before the fix this skipped forever as task_not_terminal,
# wedging the unblock path; blocked is now treated as terminal-for-delivery
# (write_outcome() in worker-listener.sh already forces outcome=err for a
# blocked session, so ending it here can never falsely "complete"
# unfinished work — see worker_current_task_terminal()'s header comment).
# Needs a real idle, ctx-rendered composer on screen (not the bare "sleep
# 300" from the no-brief check above) so this exercises the FULL chain all
# the way to worker.deliver.attempt, same rendered shape as the "idle,
# empty-composer" case further down — not just the task_not_terminal gate.
set_current_task "t1" "blocked"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane (blocked task) -> cli" "cli" "worker_pane_state '$WIN'"
: > "$EVENTS_LOG"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.skip.*reason=task_not_terminal' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "current task status=blocked -> NOT skipped as task_not_terminal (issue #578)" "notskipped" "$got"
if grep -q 'worker.deliver.attempt' "$EVENTS_LOG"; then got=attempted; else got=notattempted; fi
check "blocked task, brief pending, pane idle -> delivery attempted (issue #578: this is the documented requeue.sh unblock path)" "attempted" "$got"

# From here on, the current task has genuinely finished — the OTHER incident
# half (a worker that opened its PR, handed off, and simply never ran /quit).
set_current_task "t1" "ready-for-review"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "sleep 300" Enter
check_eventually "back to a plain non-shell foreground -> cli" "cli" "worker_pane_state '$WIN'"

# Gate on BOTH the rendered content AND worker_pane_state()'s process-name
# read (issue #398): the injected command is "clear; echo '...'; sleep 300"
# — clear/echo are shell builtins, so the busy TEXT can already be on screen
# while the pane's foreground process is still bash itself, a heartbeat
# before it forks the trailing `sleep 300` that actually flips
# pane_current_command (and therefore worker_pane_state()) to "cli". Content
# alone settles first; maybe_worker_deliver_brief()'s own gate checks
# worker_pane_state() before it ever looks at content (see its "cli" guard),
# so a busy_or_idle() keyed on content alone could report "busy" and let the
# one-shot maybe_worker_deliver_brief() call below land in that still-"shell"
# window, hit the state guard, and return without logging anything —
# "notskipped", not a real pane_busy skip. Reproduced locally by widening the
# window (a CPU-bound builtin loop between the echo and the fork); harmless
# in production (fail-open, next sweep tick just tries again) but flaked this
# one-shot assertion under CI's heavier scheduling load. Requiring both
# conditions here waits out that same fork, same as production code would
# see on its next poll.
busy_or_idle() {
    if [ "$(worker_pane_state "$WIN")" = "cli" ] && worker_pane_busy "$WIN"; then
        echo busy
    else
        echo idle
    fi
}

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
# $1: the brief file this session's listener would claim on /quit — mirrors
# worker-listener.sh's claim_next_task() atomic mv out of inbox/, since that
# mv (worker_pending_brief() going false) is now what maybe_worker_deliver_
# brief() actually keys success on (issue #344), not pane state.
BRIEF="$1"; PROCESSING_TARGET="$2"
render() { echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; }
render
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$line" = "/quit" ]; then
        mv "$BRIEF" "$PROCESSING_TARGET" 2>/dev/null || true
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
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
BRIEF_FILE="$INBOX_DIR/20260826-140000-42.md"
echo "a follow-up brief" > "$BRIEF_FILE"
PROCESSING_TARGET="$PROCESSING_DIR/$(basename "$BRIEF_FILE")"
set_current_task "t2" "ready-for-review"   # current task already finished

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "bash -c 'exec -a claude bash $FAKE_REPL \"$BRIEF_FILE\" \"$PROCESSING_TARGET\"'" Enter
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
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "brief left inbox/ (claimed by the fake listener) -> worker_pending_brief now rc1" "1" "$rc"

# issue #437: the positive counterpart to worker.deliver.skip — names the
# exact brief and attributes this success to the watcher's own /quit
# injection, not a human's manual one.
if grep -qF "worker.deliver.ok" "$EVENTS_LOG" \
    && grep -qF "brief=$(basename "$BRIEF_FILE") release=auto_deliver" "$EVENTS_LOG"; then
    got=logged
else
    got=missing
fi
check "worker.deliver.ok logged with the delivered brief's filename and release=auto_deliver (issue #437)" "logged" "$got"

# A LATER sweep that again finds this window parked in "cli" state (its
# relaunched agent going idle, say) must NOT re-attribute the delivery this
# test already logged as auto_deliver to a second, false
# listener_claim_after_quit event. Without clearing WORKER_DELIVER_
# PENDING_SEEN on auto_deliver success, worker_deliver_detect_claim would
# see prior=<the just-delivered brief> (still set from the sweep above) and
# current="" (nothing pending now) on this next cli-state sweep, and
# wrongly log it a second time.
tmux send-keys -t "$SESSION_NAME:$WIN" "sleep 300" Enter
check_eventually "pane parked in cli again (e.g. next task's agent going idle)" "cli" "worker_pane_state '$WIN'"
maybe_worker_deliver_brief "$WIN"
if grep -qF "listener_claim_after_quit" "$EVENTS_LOG"; then
    red "auto_deliver success was double-logged as listener_claim_after_quit on a later cli-state sweep; events.log: $(cat "$EVENTS_LOG")"
else
    green "no double-log: a later cli-state sweep stays silent on this issue (WORKER_DELIVER_PENDING_SEEN cleared on auto_deliver success)"
    PASS=$((PASS + 1))
fi
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2

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

# Self-review finding (issue #437, round 2): a /quit that only takes effect
# LATE — just past this timeout — must be credited to release=auto_deliver
# (this script's own delayed success), not misattributed to
# release=listener_claim_after_quit (a human's manual /quit). Simulated here
# by having the brief vanish (mimicking a delayed effect of the /quit this
# script already sent).
mv "$INBOX_DIR/20260826-150000-42.md" "$PROCESSING_DIR/20260826-150000-42.md"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "pane parked in cli again after the timed-out attempt" "cli" "worker_pane_state '$WIN'"
maybe_worker_deliver_brief "$WIN"
if grep -qF "listener_claim_after_quit" "$EVENTS_LOG"; then
    red "a late self-effected /quit was misattributed to listener_claim_after_quit; events.log: $(cat "$EVENTS_LOG")"
elif grep -qF "worker.deliver.ok" "$EVENTS_LOG" \
    && grep -qF "brief=20260826-150000-42.md release=auto_deliver late=1" "$EVENTS_LOG"; then
    green "correct attribution: a late own-effect /quit is credited to release=auto_deliver, not listener_claim_after_quit"
    PASS=$((PASS + 1))
else
    red "no attribution at all was logged for the late own-effect departure; events.log: $(cat "$EVENTS_LOG")"
fi

heading "Test 7b: the tightened guard survives MORE than one intervening idle sweep (issue #437 self-review, round 2)"
# The original guard (blindly clearing WORKER_DELIVER_PENDING_SEEN on
# timeout) only protected the ONE sweep immediately following a timeout —
# a second consecutive idle sweep before the late departure would re-arm
# tracking and the eventual departure would misattribute to
# release=listener_claim_after_quit. WORKER_DELIVER_TIMED_OUT_BRIEF must
# survive an extra idle sweep (nothing changed yet) in between.
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]'
: > "$EVENTS_LOG"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
BRIEF_FILE_LATE="$INBOX_DIR/20260826-155000-42.md"
echo "another late brief" > "$BRIEF_FILE_LATE"
set_current_task "t3b" "done-no-pr"   # current task already finished
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "bash -c 'exec -a gemini bash $FAKE_REPL2'" Enter
check_eventually "fake non-quitting REPL foreground -> cli" "cli" "worker_pane_state '$WIN'"

WORKER_DELIVER_END_TIMEOUT_SECS=3 WORKER_DELIVER_POLL_SECS=1 maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.timeout' "$EVENTS_LOG"; then got=timedout; else got=nottimedout; fi
check "second scenario's timeout logged" "timedout" "$got"

# One intervening idle sweep: nothing has changed yet (brief still pending
# in inbox/) — this must leave WORKER_DELIVER_TIMED_OUT_BRIEF intact.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "pane parked in cli for the intervening sweep" "cli" "worker_pane_state '$WIN'"
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.ok' "$EVENTS_LOG"; then
    red "an idle sweep with nothing changed should log nothing yet; events.log: $(cat "$EVENTS_LOG")"
else
    green "intervening idle sweep (brief still pending) stays silent, as expected"
    PASS=$((PASS + 1))
fi

# NOW the late effect actually lands — two sweeps after the original timeout,
# exactly the gap the original one-sweep-only guard didn't cover.
mv "$BRIEF_FILE_LATE" "$PROCESSING_DIR/$(basename "$BRIEF_FILE_LATE")"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "pane parked in cli for the actual late departure" "cli" "worker_pane_state '$WIN'"
maybe_worker_deliver_brief "$WIN"
if grep -qF "listener_claim_after_quit" "$EVENTS_LOG"; then
    red "a late self-effected /quit, two sweeps out, was misattributed to listener_claim_after_quit; events.log: $(cat "$EVENTS_LOG")"
elif grep -qF "worker.deliver.ok" "$EVENTS_LOG" \
    && grep -qF "brief=$(basename "$BRIEF_FILE_LATE") release=auto_deliver late=1" "$EVENTS_LOG"; then
    green "correct attribution survives more than one intervening sweep (issue #437 self-review, round 2)"
    PASS=$((PASS + 1))
else
    red "no attribution logged for the two-sweeps-late departure; events.log: $(cat "$EVENTS_LOG")"
fi

heading "Test 7c: issue #600 — a window that gave up must not stay silently given-up forever once its timed-out /quit is observed landing late; the NEXT queued brief must still get a real delivery attempt"
# Reproduces the exact fand-etl/corpusminder-spring/SAMlytics/llm-swarm-runner
# incidents issue #600 documents: 3 consecutive /quit timeouts -> giving_up,
# then the 3rd /quit's effect lands late (worker.deliver.ok release=
# auto_deliver late=1) -- but before this fix, WORKER_DELIVER_GAVE_UP stayed
# set forever, so every later sweep for this window, for every FUTURE
# brief too, silently returned at the give-up gate with zero further
# worker.deliver.* events. Reuses FAKE_REPL2 (never recognizes /quit, from
# Test 7) to produce 3 genuine timeouts, then FAKE_REPL (recognizes /quit,
# from Test 6) to prove the window is not just "unstuck" in bookkeeping but
# actually delivers the next brief for real.
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]' 'WORKER_DELIVER_TIMED_OUT_BRIEF[42]' 'WORKER_DELIVER_PENDING_SEEN[42]'
unset 'WORKER_DELIVER_GAVE_UP_STALL_BRIEF[42]' 'WORKER_DELIVER_GAVE_UP_STALL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP_STALL_ESCALATED[42]'
: > "$EVENTS_LOG"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
BRIEF_FILE_GU="$INBOX_DIR/20261017-013000-42.md"
echo "a brief whose delivery will time out 3 times in a row" > "$BRIEF_FILE_GU"
set_current_task "t6" "ready-for-review"   # current task already finished

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "bash -c 'exec -a gemini bash $FAKE_REPL2'" Enter
check_eventually "fake non-quitting REPL foreground -> cli" "cli" "worker_pane_state '$WIN'"

WORKER_DELIVER_BACKOFF_SECS=0   # the real 600s default would skip attempts 2/3 as backoff, never reaching 3 failures
for i in 1 2 3; do
    WORKER_DELIVER_END_TIMEOUT_SECS=3 WORKER_DELIVER_POLL_SECS=1 maybe_worker_deliver_brief "$WIN"
done
WORKER_DELIVER_BACKOFF_SECS=600
check "3 consecutive timeouts -> gave up (issue #313 baseline, reproduced here)" "1" "${WORKER_DELIVER_GAVE_UP[42]:-}"
check "worker.deliver.giving_up logged exactly once" "1" "$(grep -cF 'worker.deliver.giving_up' "$EVENTS_LOG")"

# The 3rd /quit's effect now lands late, exactly like Test 7's simulation --
# standing in for a slow-to-render CLI finally processing it a beat after
# maybe_worker_deliver_brief's own synchronous wait already gave up.
mv "$BRIEF_FILE_GU" "$PROCESSING_DIR/$(basename "$BRIEF_FILE_GU")"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "pane parked in cli again after the 3rd timed-out attempt" "cli" "worker_pane_state '$WIN'"

maybe_worker_deliver_brief "$WIN"
if grep -qF "worker.deliver.ok" "$EVENTS_LOG" \
    && grep -qF "brief=$(basename "$BRIEF_FILE_GU") release=auto_deliver late=1" "$EVENTS_LOG"; then
    green "late departure after giving_up is still correctly attributed to auto_deliver"
    PASS=$((PASS + 1))
else
    red "late departure after giving_up was not attributed; events.log: $(cat "$EVENTS_LOG")"
fi
check "the bug this closes: a late success RESETS WORKER_DELIVER_GAVE_UP instead of leaving it stuck forever" "" "${WORKER_DELIVER_GAVE_UP[42]:-}"
check "LAST_FAIL also reset by the late success" "" "${WORKER_DELIVER_LAST_FAIL[42]:-}"
check "FAIL_COUNT also reset by the late success" "" "${WORKER_DELIVER_FAIL_COUNT[42]:-}"

# issue #600's exact failure mode: the NEXT requeued brief, queued behind a
# window that had given up, must get a real delivery attempt and actually be
# delivered -- not an indefinite, silent skip with zero worker.deliver.*
# events ever again. The relaunched session that claimed BRIEF_FILE_GU
# (standing in for the real worker-listener.sh dispatch that follows any
# claim) has itself now finished too -- a fresh terminal current-task
# status, replacing the stray processing/ entry the mv above left behind,
# so this next brief's own task_not_terminal gate isn't the thing under
# test here.
set_current_task "t_gu" "ready-for-review"
: > "$EVENTS_LOG"
NEXT_BRIEF="$INBOX_DIR/20261017-021821-42.md"
echo "the next requeued brief, queued after the giving_up + late-ok sequence" > "$NEXT_BRIEF"
NEXT_PROCESSING_TARGET="$PROCESSING_DIR/$(basename "$NEXT_BRIEF")"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "bash -c 'exec -a claude bash $FAKE_REPL \"$NEXT_BRIEF\" \"$NEXT_PROCESSING_TARGET\"'" Enter
check_eventually "fake quitting REPL foreground -> cli" "cli" "worker_pane_state '$WIN'"

WORKER_DELIVER_END_TIMEOUT_SECS=10 WORKER_DELIVER_POLL_SECS=1 maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.attempt' "$EVENTS_LOG"; then got=attempted; else got=notattempted; fi
check "the next brief gets a real delivery attempt, not a silent forever-skip (issue #600's core bug)" "attempted" "$got"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "the next brief was actually delivered -- full recovery, not just an attempt" "1" "$rc"
check "give-up-stall bookkeeping never even starts once GAVE_UP is genuinely cleared" "" "${WORKER_DELIVER_GAVE_UP_STALL_COUNT[42]:-}"

rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]'
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2

heading "Test 8: relaunch-race (issue #344) — /quit followed by an IMMEDIATE relaunch must still record success, never a false timeout/retract into the new session"
# The bug this closes: worker-listener.sh's claim_next_task() atomically
# claims the brief and dispatch_agent() re-launches claude within the SAME
# WORKER_DELIVER_POLL_SECS window /quit ended the old session in, so the
# pane can go cli -> shell -> cli again entirely between two polls and
# worker_pane_state never observably rests at "shell". Test 6's fixture (a
# plain `exit 0` on /quit, landing the pane at idle bash forever) cannot
# exercise this race at all — this fixture relaunches itself the instant
# /quit lands, via the outer `while true` loop below, the same sequence the
# real listener produces.
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]'
FAKE_REPL3="$TEST_DIR/fake-worker-repl-relaunch.sh"
cat > "$FAKE_REPL3" <<'REPL'
#!/usr/bin/env bash
# $1: the brief file this session's listener would claim on /quit.
# $2: where claim_next_task's atomic mv would land it (processing/).
BRIEF="$1"; PROCESSING_TARGET="$2"
render() { echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; }
render
if [ -f "$BRIEF" ]; then
    # Pre-/quit session: the one with the pending brief still in inbox/.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$line" = "/quit" ]; then
            mv "$BRIEF" "$PROCESSING_TARGET" 2>/dev/null || true
            exit 0
        fi
        clear
        echo "resumed: $line"
        render
    done
else
    # Relaunched session: the brief is already claimed — sit idle, exactly
    # like the new agent turn dispatch_agent() just started.
    while IFS= read -r line; do :; done
fi
REPL
chmod +x "$FAKE_REPL3"

: > "$EVENTS_LOG"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
BRIEF_FILE2="$INBOX_DIR/20260826-160000-42.md"
echo "relaunch-race brief" > "$BRIEF_FILE2"
PROCESSING_TARGET2="$PROCESSING_DIR/$(basename "$BRIEF_FILE2")"
set_current_task "t4" "ready-for-review"   # current task already finished

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "while true; do bash -c 'exec -a claude bash $FAKE_REPL3 \"$BRIEF_FILE2\" \"$PROCESSING_TARGET2\"'; done" Enter
check_eventually "relaunch-loop fake REPL foreground (argv[0]=claude) -> cli" "cli" "worker_pane_state '$WIN'"

maybe_worker_deliver_brief "$WIN"

rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "brief left inbox/ (claimed) despite the instant relaunch" "1" "$rc"
if grep -q 'worker.deliver.ended' "$EVENTS_LOG"; then got=ended; else got=notended; fi
check "worker.deliver.ended logged even though the pane never observably rested at 'shell'" "ended" "$got"
if grep -q 'worker.deliver.timeout' "$EVENTS_LOG"; then got=timedout; else got=nottimedout; fi
check "no false worker.deliver.timeout on the relaunch race" "nottimedout" "$got"
if grep -qE 'worker\.deliver\.(retract|delivered_as_text)' "$EVENTS_LOG"; then got=touched; else got=untouched; fi
check "compact_retract_queued/delivered_as_text never fired into the relaunched live session" "untouched" "$got"

heading "Test 9: listener_claim_after_quit — issue #437's second attribution path (a human's manual /quit, not this script's own injection)"
# worker_deliver_detect_claim() is the only piece of this feature that can
# ever observe this path: it never sends /quit itself, it just notices,
# across sweeps, that a brief it previously saw genuinely pending while the
# window sat parked in "cli" state has since vanished without
# maybe_worker_deliver_brief's own auto_deliver success having claimed
# credit for it (that path clears WORKER_DELIVER_PENDING_SEEN itself — see
# Test 6's double-log check above). Simulated here by moving the brief out
# of inbox/ directly — standing in for the operator attaching and running
# /quit by hand, which is indistinguishable from any other release of the
# parked session from this script's point of view.
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]' 'WORKER_DELIVER_PENDING_SEEN[42]'
: > "$EVENTS_LOG"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
BRIEF_FILE3="$INBOX_DIR/20260826-170000-42.md"
echo "a brief a human will manually release" > "$BRIEF_FILE3"
set_current_task "t5" "ready-for-review"   # current task already finished

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane, brief pending -> cli" "cli" "worker_pane_state '$WIN'"

# First sweep: DRY_RUN, so this only observes and remembers the pending
# brief via worker_deliver_detect_claim — it never actually delivers it.
DRY_RUN=1 maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.ok' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "first sweep just observes the pending brief -> no worker.deliver.ok yet" "missing" "$got"

# The human's manual /quit + the listener's own claim_next_task, standing in
# for keystrokes this test never actually sends.
mv "$BRIEF_FILE3" "$PROCESSING_DIR/$(basename "$BRIEF_FILE3")"

# Second sweep: the window is still (or again) parked in "cli" — e.g. the
# listener's freshly relaunched agent going idle — but the brief this
# script itself never touched is now gone.
maybe_worker_deliver_brief "$WIN"
if grep -qF "worker.deliver.ok" "$EVENTS_LOG" \
    && grep -qF "brief=$(basename "$BRIEF_FILE3") release=listener_claim_after_quit" "$EVENTS_LOG"; then
    got=logged
else
    got=missing
fi
check "worker.deliver.ok logged with release=listener_claim_after_quit once the brief vanishes on its own (issue #437)" "logged" "$got"

heading "Test 9b: worker.deliver.ok never fires for a 'shell'-state window's routine self-heal (issue #43 traffic, not a stall recovery)"
unset 'WORKER_DELIVER_PENDING_SEEN[42]'
: > "$EVENTS_LOG"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "sleep 300" Enter
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
check_eventually "back to the listener's own idle bash shell -> shell" "shell" "worker_pane_state '$WIN'"
BRIEF_FILE4="$INBOX_DIR/20260826-180000-42.md"
echo "a brief the listener's own idle loop claims on its own" > "$BRIEF_FILE4"
maybe_worker_deliver_brief "$WIN"   # sweep #1: sees "shell" -> never calls detect_claim at all
mv "$BRIEF_FILE4" "$PROCESSING_DIR/$(basename "$BRIEF_FILE4")"   # the idle loop's own ordinary claim
maybe_worker_deliver_brief "$WIN"   # sweep #2: still "shell" -> same, nothing to detect
if grep -q 'worker.deliver.ok' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "a 'shell'-state window's own routine claim is never mislabeled listener_claim_after_quit" "missing" "$got"

heading "Test 10: composer chrome recognition (issue #436) — recap/spinner residue/clear-hint below an empty composer must not read as a human draft"
# The corpusminder-spring 2026-09-18/19 incident this closes: a read-only
# capture-worker.sh dump during a 1,812-skip/~14h stall showed an apparently
# EMPTY composer (❯), with a "※ recap:" line, "Baked for 31m" spinner
# residue, and a "new task? /clear to save 257.5k tokens" hint ALSO on
# screen — any one of which can land as the pane's own trimmed LAST line
# (below the composer, same shape issue #440 fixed for the mode-footer/
# box-drawing-rule case) and make compact_composer_clear misread a
# genuinely empty composer as dirty forever.
render_pane() {
    tmux send-keys -t "$SESSION_NAME:$WIN" C-c
    sleep 0.2
    tmux send-keys -t "$SESSION_NAME:$WIN" "clear; printf '$1'; sleep 300" Enter
    check_eventually "pane renders the fixture -> cli" "cli" "worker_pane_state '$WIN'"
}

render_pane '❯ \n✻ Baked for 31m\n'
rc=0; compact_composer_clear "$SESSION_NAME:$WIN" || rc=$?
check "spinner past-tense residue below an empty composer -> still reads clear" "0" "$rc"

render_pane '❯ \n※ recap: did some stuff\n'
rc=0; compact_composer_clear "$SESSION_NAME:$WIN" || rc=$?
check "recap line below an empty composer -> still reads clear" "0" "$rc"

render_pane '❯ \nnew task? /clear to save 257.5k tokens\n'
rc=0; compact_composer_clear "$SESSION_NAME:$WIN" || rc=$?
check "wrapped '/clear to save Nk tokens' hint below an empty composer -> still reads clear" "0" "$rc"

render_pane '※ recap: did some stuff\n✻ Baked for 31m\n❯ \nnew task? /clear to save 257.5k tokens\n'
rc=0; compact_composer_clear "$SESSION_NAME:$WIN" || rc=$?
check "the full observed incident shape (recap + spinner + empty composer + clear-hint) -> reads clear" "0" "$rc"

# Regression guard: none of the above may over-match a GENUINE typed draft.
render_pane '❯ please review PR 42\n'
rc=0; compact_composer_clear "$SESSION_NAME:$WIN" || rc=$?
check "a real typed draft still reads dirty (no over-matching from the new chrome patterns)" "1" "$rc"

# Independent-review finding (issue #436): the verb list above was
# originally an UNANCHORED substring match, so a genuine human draft that
# happened to CONTAIN one of those phrases (not just render below an
# actually-empty composer) would itself read as chrome and get dropped —
# the inverse failure from the one this issue exists to fix: a real draft
# misread as clear, papered over by an auto-/quit. Anchoring the verb group
# behind the spinner glyph (COMPACT_COMPOSER_CHROME_PATTERN's own comment)
# closes this without giving up matching the genuine chrome shapes above.
render_pane '❯ I baked for hours on this bug, need a second pair of eyes\n'
rc=0; compact_composer_clear "$SESSION_NAME:$WIN" || rc=$?
check "a draft merely MENTIONING a spinner-verb phrase still reads dirty (verb list is anchored to the glyph, not a bare substring match)" "1" "$rc"
unset -f render_pane

heading "Test 11: composer_not_clear escalation (issue #436) — N consecutive skips against the SAME brief escalate exactly once"
unset 'WORKER_DELIVER_COMPOSER_STALL_BRIEF[42]' 'WORKER_DELIVER_COMPOSER_STALL_COUNT[42]' 'WORKER_DELIVER_COMPOSER_STALL_ESCALATED[42]'
rm -rf "$COORD_INBOX_DIR"; mkdir -p "$COORD_INBOX_DIR"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json
: > "$EVENTS_LOG"
STALL_BRIEF="$INBOX_DIR/20260919-000000-42.md"
echo "a stuck brief" > "$STALL_BRIEF"
set_current_task "tstall" "ready-for-review"   # current task already finished, so this reaches the composer check
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane, stuck brief pending -> cli" "cli" "worker_pane_state '$WIN'"

compact_composer_clear() { return 1; }   # force composer_not_clear every sweep, same trick as Test 4
WORKER_DELIVER_COMPOSER_STALL_THRESHOLD=3

for i in 1 2 3; do maybe_worker_deliver_brief "$WIN"; done
check "3 consecutive skips logged" "3" "$(grep -c 'worker.deliver.skip.*reason=composer_not_clear' "$EVENTS_LOG")"
check "escalation logged exactly once, with skips=3" "1" "$(grep -cF 'worker.deliver.composer_stalled' "$EVENTS_LOG")"
if grep -qF "issue=42 brief=$(basename "$STALL_BRIEF") skips=3" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "escalation event names the stuck issue, brief, and skip count" "logged" "$got"
check "escalation durably written to the coordinator inbox (issue #430)" "1" "$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d '[:space:]')"

# A 4th consecutive skip against the SAME brief must not re-escalate.
maybe_worker_deliver_brief "$WIN"
check "4th consecutive skip -> escalation still logged only once (not every sweep)" "1" "$(grep -cF 'worker.deliver.composer_stalled' "$EVENTS_LOG")"
check "no second coord-inbox write for the same streak" "1" "$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d '[:space:]')"

# A DIFFERENT brief landing means the prior stall is moot — the streak
# resets rather than inheriting the count, and does not immediately
# re-escalate on its first skip.
rm -f "$INBOX_DIR"/*.md
NEW_BRIEF="$INBOX_DIR/20260919-010000-42.md"
echo "a different, fresh brief" > "$NEW_BRIEF"
maybe_worker_deliver_brief "$WIN"
check "new brief resets the streak to 1" "1" "${WORKER_DELIVER_COMPOSER_STALL_COUNT[42]}"
check "no re-escalation on the first skip against a new brief" "1" "$(grep -cF 'worker.deliver.composer_stalled' "$EVENTS_LOG")"

# Self-review finding: the streak is NOT reset by a sweep that skips for a
# DIFFERENT reason (pane_busy here) — only a different brief resets it.
# Without this, an occasional busy tick interleaved with an otherwise-stuck
# composer would keep pushing the threshold out of reach.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo '✻ Considering… (esc to interrupt)'; sleep 300" Enter
check_eventually "busy chrome visible -> worker_pane_busy true" "busy" 'busy_or_idle'
maybe_worker_deliver_brief "$WIN"
if grep -q 'worker.deliver.skip.*reason=pane_busy' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "interleaved pane_busy skip logged" "skipped" "$got"
check "pane_busy skip leaves the composer-stall streak untouched (still 1, not reset to 0)" "1" "${WORKER_DELIVER_COMPOSER_STALL_COUNT[42]}"

# Back to idle+empty-composer (still stubbed dirty): the streak resumes from
# where it left off (1 -> 2 -> 3) and re-escalates for this NEW brief once
# it independently reaches the threshold — a second, distinct escalation,
# not a stale re-fire of the first brief's already-handled one.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane restored -> cli" "cli" "worker_pane_state '$WIN'"
maybe_worker_deliver_brief "$WIN"
maybe_worker_deliver_brief "$WIN"
check "streak resumed across the interleaved busy skip -> reached 3 for the new brief" "3" "${WORKER_DELIVER_COMPOSER_STALL_COUNT[42]}"
check "new brief's own stall escalates independently -> 2 distinct composer_stalled events total" "2" "$(grep -cF 'worker.deliver.composer_stalled' "$EVENTS_LOG")"
if grep -qF "issue=42 brief=$(basename "$NEW_BRIEF") skips=3" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "the second escalation names the NEW brief, not the original stalled one" "logged" "$got"

unset -f compact_composer_clear
body="$(extract_fn compact_composer_clear)"; eval "$body"   # restore the real function
unset 'WORKER_DELIVER_COMPOSER_STALL_BRIEF[42]' 'WORKER_DELIVER_COMPOSER_STALL_COUNT[42]' 'WORKER_DELIVER_COMPOSER_STALL_ESCALATED[42]'
WORKER_DELIVER_COMPOSER_STALL_THRESHOLD=20

# Stop the relaunch loop before Test 12 drops the pane back to a plain bash
# shell — nothing else in the suite reuses $WIN after that.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2

heading "Test 12: shell-state stall escalation (issue #559) — a brief pending behind a fully parked idle-bash window escalates after N sweeps, never via a keystroke"
unset 'WORKER_DELIVER_SHELL_STALL_BRIEF[42]' 'WORKER_DELIVER_SHELL_STALL_COUNT[42]' 'WORKER_DELIVER_SHELL_STALL_ESCALATED[42]'
rm -rf "$COORD_INBOX_DIR"; mkdir -p "$COORD_INBOX_DIR"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json
: > "$EVENTS_LOG"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear" Enter
check_eventually "pane back at a plain bash prompt -> shell" "shell" "worker_pane_state '$WIN'"

STALL_BRIEF="$INBOX_DIR/20261006-005420-42.md"
echo "a follow-up brief queued behind a parked idle shell" > "$STALL_BRIEF"

WORKER_DELIVER_SHELL_STALL_THRESHOLD=3
for i in 1 2 3; do maybe_worker_deliver_brief "$WIN"; done
check "no per-sweep worker.deliver.skip noise for routine 'shell' traffic (issue #43 self-heal is still assumed by default)" "0" "$(grep -c 'worker.deliver.skip' "$EVENTS_LOG")"
check "nothing claimed, nothing retracted, no keystroke sent — the pane is untouched" "0" "$(grep -cE 'worker.deliver.(attempt|ok|timeout|retracted)' "$EVENTS_LOG")"
check "escalation logged exactly once, with skips=3" "1" "$(grep -cF 'worker.deliver.shell_stall' "$EVENTS_LOG")"
if grep -qF "issue=42 brief=$(basename "$STALL_BRIEF") skips=3" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "escalation event names the stuck issue, brief, and skip count" "logged" "$got"
check "escalation durably written to the coordinator inbox (issue #430)" "1" "$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d '[:space:]')"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "the brief is still sitting untouched in inbox/ (escalation only, never a blind keystroke)" "0" "$rc"

# A 4th consecutive sweep against the SAME brief must not re-escalate.
maybe_worker_deliver_brief "$WIN"
check "4th consecutive sweep -> escalation still logged only once (not every sweep)" "1" "$(grep -cF 'worker.deliver.shell_stall' "$EVENTS_LOG")"

# The brief being claimed (by a real self-heal, or a human) clears the
# streak rather than leaving a stale ESCALATED flag behind for whatever
# brief lands here next.
rm -f "$INBOX_DIR"/*.md
maybe_worker_deliver_brief "$WIN"
check "brief claimed -> shell-stall bookkeeping clears itself" "" "${WORKER_DELIVER_SHELL_STALL_COUNT[42]:-}"

# A DIFFERENT brief landing afterward starts its own fresh streak rather
# than inheriting the already-escalated one.
NEW_BRIEF="$INBOX_DIR/20261006-010000-42.md"
echo "a second, unrelated follow-up brief" > "$NEW_BRIEF"
maybe_worker_deliver_brief "$WIN"
check "new brief starts its own streak at 1" "1" "${WORKER_DELIVER_SHELL_STALL_COUNT[42]}"
check "no re-escalation on the first sweep against a new brief" "1" "$(grep -cF 'worker.deliver.shell_stall' "$EVENTS_LOG")"

rm -f "$INBOX_DIR"/*.md "$NEW_BRIEF"
unset 'WORKER_DELIVER_SHELL_STALL_BRIEF[42]' 'WORKER_DELIVER_SHELL_STALL_COUNT[42]' 'WORKER_DELIVER_SHELL_STALL_ESCALATED[42]'
WORKER_DELIVER_SHELL_STALL_THRESHOLD=20

heading "Test 13: task_not_terminal stall escalation (issue #601) — a brief stuck behind a current task that never confirms terminal escalates after N sweeps"
unset 'WORKER_DELIVER_TERMINAL_STALL_BRIEF[42]' 'WORKER_DELIVER_TERMINAL_STALL_COUNT[42]' 'WORKER_DELIVER_TERMINAL_STALL_ESCALATED[42]'
rm -rf "$COORD_INBOX_DIR"; mkdir -p "$COORD_INBOX_DIR"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json

# Same idle, empty-composer pane as Test 3's final case — the ONLY reason
# delivery should be skipped here is the current task never confirming
# terminal (the iss-1175 stall: worker_task_done() thought it was done,
# worker_current_task_terminal() never agreed, and nothing else escalated).
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane -> cli" "cli" "worker_pane_state '$WIN'"

# "in-progress", not "blocked": since issue #578, blocked is itself
# terminal-for-delivery, so it no longer reproduces a task_not_terminal
# stall — any other genuinely non-terminal state still does.
STALL_BRIEF="$INBOX_DIR/20261012-000000-42.md"
echo "a follow-up brief queued behind a current task stuck non-terminal" > "$STALL_BRIEF"
set_current_task "t1" "in-progress"

WORKER_DELIVER_TERMINAL_STALL_THRESHOLD=3
: > "$EVENTS_LOG"
for i in 1 2 3; do maybe_worker_deliver_brief "$WIN"; done
check "3 consecutive task_not_terminal skips logged" "3" "$(grep -cF 'worker.deliver.skip issue=42 reason=task_not_terminal' "$EVENTS_LOG")"
check "escalation logged exactly once, with skips=3" "1" "$(grep -cF 'worker.deliver.terminal_stalled' "$EVENTS_LOG")"
if grep -qF "issue=42 brief=$(basename "$STALL_BRIEF") skips=3" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "escalation event names the stuck issue, brief, and skip count" "logged" "$got"
check "escalation durably written to the coordinator inbox (issue #430)" "1" "$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d '[:space:]')"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "the brief is still sitting untouched in inbox/ (escalation only, never a blind keystroke)" "0" "$rc"

# A 4th consecutive sweep against the SAME brief must not re-escalate.
maybe_worker_deliver_brief "$WIN"
check "4th consecutive sweep -> escalation still logged only once (not every sweep)" "1" "$(grep -cF 'worker.deliver.terminal_stalled' "$EVENTS_LOG")"

# The current task finally confirming terminal (status flips to
# ready-for-review) clears the streak and lets delivery proceed, rather than
# leaving a stale ESCALATED flag behind for whatever brief lands here next.
set_current_task "t1" "ready-for-review"
maybe_worker_deliver_brief "$WIN"
check "task confirms terminal -> terminal-stall bookkeeping clears itself" "" "${WORKER_DELIVER_TERMINAL_STALL_COUNT[42]:-}"
if grep -q 'worker.deliver.attempt' "$EVENTS_LOG"; then got=attempted; else got=notattempted; fi
check "once terminal, delivery is attempted on the very next sweep (issue #601: no self-heal gap once confirmed)" "attempted" "$got"

rm -f "$INBOX_DIR"/*.md "$STALL_BRIEF"
unset 'WORKER_DELIVER_TERMINAL_STALL_BRIEF[42]' 'WORKER_DELIVER_TERMINAL_STALL_COUNT[42]' 'WORKER_DELIVER_TERMINAL_STALL_ESCALATED[42]'
WORKER_DELIVER_TERMINAL_STALL_THRESHOLD=20

heading "Test 14: give-up stall escalation (issue #600) — a window stuck at the give-up gate re-surfaces after N sweeps instead of staying silently stuck forever behind its one-time WARNING"
# Unlike composer_stalled/shell_stall/terminal_stalled (Tests 10-13), the
# give-up gate logs NOTHING per-sweep on its own, not even a
# worker.deliver.skip — that silence is exactly what made issue #600's
# incidents invisible for hours. How WORKER_DELIVER_GAVE_UP gets set this
# way is already covered by Test 5; this test is only about what happens
# AFTER it's set and a brief stays stuck behind it.
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]' 'WORKER_DELIVER_PENDING_SEEN[42]'
unset 'WORKER_DELIVER_GAVE_UP_STALL_BRIEF[42]' 'WORKER_DELIVER_GAVE_UP_STALL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP_STALL_ESCALATED[42]'
rm -rf "$COORD_INBOX_DIR"; mkdir -p "$COORD_INBOX_DIR"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md "$STATUS_DIR"/*.json
: > "$EVENTS_LOG"

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "idle, empty-composer pane -> cli" "cli" "worker_pane_state '$WIN'"
set_current_task "t7" "ready-for-review"   # current task already finished

WORKER_DELIVER_LAST_FAIL[42]=$(date +%s)
WORKER_DELIVER_FAIL_COUNT[42]=3
WORKER_DELIVER_GAVE_UP[42]=1
STALL_BRIEF="$INBOX_DIR/20261020-000000-42.md"
echo "a brief stuck behind a window that has already given up" > "$STALL_BRIEF"

WORKER_DELIVER_GAVE_UP_STALL_THRESHOLD=3
for i in 1 2 3; do maybe_worker_deliver_brief "$WIN"; done
check "the give-up gate logs NOTHING per-sweep on its own (issue #600: this silence is what made the original stalls invisible)" "0" "$(grep -cE 'worker\.deliver\.(skip|attempt|ok|timeout)' "$EVENTS_LOG")"
check "escalation logged exactly once, with skips=3" "1" "$(grep -cF 'worker.deliver.gave_up_stalled' "$EVENTS_LOG")"
if grep -qF "issue=42 brief=$(basename "$STALL_BRIEF") skips=3" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "escalation event names the stuck issue, brief, and skip count" "logged" "$got"
check "escalation durably written to the coordinator inbox (issue #430)" "1" "$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d '[:space:]')"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "the brief is still sitting untouched in inbox/ (escalation only, never a blind keystroke)" "0" "$rc"
check "WORKER_DELIVER_GAVE_UP itself is untouched by the escalation -- only a real success clears it" "1" "${WORKER_DELIVER_GAVE_UP[42]:-}"

# A 4th consecutive sweep against the SAME brief must not re-escalate.
maybe_worker_deliver_brief "$WIN"
check "4th consecutive sweep -> escalation still logged only once (not every sweep)" "1" "$(grep -cF 'worker.deliver.gave_up_stalled' "$EVENTS_LOG")"

# issue #653 (self-review on #600's PR): a human manually releasing the
# session (listener_claim_after_quit) must NOT clear GAVE_UP or the
# gave-up-stall bookkeeping — only a GENUINE late success of this script's
# OWN /quit (release=auto_deliver late=1, Test 7c) does that. Before this
# fix, both paths called worker_deliver_record_success, which re-armed
# automatic /quit delivery on a window whose agent never recognizes /quit
# at all — see Test 15 below for the concrete consequence that guards
# against (a fresh round of live /quit injections right after a human just
# manually released the same stuck session).
mv "$STALL_BRIEF" "$PROCESSING_DIR/$(basename "$STALL_BRIEF")"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "pane parked in cli again after the manual release" "cli" "worker_pane_state '$WIN'"
maybe_worker_deliver_brief "$WIN"
if grep -qF "brief=$(basename "$STALL_BRIEF") release=listener_claim_after_quit" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "the manual release is still correctly attributed" "logged" "$got"
check "...but GAVE_UP is NOT cleared by a human release (issue #653)" "1" "${WORKER_DELIVER_GAVE_UP[42]:-}"
check "...and the gave-up-stall bookkeeping is untouched too" "4" "${WORKER_DELIVER_GAVE_UP_STALL_COUNT[42]:-}"

rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]'
unset 'WORKER_DELIVER_GAVE_UP_STALL_BRIEF[42]' 'WORKER_DELIVER_GAVE_UP_STALL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP_STALL_ESCALATED[42]'
WORKER_DELIVER_GAVE_UP_STALL_THRESHOLD=20

heading "Test 15: issue #653 — a listener_claim_after_quit for an UNRELATED brief must not re-arm /quit delivery on a window whose agent never recognizes /quit"
# The exact regression the coordinator's review caught: #600's fix made
# worker_deliver_detect_claim call worker_deliver_record_success on BOTH its
# success branches, including listener_claim_after_quit. Realistic shape:
# brief A times out 3x against a FAKE_REPL2-shaped agent (never recognizes
# /quit) -> GAVE_UP=1, TIMED_OUT_BRIEF=A — and A then sits stuck forever
# (this agent shape never lets A resolve via auto_deliver OR a plain human
# /quit, since neither this script's paste nor a typed /quit does anything
# but echo back as an ordinary line; the only way out is killing the
# session outright). The operator abandons A directly (deletes the stale
# inbox file without it ever reaching processing/ — exactly the possibility
# worker_deliver_detect_claim's own header comment names: "an operator
# deleting the stale brief outright"), so no late=1 event is ever logged
# for it — GAVE_UP/TIMED_OUT_BRIEF=A stay exactly as the giving_up left
# them. A completely unrelated brief B is then queued and delivered the
# ordinary way (a human attaches, runs /quit, ends the session — ordinary
# listener_claim_after_quit, since B != TIMED_OUT_BRIEF=A). Under the
# pre-#653 code this ALSO reset GAVE_UP/LAST_FAIL/FAIL_COUNT, wiping the
# coordinator's only memory that THIS window's agent doesn't honor /quit —
# so the NEXT brief C would get a fresh live /quit injection anyway, 3 more
# timeouts, and a second giving_up. This test proves that no longer
# happens: GAVE_UP survives B's unrelated delivery, and C gets no
# injection at all.
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]' 'WORKER_DELIVER_TIMED_OUT_BRIEF[42]' 'WORKER_DELIVER_PENDING_SEEN[42]'
unset 'WORKER_DELIVER_GAVE_UP_STALL_BRIEF[42]' 'WORKER_DELIVER_GAVE_UP_STALL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP_STALL_ESCALATED[42]'
: > "$EVENTS_LOG"
rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
BRIEF_A="$INBOX_DIR/20261020-100000-42.md"
echo "brief A: will time out 3 times in a row against an agent that never recognizes /quit" > "$BRIEF_A"
set_current_task "t15a" "ready-for-review"   # current task already finished

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
tmux send-keys -t "$SESSION_NAME:$WIN" "bash -c 'exec -a gemini bash $FAKE_REPL2'" Enter
check_eventually "fake non-quitting REPL foreground -> cli" "cli" "worker_pane_state '$WIN'"

WORKER_DELIVER_BACKOFF_SECS=0   # the real 600s default would skip attempts 2/3 as backoff, never reaching 3 failures
for i in 1 2 3; do
    WORKER_DELIVER_END_TIMEOUT_SECS=3 WORKER_DELIVER_POLL_SECS=1 maybe_worker_deliver_brief "$WIN"
done
WORKER_DELIVER_BACKOFF_SECS=600
check "3 consecutive timeouts against brief A -> gave up" "1" "${WORKER_DELIVER_GAVE_UP[42]:-}"
check "A is recorded as the timed-out brief" "$(basename "$BRIEF_A")" "${WORKER_DELIVER_TIMED_OUT_BRIEF[42]:-}"

# The operator abandons brief A directly (rm, not mv to processing/) -- it
# never resolves via auto_deliver or any /quit, consistent with this fake
# REPL never honoring /quit at all. Brief B, wholly unrelated to A, is
# queued immediately after.
rm -f "$BRIEF_A"
BRIEF_B="$INBOX_DIR/20261020-103000-42.md"
echo "brief B: unrelated to A, will be delivered by an ordinary human /quit" > "$BRIEF_B"
maybe_worker_deliver_brief "$WIN"
if grep -qF "worker.deliver.ok" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "A's silent disappearance (never reaching processing/) logs no success of any kind" "missing" "$got"
check "GAVE_UP/TIMED_OUT_BRIEF untouched by A's abandonment" "$(basename "$BRIEF_A")" "${WORKER_DELIVER_TIMED_OUT_BRIEF[42]:-}"

# Brief B now gets an ordinary human-attended /quit (same simulation
# Test 9/14 use: move the brief out of inbox/ directly, standing in for the
# operator attaching and running /quit by hand).
mv "$BRIEF_B" "$PROCESSING_DIR/$(basename "$BRIEF_B")"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'; printf '❯ \n'; sleep 300" Enter
check_eventually "pane parked in cli again after B's manual release" "cli" "worker_pane_state '$WIN'"
maybe_worker_deliver_brief "$WIN"
if grep -qF "brief=$(basename "$BRIEF_B") release=listener_claim_after_quit" "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "B's delivery is attributed to a human, not auto_deliver" "logged" "$got"
check "GAVE_UP survives B's unrelated human-attended delivery (issue #653's fix)" "1" "${WORKER_DELIVER_GAVE_UP[42]:-}"

# A brand-new brief C is now queued behind this same, still-given-up
# window. With the bug, B's delivery would have cleared GAVE_UP, so C would
# trigger a fresh live /quit injection here; with the fix, it must not.
set_current_task "t15b" "ready-for-review"
: > "$EVENTS_LOG"
BRIEF_C="$INBOX_DIR/20261020-110000-42.md"
echo "brief C: queued right after B's unrelated human-attended release" > "$BRIEF_C"
for i in 1 2 3; do maybe_worker_deliver_brief "$WIN"; done
check "no /quit injection is attempted against the still-given-up window" "0" "$(grep -cF 'worker.deliver.attempt' "$EVENTS_LOG")"
rc=0; worker_pending_brief "$WT_DIR" || rc=$?
check "brief C is left untouched in inbox/, not swallowed" "0" "$rc"

rm -f "$INBOX_DIR"/*.md "$PROCESSING_DIR"/*.md
unset 'WORKER_DELIVER_LAST_FAIL[42]' 'WORKER_DELIVER_FAIL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP[42]' 'WORKER_DELIVER_TIMED_OUT_BRIEF[42]'
unset 'WORKER_DELIVER_GAVE_UP_STALL_BRIEF[42]' 'WORKER_DELIVER_GAVE_UP_STALL_COUNT[42]' 'WORKER_DELIVER_GAVE_UP_STALL_ESCALATED[42]'
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2

echo
green "All $PASS checks passed."
