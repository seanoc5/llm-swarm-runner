#!/usr/bin/env bash
#
# test-worker-auto-compact.sh — Tests for coordinator-watch.sh's
# WORKER_AUTO_COMPACT feature (issue #226): the AUTO_COMPACT pattern
# generalized to every `iss-*` worker window, so a worker running a
# 1M-context-window model doesn't cruise past the quality "dumb zone"
# untouched by Claude Code's built-in (window-fill-keyed) auto-compact.
#
# Same rationale and technique as test-coordinator-auto-compact.sh: these
# units (worker_pane_state, worker_pane_busy, worker_pane_ctx_used,
# worker_has_open_pr, maybe_worker_compact) call tmux directly and parse
# rendered pane text — no PATH-stubbable seam — so this extracts the
# function bodies verbatim from the real script (sed, not a hand-retyped
# copy — see extract_fn below) and exercises them against a real
# (throwaway) tmux session.
#
# Key difference from the coordinator feature under test: there is no probe
# file here (a worker's statusline runs inside its docker container and
# writes to a path the host can't see), so worker_pane_ctx_used parses
# statusline-with-context.sh's rendered "ctx: <used>/<total> (<pct>%)" text
# straight out of `tmux capture-pane` instead.
#
# Requires: tmux, jq (both already required by the feature itself).
#
# The tmux() shadow function near Test 10 is defined mid-file on purpose:
# calls above it hit the real tmux binary, calls below it (until unset -f)
# hit the stub. shellcheck's SC2218 flags every call above the definition
# as if it were a forward-reference bug, so it's disabled file-wide here.
# shellcheck disable=SC2218
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

TEST_DIR=$(mktemp -d -t worker-auto-compact-XXXXXX)
SESSION_NAME="test-worker-compact-$$"
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
for fn in worker_pane_state worker_pane_busy worker_pane_ctx_used worker_pane_ctx_window \
          worker_compact_effective_threshold worker_has_open_pr \
          worker_task_done worker_compact_record_failure worker_compact_record_success \
          maybe_worker_compact log_event; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done

# ─────────────────────────── fixed env the functions expect ────────────────
EVENTS_LOG="$TEST_DIR/events.log"; : > "$EVENTS_LOG"
HAVE_JQ=1
DRY_RUN=1
WORKER_AUTO_COMPACT=1
WORKER_COMPACT_PCT=75
WORKER_COMPACT_THRESHOLD_CAP_TOKENS=250000
WORKER_COMPACT_THRESHOLD_TOKENS=150000
WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS=300000
# issue #252: must match coordinator-watch.sh's own default — anchored on
# the "(esc to interrupt)" hint instead of a spinner-verb list (see that
# file's AUTO_COMPACT_BUSY_PATTERN header comment for why).
WORKER_COMPACT_BUSY_PATTERN='\(esc to interrupt\)|Press Ctrl-C again to .xit'
WORKER_COMPACT_START_TIMEOUT_SECS=15
WORKER_COMPACT_FINISH_TIMEOUT_SECS=300
WORKER_COMPACT_VERIFY_TIMEOUT_SECS=30
WORKER_COMPACT_POLL_SECS=2
WORKER_COMPACT_NUDGE_PROMPT="Continue your task from where you left off."
WORKER_COMPACT_BACKOFF_SECS=600
WORKER_COMPACT_MAX_FAILURES=3
declare -A WORKER_COMPACT_LAST_FAIL=()
declare -A WORKER_COMPACT_FAIL_COUNT=()
declare -A WORKER_COMPACT_GAVE_UP=()

WORKSPACE="$TEST_DIR/workspace"
WT_DIR="$WORKSPACE/wt-issue-42"
STATUS_DIR="$WT_DIR/.swarm/tasks/status"
DONE_DIR="$WT_DIR/.swarm/tasks/done"
mkdir -p "$STATUS_DIR" "$DONE_DIR"
WIN="iss-42"

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

# check_eventually — see test-coordinator-auto-compact.sh's twin for the
# rationale (polling instead of a fixed sleep to avoid a flake under load).
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

heading "Test 1: worker_pane_state"
state="$(worker_pane_state "$WIN")"
check "no session -> absent" "absent" "$state"

