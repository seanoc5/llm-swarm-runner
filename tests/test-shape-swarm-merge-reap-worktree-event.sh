#!/usr/bin/env bash
#
# test-shape-swarm-merge-reap-worktree-event.sh — regression test for issue
# #465: swarm-merge.sh used to wait up to GRACE_SECONDS (60s) for the
# watcher's own backstop to reap a merged worker, then fall back to a bare
# `git worktree remove --force` (with its own duplicated salvage/archive
# logic) if the watcher hadn't gotten to it yet. That wait is now gone:
# swarm-merge.sh reaps immediately by calling kill-worktree.sh directly —
# the SAME reaper the watcher uses — so salvage, the .swarm/.local-data
# archive, and the `reap.worktree` event logging all happen there instead
# of being duplicated in swarm-merge.sh.
#
# swarm-merge.sh's full merge flow needs gh/tmux/PR-state fixtures well
# beyond this one line's scope to exercise end-to-end (no existing test
# does), so this verifies the narrower, load-bearing facts directly:
#   1. The old wait-loop / bare `git worktree remove` fallback is gone.
#   2. swarm-merge.sh's reap step calls kill-worktree.sh with the issue
#      number and main-worktree dir, and handles its exit codes (0/75/76)
#      without treating a defer/refuse as a hard failure.
#   3. kill-worktree.sh (not swarm-merge.sh) is the thing that logs
#      `reap.worktree` — i.e. swarm-merge.sh no longer carries its own
#      duplicate log_event call for that category.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
[ -r "$MERGE" ] || red "swarm-merge.sh not readable: $MERGE"
[ -r "$KILL_WT" ] || red "kill-worktree.sh not readable: $KILL_WT"

# ============================================================================
heading "Test 1: the old wait-loop / bare fallback removal is gone"
# ============================================================================
grep -q 'GRACE_SECONDS' "$MERGE" \
    && red "expected GRACE_SECONDS (the 60s wait loop) to be gone from swarm-merge.sh — has issue #465's fix been reverted?"
grep -q 'git worktree remove --force "\$WORKTREE_DIR"' "$MERGE" \
    && red "expected swarm-merge.sh's bare fallback removal line to be gone — it should delegate to kill-worktree.sh now"
green "GRACE_SECONDS wait loop and bare fallback removal are both gone"

# ============================================================================
heading "Test 2: swarm-merge.sh reaps by calling kill-worktree.sh directly"
# ============================================================================
grep -qE '"\$SCRIPT_DIR/kill-worktree\.sh" "\$ISSUE" "\$MAIN_WT"' "$MERGE" \
    || red "expected swarm-merge.sh to call kill-worktree.sh <issue> <main-worktree> — has the call shape changed?"
green "swarm-merge.sh calls kill-worktree.sh <issue> <main-worktree> directly"

# ============================================================================
heading "Test 3: defer (75) and refuse (76) exit codes are handled, not treated as fatal"
# ============================================================================
grep -q '75)' "$MERGE" || red "expected swarm-merge.sh to handle kill-worktree.sh's exit 75 (deferred/in-flight check)"
grep -q '76)' "$MERGE" || red "expected swarm-merge.sh to handle kill-worktree.sh's exit 76 (refused/non-empty inbox)"
green "swarm-merge.sh names both of kill-worktree.sh's non-zero-but-not-fatal exit codes"

# ============================================================================
heading "Test 4: --no-kill still skips the reap step entirely"
# ============================================================================
grep -q '"\$NO_KILL" = 1 \]; then' "$MERGE" \
    || red "expected an explicit NO_KILL=1 branch guarding the reap step"
green "--no-kill still has its own explicit skip branch"

# ============================================================================
heading "Test 5: kill-worktree.sh (not swarm-merge.sh) owns the reap.worktree log_event call"
# ============================================================================
MERGE_REAP_LOGS="$(grep -c 'log_event reap\.worktree' "$MERGE" || true)"
[ "$MERGE_REAP_LOGS" = "0" ] \
    || red "expected swarm-merge.sh to no longer log its own reap.worktree events (found $MERGE_REAP_LOGS) — that's kill-worktree.sh's job now"
grep -q 'log_event reap.worktree ' "$KILL_WT" \
    || red "expected kill-worktree.sh to still log the reap.worktree event on removal — has it moved/renamed?"
green "reap.worktree logging lives only in kill-worktree.sh, not duplicated in swarm-merge.sh"

green "ALL TESTS PASSED"
