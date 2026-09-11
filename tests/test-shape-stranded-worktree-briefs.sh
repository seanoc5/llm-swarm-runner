#!/usr/bin/env bash
#
# test-shape-stranded-worktree-briefs.sh — Non-LLM shape test for issue
# #376's stranded-worktree-brief startup warning in llm-start.sh.
#
# A tmux session restart leaves worker worktrees on disk with their queue
# state intact but no corresponding `iss-N` tmux window — a brief still
# sitting in `.swarm/tasks/{inbox,processing}/` then has no listener left to
# drain it and sits invisible indefinitely (real incident, 2026-09-08: see
# llm-start.sh's warn_stranded_worktree_briefs() header comment).
#
# Same technique as test-shape-legacy-flat-warning.sh: extracts the
# function's body verbatim (sed, not a hand-retyped copy) and exercises it
# against a real (throwaway) git repo + worktrees, so a rename/edit of the
# function is caught rather than silently drifting from what's under test.
# `tmux` is shadowed by a local shell function (not a real tmux session) so
# this runs everywhere test-shape-legacy-flat-warning.sh does, with no tmux
# dependency.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_START="$SCRIPT_DIR/../llm-start.sh"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"
[ -x "$LLM_START" ] || red "llm-start.sh not executable: $LLM_START"
[ -f "$LOAD_ENV" ]  || red "not found: $LOAD_ENV"

TEST_DIR=$(mktemp -d -t shape-stranded-briefs-XXXXXX)
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

PROJECT_DIR="$TEST_DIR/main/proj"
mkdir -p "$PROJECT_DIR"
(cd "$PROJECT_DIR" && git init -q -b master && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

# swarm_own_worktree_dirs() (sourced fresh here, matching test-shape-legacy-
# flat-warning.sh's own pattern) is the function under test's own worktree
# source of truth — see its header comment / PR #356's BLOCK verdict for why
# a hardcoded glob is the anti-pattern this must not regress to.
# shellcheck source=/dev/null
. "$LOAD_ENV" "$PROJECT_DIR" >/dev/null 2>&1

body="$(extract_fn warn_stranded_worktree_briefs "$LLM_START")"
[ -n "$body" ] || red "could not extract function 'warn_stranded_worktree_briefs' from $LLM_START — has it been renamed?"
eval "$body"

# ============================================================================
heading "Test 1: clean worktree (empty inbox/processing) → silent"
# ============================================================================
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-101 "$TEST_DIR/main/wt-issue-101" master
mkdir -p "$TEST_DIR/main/wt-issue-101/.swarm/tasks/inbox" "$TEST_DIR/main/wt-issue-101/.swarm/tasks/processing"

tmux() { echo ""; }   # no live session — nothing on the fake socket

OUT="$(warn_stranded_worktree_briefs "$PROJECT_DIR" "llm-proj" 2>&1)" || true
[ -z "$OUT" ] || red "expected no output for a clean worktree, got: $OUT"
green "empty inbox/processing → no warning"

# ============================================================================
heading "Test 2: file in inbox/, no live iss-N window → warned"
# ============================================================================
echo "brief" > "$TEST_DIR/main/wt-issue-101/.swarm/tasks/inbox/20260905-165725-101.md"

OUT="$(warn_stranded_worktree_briefs "$PROJECT_DIR" "llm-proj" 2>&1)" || true
echo "$OUT" | grep -q "stranded worktree wt-issue-101" \
    || red "expected a stranded-worktree warning for wt-issue-101, got: $OUT"
echo "$OUT" | grep -q "inbox=1 processing=0" \
    || red "expected inbox=1 processing=0 in the warning, got: $OUT"
green "queued inbox/ brief with no live window → warned, counts correct"

# ============================================================================
heading "Test 3: same worktree, but a live iss-101 tmux window exists → silent"
# ============================================================================
tmux() { echo "coordinator"; echo "util"; echo "iss-101"; }

OUT="$(warn_stranded_worktree_briefs "$PROJECT_DIR" "llm-proj" 2>&1)" || true
[ -z "$OUT" ] || red "expected no warning once a live iss-101 window exists, got: $OUT"
green "live iss-101 window suppresses the warning"

# ============================================================================
heading "Test 4: file left in processing/ (claimed-but-dead worker), no live window → warned"
# ============================================================================
tmux() { echo ""; }
rm -f "$TEST_DIR/main/wt-issue-101/.swarm/tasks/inbox/20260905-165725-101.md"
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-298 "$TEST_DIR/main/wt-issue-298" master
mkdir -p "$TEST_DIR/main/wt-issue-298/.swarm/tasks/processing"
echo "claimed" > "$TEST_DIR/main/wt-issue-298/.swarm/tasks/processing/20260905-165552-298.md"

OUT="$(warn_stranded_worktree_briefs "$PROJECT_DIR" "llm-proj" 2>&1)" || true
echo "$OUT" | grep -q "stranded worktree wt-issue-298" \
    || red "expected a stranded-worktree warning for wt-issue-298, got: $OUT"
echo "$OUT" | grep -q "inbox=0 processing=1" \
    || red "expected inbox=0 processing=1 in the warning, got: $OUT"
echo "$OUT" | grep -q "wt-issue-101" \
    && red "expected wt-issue-101 (clean at this point) to stay silent, got: $OUT"
green "claimed-but-dead processing/ brief with no live window → warned, counts correct"

# ============================================================================
heading "Test 5: llm-start.sh calls the warning unconditionally after env load"
# ============================================================================
grep -q 'warn_stranded_worktree_briefs "\$PWD" "\$SESSION_NAME"' "$LLM_START" \
    || red "expected llm-start.sh to call warn_stranded_worktree_briefs \"\$PWD\" \"\$SESSION_NAME\""
green "warn_stranded_worktree_briefs is wired into llm-start.sh's startup path"

# ============================================================================
heading "All stranded-worktree-brief warning shape tests passed"
# ============================================================================
green "warn_stranded_worktree_briefs(): silent when clean or live, warns with correct inbox/processing counts otherwise"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