tmux new-session -d -s "$SESSION_NAME" -n "$WIN" 2>/dev/null
check_eventually "fresh window, bash foreground -> shell" "shell" "worker_pane_state '$WIN'"

state="$(worker_pane_state "iss-999")"
check "no such window -> absent" "absent" "$state"

tmux send-keys -t "$SESSION_NAME:$WIN" "sleep 300" Enter
check_eventually "non-shell foreground -> cli" "cli" "worker_pane_state '$WIN'"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2

heading "Test 2: worker_pane_busy"
busy_or_idle() { if worker_pane_busy "$WIN"; then echo busy; else echo idle; fi; }

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/1M (2%)'" Enter
check_eventually "idle-looking text -> not busy" "idle" 'busy_or_idle'

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo '✻ Considering… (esc to interrupt)'" Enter
check_eventually "spinner text -> busy" "busy" 'busy_or_idle'

# issue #252 mode 1 (missing verbs): a present-tense verb Claude Code hasn't
# rendered before still counts as busy, because detection no longer keys off
# a fixed verb list — it's anchored on the "(esc to interrupt)" hint that
# accompanies EVERY in-flight turn regardless of wording.
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo '✻ Cogitated for 3s (esc to interrupt)'" Enter
check_eventually "unlisted verb + esc-to-interrupt -> still busy (issue #252 mode 1)" "busy" 'busy_or_idle'

# issue #252 mode 2 (past-tense scrollback): a completed turn's leftover
# summary line ("Simmered for 12s", no "(esc to interrupt)" — the turn is
# over) must NOT read as busy. The old verb-list pattern matched this text
# unconditionally and produced a false-busy skip.
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo '✻ Simmered for 12s'" Enter
check_eventually "past-tense completed-turn text (no esc-hint) -> idle, not busy (issue #252 mode 2)" "idle" 'busy_or_idle'

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'Press Ctrl-C again to exit'" Enter
check_eventually "exit-confirm text -> busy (guarded against a stray Enter)" "busy" 'busy_or_idle'

heading "Test 3: worker_pane_ctx_used (parsing the rendered statusline, no probe file)"
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'no statusline here'" Enter
sleep 0.3
rc=0; out="$(worker_pane_ctx_used "$WIN")" || rc=$?
check "no ctx text on screen -> rc1" "1" "$rc"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 160k/1M (16%)'" Enter
check_eventually "k-suffixed ctx -> used=160000" "160000" "worker_pane_ctx_used '$WIN'"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 1M/1M (100%)'" Enter
check_eventually "M-suffixed ctx -> used=1000000" "1000000" "worker_pane_ctx_used '$WIN'"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 850/1M (0%)'" Enter
check_eventually "unsuffixed (sub-1k) ctx -> used=850" "850" "worker_pane_ctx_used '$WIN'"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: ?'" Enter
sleep 0.3
rc=0; out="$(worker_pane_ctx_used "$WIN")" || rc=$?
check "unparseable '?' fallback -> rc1" "1" "$rc"

heading "Test 3b: worker_pane_ctx_window (parsing the statusline denominator, issue #259)"
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 160k/1M (16%)'" Enter
check_eventually "M-suffixed window -> window=1000000" "1000000" "worker_pane_ctx_window '$WIN'"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/200k (10%)'" Enter
check_eventually "k-suffixed window -> window=200000" "200000" "worker_pane_ctx_window '$WIN'"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'no statusline here'" Enter
sleep 0.3
rc=0; out="$(worker_pane_ctx_window "$WIN")" || rc=$?
check "no ctx text on screen -> rc1" "1" "$rc"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: ?'" Enter
sleep 0.3
rc=0; out="$(worker_pane_ctx_window "$WIN")" || rc=$?
check "unparseable '?' fallback -> rc1" "1" "$rc"

