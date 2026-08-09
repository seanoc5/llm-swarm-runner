#!/usr/bin/env bash
#
# test-pr-predates-worktree.sh — Regression test for issue #232.
#
# The #185 guard (pr_predates_worktree, in both kill-finished-workers.sh
# and coordinator-watch.sh) compared a PR's createdAt against the
# WORKTREE ROOT DIRECTORY's mtime as a proxy for "when this worktree was
# born." But a directory's mtime bumps on every direct child
# create/rename/delete — .agent-task.md rewrites, build/ creation, status
# files — so any worker activity in the root after the PR opens made the
# root look "born" later than the PR, permanently misclassifying a
# merged/closed PR as "predates this worktree" and blocking
# --merged-only/--pr-finalized reaps forever.
#
# The fix: derive the worktree's birth timestamp from `<worktree>/.git` —
# a FILE (not a dir) written once by `git worktree add` and never touched
# by normal work — via the new worktree_birth_path() helper, with a
# fallback to the dir itself when that file is absent.
#
# Strategy: extract the real function bodies out of the two scripts (sed,
# not hand-retyped copies) and exercise them against a real git worktree,
# simulating post-PR churn with `touch -d` instead of a real sleep.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_FINISHED="$SCRIPT_DIR/../scripts/kill-finished-workers.sh"
COORD_WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -f "$KILL_FINISHED" ] || red "kill-finished-workers.sh not found: $KILL_FINISHED"
[ -f "$COORD_WATCH" ] || red "coordinator-watch.sh not found: $COORD_WATCH"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t pr-predates-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        printf '\033[33mKEEP=1: leaving %s for inspection\033[0m\n' "$TEST_DIR"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    local fn="$1" file="$2"
    sed -n "/^${fn}() {/,/^}/p" "$file"
}

# ─────────────────── both scripts must stay logically identical here ───────
# They're independent copies by design (scripts are self-contained), but
# that only stays safe if a fix to one always lands in the other too —
# this guards against exactly the kind of silent drift that would let
# issue #232's bug survive in coordinator-watch.sh's pr_poll_pass while
# "fixed" in kill-finished-workers.sh. Normalizes the two scripts' local
# variable names (wt vs wt_dir) before comparing so the check tracks logic
# drift, not each file's pre-existing naming convention.
normalize_fn() {
    sed -E 's/\bwt_dir\b/wt/g'
}
for fn in mtime_epoch worktree_birth_path pr_predates_worktree; do
    a="$(extract_fn "$fn" "$KILL_FINISHED" | normalize_fn)"
    b="$(extract_fn "$fn" "$COORD_WATCH" | normalize_fn)"
    [ -n "$a" ] || red "could not extract '$fn' from kill-finished-workers.sh — renamed?"
    [ -n "$b" ] || red "could not extract '$fn' from coordinator-watch.sh — renamed?"
    [ "$a" = "$b" ] || red "'$fn' has drifted between kill-finished-workers.sh and coordinator-watch.sh — fix both copies identically"
done
green "mtime_epoch / worktree_birth_path / pr_predates_worktree are logically identical in both scripts"

eval "$(extract_fn mtime_epoch "$KILL_FINISHED")"
eval "$(extract_fn worktree_birth_path "$KILL_FINISHED")"
eval "$(extract_fn pr_predates_worktree "$KILL_FINISHED")"

# ─────────────────────── fixture: git repo + worktree ───────────────────────

PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR"
git init -q "$PROJECT_DIR"
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name "Test"
echo hello > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" commit -q -m init

WT="$TEST_DIR/wt-issue-232"
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-232 "$WT"
[ -f "$WT/.git" ] || red "fixture: expected $WT/.git to be a FILE (git worktree checkout)"

BIRTH="$(mtime_epoch "$WT/.git")"
[ -n "$BIRTH" ] || red "fixture: could not read $WT/.git mtime"

# PR opened 5s after the worktree was actually born.
PR_CREATED_EPOCH=$((BIRTH + 5))
PR_CREATED_ISO="$(date -u -d "@$PR_CREATED_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"

# Simulate the #232 failure mode: worker activity in the worktree root
# LONG after the PR opened (status file, build dir, .agent-task.md
# rewrite...) bumps the root dir's mtime — but never touches .git.
echo "in progress" > "$WT/.agent-task.md"
touch -d "@$((BIRTH + 3600))" "$WT"

# ============================================================================
heading "Test 1: root dir mtime alone would misdiagnose this as stale (the #232 bug)"
# ============================================================================

OLD_WT_EPOCH="$(mtime_epoch "$WT")"
if [ "$PR_CREATED_EPOCH" -lt "$OLD_WT_EPOCH" ]; then
    green "confirmed: comparing against the root dir's mtime alone reproduces the bug (pr predates wt dir mtime)"
else
    red "fixture didn't reproduce the bug precondition — root dir mtime ($OLD_WT_EPOCH) not after PR creation ($PR_CREATED_EPOCH)"
fi

# ============================================================================
heading "Test 2: .git file mtime is unaffected by the same churn"
# ============================================================================

NEW_WT_EPOCH="$(mtime_epoch "$(worktree_birth_path "$WT")")"
[ "$NEW_WT_EPOCH" -eq "$BIRTH" ] \
    || red "worktree_birth_path's mtime moved ($NEW_WT_EPOCH != birth $BIRTH) — .git file was touched by the churn simulation"
green ".git file mtime ($NEW_WT_EPOCH) still matches the worktree's real birth time"

# ============================================================================
heading "Test 3: pr_predates_worktree correctly says 'does not predate' post-fix"
# ============================================================================

set +e
pr_predates_worktree "$PR_CREATED_ISO" "$WT"
RC=$?
set -e
[ "$RC" -ne 0 ] \
    || red "pr_predates_worktree returned 0 (predates) — the #232 bug is back: a PR created after the worktree's real birth is being misclassified as stale history due to root-dir churn"
green "pr_predates_worktree(post-churn) correctly returns 'does not predate' — reap would proceed"

# ============================================================================
heading "Test 4: fallback to dir mtime when .git file is absent (non-worktree dir)"
# ============================================================================

PLAIN_DIR="$TEST_DIR/not-a-worktree"
mkdir -p "$PLAIN_DIR"
[ ! -e "$PLAIN_DIR/.git" ] || red "fixture: $PLAIN_DIR/.git unexpectedly exists"
[ "$(worktree_birth_path "$PLAIN_DIR")" = "$PLAIN_DIR" ] \
    || red "worktree_birth_path should fall back to the dir itself when .git is absent"
green "worktree_birth_path falls back to the worktree dir when .git file is absent"

echo
green "ALL TESTS PASSED"
