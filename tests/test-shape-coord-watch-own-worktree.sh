#!/usr/bin/env bash
#
# test-shape-coord-watch-own-worktree.sh — Non-LLM shape test for issue
# #357's fix inside coordinator-watch.sh itself.
#
# Several coordinator-watch.sh passes (pr_poll_pass, bg_violation_sweep_pass,
# status_poll_pass, maybe_worker_deliver_brief, maybe_worker_compact) derive
# a worktree path by string-pasting a LOCAL issue number (from this
# project's own tmux window name, or a `gh pr list` branch on this
# project's own repo — both trustworthy) onto $WORKSPACE. Under
# SWARM_WORKTREE_GROUPING=flat, $WORKSPACE is the project's PARENT
# directory, shared with any sibling project's swarm checked out
# alongside it — so a same-numbered wt-issue-N belonging to a DIFFERENT
# project's repo silently matched too, before this fix. Some of those
# passes then read from, or even WRITE into (bg_violation_sweep_pass's
# outbox drop, status_poll_pass's maybe_run_check), whatever directory
# they resolved — i.e. this was not just a read-side triage bug but could
# leak state into (or execute checks inside) a sibling project's worktree.
#
# is_own_worktree_dir()/own_wt_dir_for_issue() are the fix: they verify a
# resolved path is actually registered as THIS project's own worktree
# (via `git worktree list` against $PROJECT_DIR) before any caller treats
# it as trustworthy. This test extracts those two function bodies verbatim
# (sed, not a hand-retyped copy — same technique as
# test-pr-predates-worktree.sh's extract_fn) and exercises them directly
# against a fixture with a real foreign worktree colliding on the same
# issue number.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD_WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -f "$COORD_WATCH" ] || red "coordinator-watch.sh not found: $COORD_WATCH"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t shape-coord-watch-own-wt-XXXXXX)
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

for fn in is_own_worktree_dir own_wt_dir_for_issue; do
    body="$(extract_fn "$fn" "$COORD_WATCH")"
    [ -n "$body" ] || red "could not extract '$fn' from coordinator-watch.sh — has it been renamed?"
    eval "$body"
done

# ─────────────────────── Fixture: two sibling git repos ──────────────────────
mkdir -p "$TEST_DIR/main"
export SWARM_WORKTREE_GROUPING=flat

PROJECT_DIR="$TEST_DIR/main/proj"
git init -q -b master "$PROJECT_DIR"
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name "Test"
git -C "$PROJECT_DIR" commit -q --allow-empty -m init
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-1 "$TEST_DIR/main/wt-issue-1" master

OTHER_DIR="$TEST_DIR/main/other"
git init -q -b master "$OTHER_DIR"
git -C "$OTHER_DIR" config user.email test@example.com
git -C "$OTHER_DIR" config user.name "Test"
git -C "$OTHER_DIR" commit -q --allow-empty -m init
# Deliberate collision: other's own issue-999 worktree lands at the exact
# path proj's own issue-999 worktree would use under flat grouping.
git -C "$OTHER_DIR" worktree add -q -b fix/issue-999 "$TEST_DIR/main/wt-issue-999" master

WORKSPACE="$TEST_DIR/main"

# ============================================================================
heading "Test 1: is_own_worktree_dir() accepts proj's own worktree"
# ============================================================================
is_own_worktree_dir "$TEST_DIR/main/wt-issue-1" \
    || red "is_own_worktree_dir rejected proj's genuine wt-issue-1"
green "is_own_worktree_dir() accepts proj's own wt-issue-1"

# ============================================================================
heading "Test 2: is_own_worktree_dir() rejects other's colliding worktree"
# ============================================================================
if is_own_worktree_dir "$TEST_DIR/main/wt-issue-999"; then
    red "is_own_worktree_dir accepted other's wt-issue-999 as proj's own"
fi
green "is_own_worktree_dir() rejects other's colliding wt-issue-999"

# ============================================================================
heading "Test 3: own_wt_dir_for_issue() resolves proj's own issue number"
# ============================================================================
OUT="$(own_wt_dir_for_issue 1)" || red "own_wt_dir_for_issue(1) failed for proj's own worktree"
[ "$OUT" = "$TEST_DIR/main/wt-issue-1" ] || red "own_wt_dir_for_issue(1) returned '$OUT', want $TEST_DIR/main/wt-issue-1"
green "own_wt_dir_for_issue() resolves proj's own issue 1"

# ============================================================================
heading "Test 4: own_wt_dir_for_issue() refuses the colliding foreign issue number"
# ============================================================================
# This is the exact scenario a tmux window "iss-999" in PROJ's own session
# would hit if proj never actually provisioned issue 999 itself, but
# other's swarm happens to have: pr_poll_pass, bg_violation_sweep_pass,
# status_poll_pass, maybe_worker_deliver_brief and maybe_worker_compact all
# call this before treating a directory as proj's own — none of them may
# ever read from, or write into, other's worktree.
if OUT="$(own_wt_dir_for_issue 999)"; then
    red "own_wt_dir_for_issue(999) returned other's worktree: $OUT"
fi
green "own_wt_dir_for_issue() refuses to resolve the colliding foreign issue 999"

echo
green "All coordinator-watch.sh own-worktree-verification tests passed (issue #357)."
