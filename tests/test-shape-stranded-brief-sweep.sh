#!/usr/bin/env bash
#
# test-shape-stranded-brief-sweep.sh — Non-LLM shape test for issue #448's
# stranded_brief_sweep_pass in coordinator-watch.sh.
#
# llm-start.sh's warn_stranded_worktree_briefs (issue #376,
# test-shape-stranded-worktree-briefs.sh) only ever runs once, at
# session/watcher startup. Real incident, fand-app 2026-09-20: window
# iss-1112 was reaped in parked/window-only mode (kill-finished-workers.sh,
# no --with-worktree — deliberately keeps the worktree) while a claimed
# brief from the previous day still sat in the worktree's
# .swarm/tasks/processing/. With no live iss-1112 window left to drain it
# and no session restart in sight, the brief was invisible from the moment
# of the reap until the swarm's next restart — only found by a manual
# cross-swarm audit. This sweep generalizes that startup check into a
# periodic, mid-session one that writes a durable coord-inbox entry
# (issue #430 idiom) instead.
#
# Same technique as test-shape-worktree-watch-sweeps.sh: extracts each
# function's body verbatim (sed, not a hand-retyped copy) and exercises it
# against real (throwaway) git worktrees, so a rename/edit of any function
# under test is caught rather than silently drifting from reality. `tmux`
# is shadowed by a local shell function (no real tmux session needed), same
# technique as test-shape-stranded-worktree-briefs.sh.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"
[ -r "$WATCH" ]    || red "coordinator-watch.sh not readable: $WATCH"
[ -f "$LOAD_ENV" ] || red "not found: $LOAD_ENV"

TEST_DIR=$(mktemp -d -t shape-stranded-brief-sweep-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    local fn="$1" file="$2"
    sed -n "/^${fn}() {/,/^}/p" "$file"
}

PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR/.swarm"
git -C "$PROJECT_DIR" init -q -b master
git -C "$PROJECT_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# shellcheck source=/dev/null
. "$LOAD_ENV" "$PROJECT_DIR" >/dev/null 2>&1

WORKSPACE="$TEST_DIR"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
DRY_RUN=0
SESSION_NAME=llm-proj
: > "$EVENTS_LOG"

# Minimal stand-in matching the real log_event's on-disk contract (this
# test never reads events.log's format back, but stranded_brief_sweep_pass
# calls it unconditionally on the write path).
log_event() {
    local cat="$1"; shift
    printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$cat" "$*" >> "$EVENTS_LOG"
}

# coord_inbox_write and mtime_epoch are extracted verbatim rather than
# reimplemented, matching test-shape-worktree-watch-sweeps.sh's own
# reasoning: drift here would be silent (a reimplementation could pass
# while the real one broke).
for fn in coord_inbox_write mtime_epoch; do
    eval "$(extract_fn "$fn" "$WATCH")"
    [ "$(type -t "$fn")" = "function" ] || red "could not extract '$fn' from $WATCH — has it been renamed?"
done

for fn in is_own_worktree_dir own_worktree_dirs_for_scan has_live_window \
          stranded_brief_queue_lines stranded_brief_body stranded_brief_sweep_pass; do
    body="$(extract_fn "$fn" "$WATCH")"
    [ -n "$body" ] || red "could not extract '$fn' from $WATCH — has it been renamed?"
    eval "$body"
    [ "$(type -t "$fn")" = "function" ] || red "'$fn' did not eval into a function"
done

inbox_count()  { find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }
last_inbox()   { find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null | sort | tail -1; }

# stranded_brief_queue_lines ignores anything younger than 120s (self-review
# finding on #448: a brief written moments before provision-worker.sh opens
# its tmux window must not read as a strand) — every fixture file below has
# to be backdated past that floor, same GNU/BSD `touch -d`/`touch -t`
# fallback test-coordinator-auto-compact.sh and test-watcher-autoclose.sh
# already use.
backdate() {
    local epoch=$(( $(date +%s) - 200 ))
    touch -d "@$epoch" "$1" 2>/dev/null || touch -t 197001010000 "$1"
}

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-101 "$TEST_DIR/wt-issue-101" master
declare -A STRANDED_BRIEF_LOGGED=()

