#!/usr/bin/env bash
#
# test-shape-swarm-merge-reap-worktree-event.sh — Non-LLM shape test for a
# self-review finding on issue #439's own PR: swarm-merge.sh's fallback
# worktree removal (used when coordinator-watch.sh hasn't reaped a
# worker's worktree within GRACE_SECONDS of merging) used to call `git
# worktree remove` directly, bypassing kill-worktree.sh entirely — which
# meant coordinator-watch.sh's new worktree_vanish_sweep_pass
# (test-shape-worktree-watch-sweeps.sh) would flag every such fallback
# removal as an unblessed disappearance, a false alarm on swarm-merge.sh's
# own routine housekeeping.
#
# swarm-merge.sh's full merge flow needs gh/tmux/PR-state fixtures well
# beyond this one line's scope to exercise end-to-end (no existing test
# does), so this verifies the narrower, load-bearing fact directly: the
# log_event function swarm-merge.sh now defines writes a `reap.worktree`
# line in EXACTLY the format coordinator-watch.sh's wt_reap_event_since
# (test-shape-worktree-watch-sweeps.sh) parses — same extract-and-eval
# technique as that file, so a rename/reshape of either side is caught.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -r "$MERGE" ] || red "swarm-merge.sh not readable: $MERGE"
[ -r "$WATCH" ] || red "coordinator-watch.sh not readable: $WATCH"

TEST_DIR=$(mktemp -d -t swarm-merge-reap-event-XXXXXX)
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

grep -q 'git worktree remove --force "\$WORKTREE_DIR"' "$MERGE" \
    || red "expected swarm-merge.sh's fallback removal line to still be present — has it moved/changed shape?"
grep -q 'log_event reap.worktree' "$MERGE" \
    || red "expected swarm-merge.sh to log a reap.worktree event after its fallback removal — has issue #439's fix been reverted?"

EVENTS_LOG="$TEST_DIR/events.log"
: > "$EVENTS_LOG"

# ============================================================================
heading "Test 1: swarm-merge.sh's log_event writes the exact format wt_reap_event_since parses"
# ============================================================================
body="$(extract_fn log_event "$MERGE")"
[ -n "$body" ] || red "could not extract log_event from $MERGE — has it been renamed?"
eval "$body"
[ "$(type -t log_event)" = "function" ] || red "log_event did not eval into a function"

log_event reap.worktree "issue=42 branch=fix/issue-42 dir=$TEST_DIR/wt-issue-42 caller=swarm-merge.sh"
grep -qE '^[0-9-]+T[0-9:]+Z  reap\.worktree {1,}issue=42 branch=fix/issue-42' "$EVENTS_LOG" \
    || red "log_event's output doesn't match the expected timestamp/category/kv shape: $(cat "$EVENTS_LOG")"
green "swarm-merge.sh's log_event writes a well-formed reap.worktree line"

# ============================================================================
heading "Test 2: wt_reap_event_since (coordinator-watch.sh) recognizes that exact line as a blessed removal"
# ============================================================================
body="$(extract_fn wt_reap_event_since "$WATCH")"
[ -n "$body" ] || red "could not extract wt_reap_event_since from $WATCH — has it been renamed?"
eval "$body"
[ "$(type -t wt_reap_event_since)" = "function" ] || red "wt_reap_event_since did not eval into a function"

since="$(date -u -d '-5 minutes' +'%Y-%m-%dT%H:%M:%SZ')"
wt_reap_event_since 42 "$since" \
    || red "wt_reap_event_since did not recognize swarm-merge.sh's own reap.worktree line as blessed"
green "coordinator-watch.sh's vanish sweep will NOT flag swarm-merge.sh's fallback removal as unblessed"

green "ALL TESTS PASSED"
