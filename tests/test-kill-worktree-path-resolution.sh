#!/usr/bin/env bash
#
# test-kill-worktree-path-resolution.sh — Non-LLM regression test for issue
# #407: kill-worktree.sh must find a worktree wherever git actually
# registered it, not only at the path SWARM_WORKTREE_GROUPING currently
# derives.
#
# The #407 bug: a worktree created under `flat` grouping
# (<parent>/wt-issue-N) is left exactly where it is if the project's env
# later switches to `project` grouping. kill-worktree.sh's WT was computed
# purely from swarm_worktree_dir(), which only ever knows the CURRENT
# mode's path (<parent>/<project>-worktrees/wt-issue-N) — so it reported
# "worktree dir not present (skipped)" for a worktree that was very much
# present and still registered, and the branch-delete that followed then
# failed with "cannot delete branch used by worktree" (git refuses to
# delete a branch checked out in a worktree it still knows about).
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
[ -x "$KILL_WT" ] || red "kill-worktree.sh not executable: $KILL_WT"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t kill-wt-path-res-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

new_project() {
    local proj="$1"
    mkdir -p "$proj"
    git init -q "$proj"
    git -C "$proj" config user.email test@example.com
    git -C "$proj" config user.name "Test"
    echo hello > "$proj/README.md"
    git -C "$proj" add README.md
    git -C "$proj" commit -q -m init
}

# ============================================================================
heading "Test 1: legacy flat worktree found and removed under SWARM_WORKTREE_GROUPING=project"
# ============================================================================

PROJ1="$TEST_DIR/proj1"
new_project "$PROJ1"

# Worktree created while grouping was (or defaulted to) flat: lives directly
# under the project's parent dir, NOT under <project>-worktrees/.
git -C "$PROJ1" worktree add -q -b fix/issue-71 "$TEST_DIR/wt-issue-71"
LEGACY_WT="$TEST_DIR/wt-issue-71"
[ -d "$LEGACY_WT" ] || red "test setup failed: legacy worktree not created"

RUN1="$TEST_DIR/run1.log"
set +e
(cd "$PROJ1" && SWARM_WORKTREE_GROUPING=project "$KILL_WT" 71 "$PROJ1") > "$RUN1" 2>&1
RC1=$?
set -e
[ "$RC1" -eq 0 ] || red "expected exit 0, got $RC1. Output:
$(cat "$RUN1")"
green "kill-worktree.sh exited 0 against a legacy flat worktree under project grouping"

grep -qF "worktree: $LEGACY_WT" "$RUN1" \
    || red "expected the script to resolve WT to the legacy flat path ($LEGACY_WT), not the project-grouping derived path. Output:
$(cat "$RUN1")"
green "resolved worktree path is the legacy flat path, not the derived project-grouping path"

grep -qF 'worktree dir not present (skipped)' "$RUN1" \
    && red "the legacy worktree should have been found and removed, not skipped as absent. Output:
$(cat "$RUN1")"
[ -d "$LEGACY_WT" ] && red "legacy worktree dir still present after removal: $LEGACY_WT"
git -C "$PROJ1" show-ref --verify --quiet refs/heads/fix/issue-71 \
    && red "branch fix/issue-71 still present after removal — the #407 bug reproduces as 'cannot delete branch used by worktree'"
green "legacy worktree removed and branch fix/issue-71 deleted cleanly"

# ============================================================================
heading "Test 2: current-mode (project-grouping) worktree still resolves correctly"
# ============================================================================

PROJ2="$TEST_DIR/proj2"
new_project "$PROJ2"

GROUPED_WT="$TEST_DIR/$(basename "$PROJ2")-worktrees/wt-issue-72"
mkdir -p "$(dirname "$GROUPED_WT")"
git -C "$PROJ2" worktree add -q -b fix/issue-72 "$GROUPED_WT"

RUN2="$TEST_DIR/run2.log"
set +e
(cd "$PROJ2" && SWARM_WORKTREE_GROUPING=project "$KILL_WT" 72 "$PROJ2") > "$RUN2" 2>&1
RC2=$?
set -e
[ "$RC2" -eq 0 ] || red "expected exit 0, got $RC2. Output:
$(cat "$RUN2")"
grep -qF "worktree: $GROUPED_WT" "$RUN2" \
    || red "expected the script to resolve WT to the project-grouping path ($GROUPED_WT). Output:
$(cat "$RUN2")"
[ -d "$GROUPED_WT" ] && red "project-grouping worktree dir still present after removal: $GROUPED_WT"
git -C "$PROJ2" show-ref --verify --quiet refs/heads/fix/issue-72 \
    && red "branch fix/issue-72 still present after removal"
green "current-mode (project-grouping) worktree removed exactly as before this fix"

# ============================================================================
heading "Test 3: no worktree registered anywhere → falls back to derived path, reports absent (unchanged behavior)"
# ============================================================================

PROJ3="$TEST_DIR/proj3"
new_project "$PROJ3"

RUN3="$TEST_DIR/run3.log"
set +e
(cd "$PROJ3" && SWARM_WORKTREE_GROUPING=project "$KILL_WT" 73 "$PROJ3") > "$RUN3" 2>&1
RC3=$?
set -e
[ "$RC3" -eq 0 ] || red "expected exit 0, got $RC3. Output:
$(cat "$RUN3")"
DERIVED_WT="$TEST_DIR/$(basename "$PROJ3")-worktrees/wt-issue-73"
grep -qF "worktree: $DERIVED_WT" "$RUN3" \
    || red "expected fallback to the derived project-grouping path ($DERIVED_WT) when git has no registration. Output:
$(cat "$RUN3")"
grep -qF 'worktree dir not present (skipped)' "$RUN3" \
    || red "expected the usual absent-worktree message. Output:
$(cat "$RUN3")"
green "no registration anywhere → falls back to the derived path and reports absent, as before"

echo
green "ALL TESTS PASSED"