# ============================================================================
heading "Test 1: clean worktree (no queue dirs at all), no live window -> silent"
# ============================================================================
tmux() { echo ""; }   # no live session at all
stranded_brief_sweep_pass
[ "$(inbox_count)" -eq 0 ] || red "expected no coord-inbox entry for a clean worktree"
green "no queue dirs, no live window -> silent"

# ============================================================================
heading "Test 2: claimed-but-orphaned brief in processing/, no live window -> flagged (strand detected)"
# ============================================================================
mkdir -p "$TEST_DIR/wt-issue-101/.swarm/tasks/processing"
echo "claimed" > "$TEST_DIR/wt-issue-101/.swarm/tasks/processing/20260919-182935-101.md"
backdate "$TEST_DIR/wt-issue-101/.swarm/tasks/processing/20260919-182935-101.md"

stranded_brief_sweep_pass
[ "$(inbox_count)" -eq 1 ] || red "expected exactly one coord-inbox entry, got $(inbox_count)"
entry="$(last_inbox)"
grep -q 'issue #101' "$entry" || red "coord-inbox entry should name issue #101: $(cat "$entry")"
grep -q '20260919-182935-101.md' "$entry" || red "coord-inbox entry should name the stranded file: $(cat "$entry")"
grep -q 'processing' "$entry" || red "coord-inbox entry should name the processing/ queue: $(cat "$entry")"
grep -q 'watch.stranded_brief_sweep.*issue=101.*reason=detected' "$EVENTS_LOG" \
    || red "expected watch.stranded_brief_sweep logged, events.log: $(cat "$EVENTS_LOG")"
[ -n "${STRANDED_BRIEF_LOGGED[101]:-}" ] || red "expected STRANDED_BRIEF_LOGGED[101] to be set"
green "claimed-but-orphaned processing/ brief with no live window is flagged: coord-inbox write + dedup marked"

# ============================================================================
heading "Test 3: second tick, still stranded -> dedup holds (no duplicate)"
# ============================================================================
: > "$EVENTS_LOG"
stranded_brief_sweep_pass
[ "$(inbox_count)" -eq 1 ] || red "expected still exactly 1 coord-inbox entry (no duplicate), got $(inbox_count)"
[ -z "$(grep 'watch.stranded_brief_sweep' "$EVENTS_LOG" || true)" ] \
    || red "expected no watch.stranded_brief_sweep line on the deduped tick"
green "a still-stranded worktree does not re-post on every tick"

# ============================================================================
heading "Test 4: a live iss-101 window reappears (re-provisioned) -> dedup clears"
# ============================================================================
rm -rf "$COORD_INBOX_DIR"
tmux() { echo "iss-101"; }
stranded_brief_sweep_pass
[ -z "${STRANDED_BRIEF_LOGGED[101]:-}" ] || red "expected STRANDED_BRIEF_LOGGED[101] cleared once a live window exists"
[ "$(inbox_count)" -eq 0 ] || red "expected no coord-inbox entry once a live window covers the queue"
green "re-provisioning (live window reappears) clears the dedup state"

# ============================================================================
heading "Test 5: window gone again, still-stranded -> re-flagged (dedup cleared -> re-strand reports again)"
# ============================================================================
tmux() { echo ""; }
stranded_brief_sweep_pass
[ "$(inbox_count)" -eq 1 ] || red "expected a fresh coord-inbox entry after the dedup was cleared, got $(inbox_count)"
[ -n "${STRANDED_BRIEF_LOGGED[101]:-}" ] || red "expected STRANDED_BRIEF_LOGGED[101] set again"
green "a re-strand of the same issue after re-provisioning is reported again"