heading "Test 3c: worker_compact_effective_threshold — min(pct-of-window, cap) + gap-preserving wrap-up (issue #259)"
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 20k/200k (10%)'" Enter
check_eventually "200k-window worker settles on screen" "200000" "worker_pane_ctx_window '$WIN'"
read -r base wrapup < <(worker_compact_effective_threshold "$WIN")
check "200k window: base = 75% of window (150000), under the 250000 cap" "150000" "$base"
check "200k window: wrap-up preserves the 150000 default gap -> 300000 (today's unchanged behavior)" "300000" "$wrapup"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 260k/1M (26%)'" Enter
check_eventually "1M-window worker settles on screen" "1000000" "worker_pane_ctx_window '$WIN'"
read -r base wrapup < <(worker_compact_effective_threshold "$WIN")
check "1M window: 75% (750000) exceeds the cap -> clamped to 250000" "250000" "$base"
check "1M window: wrap-up = scaled base + preserved 150000 gap -> 400000 (not the stale flat 300000)" "400000" "$wrapup"

tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'no statusline here'" Enter
sleep 0.3
read -r base wrapup < <(worker_compact_effective_threshold "$WIN")
check "unparseable window -> base falls back to flat WORKER_COMPACT_THRESHOLD_TOKENS (150000)" "150000" "$base"
check "unparseable window -> wrap-up falls back to flat WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS (300000)" "300000" "$wrapup"