# ============================================================================
heading "Test 6: brief archived (queue drained) -> dedup clears, no re-post"
# ============================================================================
rm -f "$TEST_DIR/wt-issue-101/.swarm/tasks/processing"/*.md
rm -rf "$COORD_INBOX_DIR"
: > "$EVENTS_LOG"
stranded_brief_sweep_pass
[ -z "${STRANDED_BRIEF_LOGGED[101]:-}" ] || red "expected STRANDED_BRIEF_LOGGED[101] cleared once the queue is drained"
[ "$(inbox_count)" -eq 0 ] || red "expected no coord-inbox entry for an empty (archived) queue"
green "archiving the brief (draining the queue) clears the dedup state, no re-post"

# ============================================================================
heading "Test 7: DRY_RUN=1 detects but writes nothing, and does not persist dedup"
# ============================================================================
echo "claimed again" > "$TEST_DIR/wt-issue-101/.swarm/tasks/processing/20260920-090000-101.md"
backdate "$TEST_DIR/wt-issue-101/.swarm/tasks/processing/20260920-090000-101.md"
DRY_RUN=1
OUT="$(stranded_brief_sweep_pass)"
DRY_RUN=0
echo "$OUT" | grep -q 'DRY.*issue #101' || red "expected a [DRY] line naming issue #101, got: $OUT"
[ "$(inbox_count)" -eq 0 ] || red "DRY_RUN=1 must not write a real coord-inbox entry"
[ -z "${STRANDED_BRIEF_LOGGED[101]:-}" ] || red "DRY_RUN=1 must not mark the dedup map (so a real run afterwards still fires)"
green "DRY_RUN=1 detects and reports every tick, but writes nothing and never marks dedup"

# ============================================================================
heading "Test 8: same brief, now for real -> single real write"
# ============================================================================
stranded_brief_sweep_pass
[ "$(inbox_count)" -eq 1 ] || red "expected exactly 1 real coord-inbox entry after DRY_RUN was lifted, got $(inbox_count)"
green "turning DRY_RUN off lets the previously-dry-reported strand actually post"

# ============================================================================
heading "Test 9: a brief queued in inbox/ (never claimed) is detected the same way"
# ============================================================================
rm -f "$TEST_DIR/wt-issue-101/.swarm/tasks/processing"/*.md
rm -rf "$COORD_INBOX_DIR"
declare -A STRANDED_BRIEF_LOGGED=()
mkdir -p "$TEST_DIR/wt-issue-101/.swarm/tasks/inbox"
echo "queued" > "$TEST_DIR/wt-issue-101/.swarm/tasks/inbox/20260921-100000-101.md"
backdate "$TEST_DIR/wt-issue-101/.swarm/tasks/inbox/20260921-100000-101.md"
stranded_brief_sweep_pass
[ "$(inbox_count)" -eq 1 ] || red "expected an inbox/-only strand to be flagged too, got $(inbox_count)"
grep -q 'inbox' "$(last_inbox)" || red "coord-inbox entry should name the inbox/ queue: $(cat "$(last_inbox)")"
green "an unclaimed brief sitting in inbox/ (not just processing/) is detected the same way"

# ============================================================================
heading "Test 10: the worktree itself is fully reaped (--with-worktree) -> dedup entry drops"
# ============================================================================
git -C "$PROJECT_DIR" worktree remove --force "$TEST_DIR/wt-issue-101"
stranded_brief_sweep_pass
[ -z "${STRANDED_BRIEF_LOGGED[101]:-}" ] \
    || red "expected STRANDED_BRIEF_LOGGED[101] dropped once the worktree is gone entirely (a future wt-issue-101 should start fresh)"
green "a fully-reaped worktree drops out of the dedup map, same as pr_poll_pass's ORPHAN_PR_LOGGED cleanup"

# ============================================================================
heading "Test 11: a brief younger than the grace floor is not yet flagged (self-review finding, #448)"
# ============================================================================
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-102 "$TEST_DIR/wt-issue-102" master
mkdir -p "$TEST_DIR/wt-issue-102/.swarm/tasks/inbox"
echo "queued" > "$TEST_DIR/wt-issue-102/.swarm/tasks/inbox/20260926-brand-new-102.md"
tmux() { echo ""; }
before_count="$(inbox_count)"
stranded_brief_sweep_pass
[ "$(inbox_count)" -eq "$before_count" ] \
    || red "a brief written moments ago (provision-worker.sh's own window-creation gap) must not be flagged yet"
[ -z "${STRANDED_BRIEF_LOGGED[102]:-}" ] || red "STRANDED_BRIEF_LOGGED[102] must not be set for a too-young brief"
green "a freshly-written brief inside provision-worker.sh's window-creation gap is not flagged (grace floor holds)"

backdate "$TEST_DIR/wt-issue-102/.swarm/tasks/inbox/20260926-brand-new-102.md"
stranded_brief_sweep_pass
[ "$(inbox_count)" -eq $((before_count + 1)) ] || red "once past the grace floor, the same brief should be flagged"
[ -n "${STRANDED_BRIEF_LOGGED[102]:-}" ] || red "expected STRANDED_BRIEF_LOGGED[102] set once past the grace floor"
green "the same brief is flagged once it's old enough to be a real strand"

# ============================================================================
heading "Test 12: a file listed by find but deleted before stat leaves the rest of the scan (and the sweep) alive (PR #480 review)"
# ============================================================================
# Reproduces the coordinator's PR #480 finding: the coordinator can archive
# a stranded brief by hand mid-tick, between find listing it and
# stranded_brief_queue_lines's stat on it. Two files, sorted so the vanishing
# one is scanned first and a REAL still-stranded one follows it -- this is
# the only way to observe the pre-fix bug directly: a bare
# `age_secs=$(( now - $(mtime_epoch "$f") ))` on the empty mtime_epoch result
# is an arithmetic syntax error that aborts the `while read` scan outright
# (confirmed experimentally: the loop does not even reach its next
# iteration), so the real strand sorted after the vanished file would go
# completely unreported -- not just "one line missing", a false "all clear"
# for the whole queue. `|| true` on the bare form can't catch this because
# the error isn't a normal nonzero exit status, it's a fatal parse error.
rm -f "$TEST_DIR/wt-issue-102/.swarm/tasks/inbox"/*.md
: > "$EVENTS_LOG"
declare -A STRANDED_BRIEF_LOGGED=()
mkdir -p "$TEST_DIR/wt-issue-102/.swarm/tasks/inbox"
VANISHING="$TEST_DIR/wt-issue-102/.swarm/tasks/inbox/20260926-a-vanishing-102.md"
STILL_STRANDED="$TEST_DIR/wt-issue-102/.swarm/tasks/inbox/20260926-b-still-stranded-102.md"
echo "queued" > "$VANISHING"
echo "queued" > "$STILL_STRANDED"
backdate "$VANISHING"
backdate "$STILL_STRANDED"

# Shadow mtime_epoch (as extracted above) so stat'ing the vanishing file
# fails exactly once, the moment it's looked up -- same shape as the real
# race, without a timing-dependent sleep.
mtime_epoch() {
    if [ "$1" = "$VANISHING" ]; then
        rm -f "$VANISHING"
    fi
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

lines="$(stranded_brief_queue_lines "$TEST_DIR/wt-issue-102")"
echo "$lines" | grep -q "20260926-b-still-stranded-102.md" \
    || red "the real strand sorted after a vanished file must still be reported, got: $lines"
echo "$lines" | grep -q "20260926-a-vanishing-102.md" \
    && red "the vanished file itself must not appear in the output: $lines"
green "a file that vanishes mid-scan is skipped without losing the real strand that sorts after it"

# Restore the real mtime_epoch (re-extracted) for any test added after this one.
eval "$(extract_fn mtime_epoch "$WATCH")"

# ============================================================================
heading "All stranded-brief sweep tests passed"
# ============================================================================
green "stranded_brief_sweep_pass(): detects a queued/claimed brief with no live window, dedups per issue, and clears on re-provision or archive"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