heading "Test 4: worker_has_open_pr"
rm -f "$STATUS_DIR"/*.json
rc=0; worker_has_open_pr "$WT_DIR" || rc=$?
check "no status files -> rc1 (no PR)" "1" "$rc"

printf '{"task_id":"t1","state":"blocked","pr":null,"ts":"2026-01-01T00:00:00Z","note":"waiting on input"}' \
    > "$STATUS_DIR/t1.json"
rc=0; worker_has_open_pr "$WT_DIR" || rc=$?
check "status file with pr=null -> rc1 (no PR)" "1" "$rc"

printf '{"task_id":"t1","state":"ready-for-review","pr":555,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t1.json"
rc=0; worker_has_open_pr "$WT_DIR" || rc=$?
check "status file with pr=555 -> rc0 (open PR)" "0" "$rc"
rm -f "$STATUS_DIR"/*.json

heading "Test 5: maybe_worker_compact threshold + wrap-up hysteresis (DRY_RUN)"
# `cat` (no args) keeps a non-shell process in the foreground (state=cli)
# while leaving the just-echoed line as the visible screen content. This
# window renders a 1M-window statusline throughout, so (issue #259, with the
# fixed-env defaults above: WORKER_COMPACT_PCT=75, CAP=250000) the effective
# base threshold is min(750000, 250000) = 250000, not the flat 150000
# WORKER_COMPACT_THRESHOLD_TOKENS fallback — see Test 3c above for that
# fallback path covered in isolation, and Test 9 below for why the
# real-injection fixture has to override the cap downward instead.
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 50k/1M (5%)'; cat" Enter
check_eventually "cat foreground -> cli (sanity check before the threshold test)" "cli" "worker_pane_state '$WIN'"

before="$(wc -l < "$EVENTS_LOG")"
maybe_worker_compact "$WIN"
after="$(wc -l < "$EVENTS_LOG")"
check "under threshold, no PR -> no compact event logged" "$before" "$after"

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 260k/1M (26%)'; cat" Enter
check_eventually "cat foreground w/ 260k ctx -> cli" "cli" "worker_pane_state '$WIN'"

maybe_worker_compact "$WIN"
if grep -q 'worker.compact ' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "260k, no PR open -> above the scaled 250k threshold (75% of 1M, capped), compact logged" "logged" "$got"

# Now with a PR open: issue #252's worker_task_done fires the moment the
# status file reports "ready-for-review" — see this file's
# WORKER_AUTO_COMPACT header comment for why that now supersedes
# WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS in the common case (worker_
# has_open_pr and worker_task_done's status check key off the same "pr"
# field). So BOTH a below-threshold 200k ctx and an above-wrap-up-threshold
# 410k ctx (the scaled 250k base + the preserved 150k gap = 400k wrap-up
# threshold; see Test 3c above) should skip below — but for the SAME reason
# (task_done), not because of a ctx/threshold comparison. Test 7 below
# covers task_done in isolation; this just confirms it also wins inside the
# full maybe_worker_compact call this test already had wired up.
printf '{"task_id":"t2","state":"ready-for-review","pr":777,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t2.json"

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 200k/1M (20%)'; cat" Enter
check_eventually "cat foreground w/ 200k ctx -> cli" "cli" "worker_pane_state '$WIN'"

: > "$EVENTS_LOG"
maybe_worker_compact "$WIN"
if grep -q 'worker.compact.skip.*reason=task_done' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "200k WITH PR open -> skipped as task_done (issue #252)" "skipped" "$got"
if grep -q 'worker.compact ' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "200k WITH PR open -> no compact injection logged" "missing" "$got"

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 410k/1M (41%)'; cat" Enter
check_eventually "cat foreground w/ 410k ctx -> cli" "cli" "worker_pane_state '$WIN'"

: > "$EVENTS_LOG"
maybe_worker_compact "$WIN"
if grep -q 'worker.compact.skip.*reason=task_done' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "410k WITH PR open -> STILL skipped as task_done, even above the scaled 400k wrap-up threshold" "skipped" "$got"
if grep -q 'worker.compact ' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "410k WITH PR open -> no compact injection logged (issue #252 supersedes the wrap-up threshold)" "missing" "$got"
rm -f "$STATUS_DIR"/*.json

heading "Test 6: worker_task_done — three independent signals + the requeue-staleness guard (issue #252)"
rm -f "$STATUS_DIR"/*.json "$DONE_DIR"/*.json 2>/dev/null || true

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 50k/1M (5%)'; cat" Enter
check_eventually "plain idle-looking pane -> cli (sanity check)" "cli" "worker_pane_state '$WIN'"

rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "no done-file, no terminal status, no completion-block text -> rc1 (not done)" "1" "$rc"

# (a) outcome file in done/
printf '{}' > "$DONE_DIR/t1.ok.json"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "(a) outcome file present in done/ -> rc0 (task done)" "0" "$rc"
rm -f "$DONE_DIR"/*.json

# staleness guard: a leftover outcome file from an EARLIER, already-concluded
# task must NOT block a NEWER task that's currently claimed (processing/
# non-empty) — otherwise every requeue.sh follow-up into a worktree that has
# ever finished once would permanently disable auto-compact for it.
PROCESSING_DIR="$WT_DIR/.swarm/tasks/processing"
mkdir -p "$PROCESSING_DIR"
printf '%s' "a newer task brief" > "$PROCESSING_DIR/t2.md"
printf '{}' > "$DONE_DIR/t1.ok.json"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "stale done-file from a PAST task + a claimed task in processing/ -> rc1 (NOT done — requeue-staleness guard)" "1" "$rc"
rm -f "$DONE_DIR"/*.json "$PROCESSING_DIR"/*.md
rmdir "$PROCESSING_DIR" 2>/dev/null || true

# (b) status file terminal state
printf '{"task_id":"t1","state":"ready-for-review","pr":555,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t1.json"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "(b) status state=ready-for-review -> rc0 (task done)" "0" "$rc"

printf '{"task_id":"t1","state":"done-no-pr","pr":null,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t1.json"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "(b) status state=done-no-pr -> rc0 (task done)" "0" "$rc"

printf '{"task_id":"t1","state":"blocked","pr":null,"ts":"2026-01-01T00:00:00Z","note":"waiting"}' \
    > "$STATUS_DIR/t1.json"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "(b) status state=blocked -> rc1 (still a normal compact candidate, NOT done)" "1" "$rc"
rm -f "$STATUS_DIR"/*.json

# (c) pane shows the listener's completion block — the only signal
# available before (a)/(b) land, so NOT gated by the processing/ guard.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; printf 'TASK COMPLETE    exit=0    duration=12s\n'; cat" Enter
check_eventually "completion-block pane foreground -> cli" "cli" "worker_pane_state '$WIN'"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "(c) pane shows TASK COMPLETE banner (no done-file/status yet) -> rc0 (task done)" "0" "$rc"

tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; printf 'TASK FAILED       exit=1    duration=9s\n'; cat" Enter
check_eventually "TASK FAILED banner pane foreground -> cli" "cli" "worker_pane_state '$WIN'"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "(c) pane shows TASK FAILED banner -> rc0 (task done)" "0" "$rc"

# Regression: an in-progress worker whose pane merely displays the phrase
# "TASK COMPLETE" (e.g. grepping/catting worker-listener.sh's own source, or
# this repo's test fixtures) must NOT be misread as done — the real
# completion block is a specific line shape ("  TASK COMPLETE    exit=0..."),
# not just the bare phrase anywhere in scrollback.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" 'clear; echo "365:        printf ..TASK COMPLETE    exit=.s.."; cat' Enter
check_eventually "source-grep-like pane text foreground -> cli" "cli" "worker_pane_state '$WIN'"
rc=0; worker_task_done "$WIN" "$WT_DIR" || rc=$?
check "phrase appears mid-line (source/grep context, not the real banner) -> rc1 (NOT done)" "1" "$rc"

heading "Test 7: maybe_worker_compact skips an over-threshold window whose task is already done"
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 260k/1M (26%)'; cat" Enter
check_eventually "cat foreground w/ 260k ctx -> cli" "cli" "worker_pane_state '$WIN'"

printf '{"task_id":"t3","state":"ready-for-review","pr":999,"ts":"2026-01-01T00:00:00Z","note":""}' \
    > "$STATUS_DIR/t3.json"
: > "$EVENTS_LOG"
maybe_worker_compact "$WIN"
if grep -q 'worker.compact.skip.*reason=task_done' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "260k, well over the scaled 250k threshold, but task_done -> skipped as task_done" "skipped" "$got"
if grep -q 'worker.compact ' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "no compact injection logged when task_done" "missing" "$got"
rm -f "$STATUS_DIR"/*.json

heading "Test 8: per-window backoff after failed injection attempts (issue #252)"
: > "$EVENTS_LOG"
unset 'WORKER_COMPACT_LAST_FAIL[42]' 'WORKER_COMPACT_FAIL_COUNT[42]' 'WORKER_COMPACT_GAVE_UP[42]'

worker_compact_record_failure 42
check "1st consecutive failure -> not yet given up" "" "${WORKER_COMPACT_GAVE_UP[42]:-}"
worker_compact_record_failure 42
check "2nd consecutive failure -> still not given up" "" "${WORKER_COMPACT_GAVE_UP[42]:-}"
if grep -q 'worker.compact.giving_up' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "no giving_up event before WORKER_COMPACT_MAX_FAILURES (3) is reached" "missing" "$got"

worker_compact_record_failure 42
check "3rd consecutive failure (MAX_FAILURES=3) -> gave up" "1" "${WORKER_COMPACT_GAVE_UP[42]:-}"
if grep -q 'worker.compact.giving_up.*issue=42 failures=3' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "worker.compact.giving_up logged exactly once, with failures=3" "logged" "$got"

# Once given up, maybe_worker_compact must stay completely silent for this
# window from then on — no repeated warnings/skip lines every sweep.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.2
tmux send-keys -t "$SESSION_NAME:$WIN" "clear; echo 'sonnet · wt-issue-42 · ctx: 200k/1M (20%)'; cat" Enter
check_eventually "cat foreground w/ 200k ctx -> cli" "cli" "worker_pane_state '$WIN'"

before="$(wc -l < "$EVENTS_LOG")"
maybe_worker_compact "$WIN"
after="$(wc -l < "$EVENTS_LOG")"
check "gave-up window: maybe_worker_compact stays silent (no new log lines)" "$before" "$after"

# A window that failed once (but hasn't hit MAX_FAILURES) cools down for
# WORKER_COMPACT_BACKOFF_SECS instead of retrying every sweep.
unset 'WORKER_COMPACT_LAST_FAIL[42]' 'WORKER_COMPACT_FAIL_COUNT[42]' 'WORKER_COMPACT_GAVE_UP[42]'
WORKER_COMPACT_LAST_FAIL[42]=$(date +%s)
: > "$EVENTS_LOG"
maybe_worker_compact "$WIN"
if grep -q 'worker.compact.skip.*reason=backoff' "$EVENTS_LOG"; then got=skipped; else got=notskipped; fi
check "recent failure timestamp -> skipped as backoff (cooldown still active)" "skipped" "$got"
if grep -q 'worker.compact ' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "no compact injection logged during the backoff cooldown" "missing" "$got"

# A real success clears all backoff/failure bookkeeping immediately.
WORKER_COMPACT_FAIL_COUNT[42]=2
worker_compact_record_success 42
check "record_success clears LAST_FAIL" "" "${WORKER_COMPACT_LAST_FAIL[42]:-}"
check "record_success clears FAIL_COUNT" "" "${WORKER_COMPACT_FAIL_COUNT[42]:-}"
check "record_success clears GAVE_UP" "" "${WORKER_COMPACT_GAVE_UP[42]:-}"

heading "Test 9: real (non-DRY_RUN) injection against a fake worker REPL"
# Stand-in for a live worker Claude Code REPL: renders its own statusline
# (no probe file, no background writer needed — unlike the coordinator
# fixture, the "before" and "after" ctx values are both rendered directly
# by this script), reads one line at a time, simulates a multi-second
# compaction on "/compact", and echoes back anything else so the test can
# confirm the post-compact nudge was actually received.
#
# Post-compact behavior is controlled by $REPL_MODE_FILE (inherited env var,
# read fresh on every "/compact") rather than baked into the script, so
# Tests 6/8/9 below can all reuse this SAME long-running process by just
# rewriting the mode file — never re-exec'ing or C-c'ing the pane's
# foreground process once it's live. That matters: this process is
# `exec`'d (replaces the pane's shell outright, same as a real worker's
# `claude` REPL), so it's the pane's ONLY process; C-c'ing it after exec
# would SIGINT-kill it, closing the pane and, since this is the session's
# only window, the whole tmux server out from under the rest of the test
# (see test-coordinator-auto-compact.sh's Test 7 comment for the same
# hazard on the coordinator side — this fixture avoids it entirely instead
# of just documenting around it).
#   drop  — lowers ctx (the happy path)
#   same  — redraws the identical value (ineffective-compaction case)
#   blank — renders no ctx line at all post-compact (verify-skip case)
FAKE_REPL="$TEST_DIR/fake-worker-repl.sh"
REPL_MODE_FILE="$TEST_DIR/repl-mode"
echo drop > "$REPL_MODE_FILE"
cat > "$FAKE_REPL" <<'REPL'
#!/usr/bin/env bash
CTX="160k/1M (16%)"
render() { echo "sonnet · wt-issue-42 · ctx: $CTX"; }
render
echo "idle-prompt >"
while IFS= read -r line; do
    # See test-coordinator-auto-compact.sh's fake REPL for why blank lines
    # (the embedded-newline artifact of a bracketed-paste-unaware `read`
    # loop) are skipped here.
    [ -z "$line" ] && continue
    if [ "$line" = "/compact" ]; then
        echo "✻ Considering… (esc to interrupt)"
        sleep 4
        clear
        mode="$(cat "$REPL_MODE_FILE" 2>/dev/null || echo drop)"
        case "$mode" in
            drop) CTX="40k/1M (4%)"; render ;;
            same) render ;;
            blank) : ;;   # no ctx line at all this render
        esac
        echo "idle-prompt >"
    else
        clear
        render
        echo "resumed: $line"
        echo "idle-prompt >"
    fi
done
REPL
chmod +x "$FAKE_REPL"

DRY_RUN=0
WORKER_COMPACT_START_TIMEOUT_SECS=10
WORKER_COMPACT_FINISH_TIMEOUT_SECS=15
WORKER_COMPACT_VERIFY_TIMEOUT_SECS=10
WORKER_COMPACT_POLL_SECS=1
# issue #259: the fixture renders a 1M-window statusline, which is now
# parseable by worker_pane_ctx_window() — so the effective threshold comes
# from min(WORKER_COMPACT_PCT% of 1M, WORKER_COMPACT_THRESHOLD_CAP_TOKENS),
# NOT the flat WORKER_COMPACT_THRESHOLD_TOKENS fallback (that only applies
# when the denominator can't be parsed — see Test 3c above for that path in
# isolation). Lower the cap below the fixture's 160k starting value so this
# real-injection timing/verify test still exercises the same mechanics it
# did pre-#259.
WORKER_COMPACT_THRESHOLD_CAP_TOKENS=100000
: > "$EVENTS_LOG"

# Test 5 left `cat` blocked in the foreground reading stdin -- interrupt it
# first (safe: `cat` is a plain command in an ordinary, non-exec'd
# interactive shell, not the pane's only process), or the exec command
# below would be fed to cat as input rather than interpreted by the shell.
tmux send-keys -t "$SESSION_NAME:$WIN" C-c
sleep 0.3
# exec -a claude sets argv[0] so pane_current_command reports "claude" (the
# real CLI's process name) rather than "bash". REPL_MODE_FILE is exported
# into the exec'd process's environment via the inline VAR=val prefix.
tmux send-keys -t "$SESSION_NAME:$WIN" "REPL_MODE_FILE=$REPL_MODE_FILE exec -a claude bash $FAKE_REPL" Enter
check_eventually "fake REPL foreground (argv[0]=claude) -> cli" "cli" "worker_pane_state '$WIN'"
check_eventually "fake REPL renders initial 160k ctx" "160000" "worker_pane_ctx_used '$WIN'"

start_ts=$(date +%s)
maybe_worker_compact "$WIN"
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

# start-wait (~0-1s) + fixture compaction (4s) + finish-wait (~0-1s) +
# verify-poll for the redraw (~0-1s) + nudge send puts this around 5-7s;
# bound generously either side.
if grep -q 'worker.compact.done' "$EVENTS_LOG" && [ "$elapsed" -ge 4 ] && [ "$elapsed" -lt 20 ]; then
    green "real /compact injection observed start->finish transition (~${elapsed}s; fixture sleeps 4s)"
    PASS=$((PASS + 1))
else
    red "did not observe expected worker.compact.done within the expected window (elapsed=${elapsed}s); events.log: $(cat "$EVENTS_LOG")"
fi
if grep -q 'worker.compact.ineffective' "$EVENTS_LOG"; then
    red "usage genuinely dropped (160000 -> 40000) but worker.compact.ineffective still fired; events.log: $(cat "$EVENTS_LOG")"
else
    green "usage genuinely dropped -> no false-positive worker.compact.ineffective"
    PASS=$((PASS + 1))
fi
check_eventually "post-compact nudge was actually received by the worker" "resumed: $WORKER_COMPACT_NUDGE_PROMPT" \
    "tmux capture-pane -t '$SESSION_NAME:$WIN' -p | grep -o 'resumed: .*' | tail -1"

heading "Test 10: set -e safety — a forced tmux failure must not abort the process"
# This file (coordinator-watch.sh) runs under set -euo pipefail. Force
# `tmux list-panes` to fail mid-call and confirm the function degrades to a
# safe fallback instead of taking the whole daemon down.
tmux() {
    if [ "$1" = "list-panes" ]; then
        return 7
    fi
    command tmux "$@"
}
state="$(worker_pane_state "$WIN")" || state="CRASHED"
unset -f tmux
if [ "$state" = "shell" ]; then
    green "forced tmux list-panes failure resolved to a safe fallback (state=shell), process still alive"
    PASS=$((PASS + 1))
else
    red "expected state=shell on tmux failure, got [$state]"
fi

heading "Test 11: ineffective-compaction detection — usage that DOESN'T drop must warn"
# Same fake REPL instance from Test 9, still running (a `while read` loop —
# no need to touch the pane's foreground process at all). Just flip the
# mode file to "same" so this round's /compact redraws whatever the
# CURRENT ctx is (40k, left over from Test 9's drop) unchanged — mirroring
# test-coordinator-auto-compact.sh's Test 7 (fresh probe, unchanged usage).
# Threshold lowered so 40k still counts as "over" — the point here is the
# ineffective-detection logic, not re-establishing the scaled trigger. The
# window (1M) is still parseable, so it's the CAP that has to come down
# (see Test 9's comment above) — WORKER_COMPACT_THRESHOLD_TOKENS is set too,
# purely for fallback-path consistency, but does nothing while the window
# parses.
: > "$EVENTS_LOG"
WORKER_COMPACT_THRESHOLD_TOKENS=10000
WORKER_COMPACT_THRESHOLD_CAP_TOKENS=10000
echo same > "$REPL_MODE_FILE"
check_eventually "REPL settled back to idle before Test 11" "cli" "worker_pane_state '$WIN'"

maybe_worker_compact "$WIN"
if grep -q 'worker.compact.ineffective' "$EVENTS_LOG"; then
    green "usage did not drop (same value pre/post) -> worker.compact.ineffective correctly fired"
    PASS=$((PASS + 1))
else
    red "usage stayed unchanged across the 'compaction' but no worker.compact.ineffective fired; events.log: $(cat "$EVENTS_LOG")"
fi
# That ineffective verdict just armed issue #252's backoff for this window
# (worker_compact_record_failure) — clear it so Test 12 below exercises
# verify_skip in isolation instead of getting swallowed by reason=backoff.
unset 'WORKER_COMPACT_LAST_FAIL[42]' 'WORKER_COMPACT_FAIL_COUNT[42]' 'WORKER_COMPACT_GAVE_UP[42]'

heading "Test 12: verify-skip — a pane whose ctx text never comes back must NOT be flagged ineffective"
# Same fake REPL instance, still running. Flip the mode file to "blank" so
# this round's post-compact screen shows NOTHING parseable within the
# verify window (a short WORKER_COMPACT_VERIFY_TIMEOUT_SECS makes this
# deterministic without a long test run) — simulating a statusline that
# hasn't re-rendered at all (vs Test 8's "re-rendered with an unchanged
# value").
: > "$EVENTS_LOG"
echo blank > "$REPL_MODE_FILE"
check_eventually "REPL settled back to idle before Test 12" "cli" "worker_pane_state '$WIN'"

WORKER_COMPACT_VERIFY_TIMEOUT_SECS=3 maybe_worker_compact "$WIN"
if grep -q 'worker.compact.verify_skip' "$EVENTS_LOG" && ! grep -q 'worker.compact.ineffective' "$EVENTS_LOG"; then
    green "ctx text never came back -> worker.compact.verify_skip (no false-positive ineffective)"
    PASS=$((PASS + 1))
else
    red "expected verify_skip with no ineffective warning; events.log: $(cat "$EVENTS_LOG")"
fi

heading "Test 13: shipped WORKER_COMPACT_BUSY_PATTERN default matches 2.1.x busy chrome (issue #266)"
# Every test above pins its own WORKER_COMPACT_BUSY_PATTERN override (set at
# the top of this file), so none of them would have caught issue #266: the
# 2.1.x CLI dropped the "(esc to interrupt)" hint the OLD default was solely
# anchored on, and the default silently stopped matching anything. This test
# extracts the actual shipped default straight out of coordinator-watch.sh
# (not a hand-copied guess) so it fails if the default ever regresses again.
default_pattern="$(
    unset WORKER_COMPACT_BUSY_PATTERN
    eval "$(grep -m1 '^WORKER_COMPACT_BUSY_PATTERN=' "$WATCH")"
    printf '%s' "$WORKER_COMPACT_BUSY_PATTERN"
)"
[ -n "$default_pattern" ] || red "could not extract WORKER_COMPACT_BUSY_PATTERN default from $WATCH"

match_default() {
    printf '%s' "$1" | LC_ALL=C grep -qE "$default_pattern" && echo match || echo nomatch
}

check "default matches 2.1.x spinner token counter" "match" \
    "$(match_default '✽ Churning… (1s · ↓ 63 tokens)')"
check "default matches queued-input marker" "match" \
    "$(match_default '❯ Press up to edit queued messages')"
check "default still matches legacy esc-to-interrupt hint (<=2.0.x)" "match" \
    "$(match_default '✻ Considering… (esc to interrupt)')"
check "default still matches Ctrl-C exit-confirm prompt" "match" \
    "$(match_default 'Press Ctrl-C again to exit')"
check "default does NOT match finished-turn summary (no token counter)" "nomatch" \
    "$(match_default '✻ Churned for 13s')"
check "default does NOT match idle statusline /clear hint" "nomatch" \
    "$(match_default 'sonnet · wt-issue-42 · ctx: 900k/1M (90%) · new task? /clear to save 109.7k tokens')"

echo ""
green "All worker-auto-compact tests passed ($PASS checks)"
