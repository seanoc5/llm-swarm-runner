#!/usr/bin/env bash
#
# test-shape-legacy-flat-warning.sh — Non-LLM shape test for issue #271's
# legacy-flat-worktree startup warning in llm-start.sh.
#
# llm-start.sh's warn_legacy_flat_worktrees() function has no PATH-stubbable
# seam (it shells out to `git` directly against real paths), so this
# extracts its body verbatim (sed, not a hand-retyped copy — same technique
# as test-llm-start-reprompt.sh's extract_fn) and exercises it against a
# real (throwaway) git repo + worktrees. No tmux required, so this suite
# runs in CI unlike test-llm-start-reprompt.sh.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_START="$SCRIPT_DIR/../llm-start.sh"
[ -x "$LLM_START" ] || red "llm-start.sh not executable: $LLM_START"

TEST_DIR=$(mktemp -d -t shape-legacy-flat-warning-XXXXXX)
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
body="$(extract_fn warn_legacy_flat_worktrees "$LLM_START")"
[ -n "$body" ] || red "could not extract function 'warn_legacy_flat_worktrees' from $LLM_START — has it been renamed?"
eval "$body"

# ============================================================================
heading "Test 1: no flat worktrees present → silent (no warning)"
# ============================================================================
PROJECT_DIR="$TEST_DIR/main/some-project"
mkdir -p "$PROJECT_DIR"
(cd "$PROJECT_DIR" && git init -q -b master && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)

OUT="$(warn_legacy_flat_worktrees "$PROJECT_DIR" 2>&1)" || true
[ -z "$OUT" ] || red "expected no output with no flat worktrees present, got: $OUT"
green "no wt-issue-* paths at the parent dir → no warning"

# ============================================================================
heading "Test 2: a real legacy flat worktree of THIS project → warned, path listed"
# ============================================================================
(cd "$PROJECT_DIR" && git worktree add -q -b fix/issue-943 "$TEST_DIR/main/wt-issue-943" master)

OUT="$(warn_legacy_flat_worktrees "$PROJECT_DIR" 2>&1)" || true
echo "$OUT" | grep -q "found 1 legacy flat worktree" \
    || red "expected a 'found 1 legacy flat worktree' warning, got: $OUT"
echo "$OUT" | grep -qF "$TEST_DIR/main/wt-issue-943" \
    || red "expected the legacy worktree path listed, got: $OUT"
green "own project's legacy flat worktree detected and listed: $TEST_DIR/main/wt-issue-943"

# ============================================================================
heading "Test 3: an unrelated sibling repo's same-named worktree → NOT reported"
# ============================================================================
rm -rf "$TEST_DIR/main/wt-issue-943"
(cd "$PROJECT_DIR" && git worktree prune)

SIBLING_DIR="$TEST_DIR/main/other-project"
mkdir -p "$SIBLING_DIR"
(cd "$SIBLING_DIR" && git init -q -b master && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init)
(cd "$SIBLING_DIR" && git worktree add -q -b fix/issue-943 "$TEST_DIR/main/wt-issue-943" master)

OUT="$(warn_legacy_flat_worktrees "$PROJECT_DIR" 2>&1)" || true
[ -z "$OUT" ] || red "sibling repo's wt-issue-943 must not be reported as this project's legacy worktree, got: $OUT"
green "sibling repo's same-named worktree correctly excluded (gitdir doesn't match)"

# ============================================================================
heading "Test 4: llm-start.sh only calls the warning when grouping resolves to project"
# ============================================================================
grep -qE '\[ "\$\{SWARM_WORKTREE_GROUPING:-\}" = "project" \] *; *then' "$LLM_START" \
    || red "expected llm-start.sh to gate warn_legacy_flat_worktrees on SWARM_WORKTREE_GROUPING=project"
grep -q "warn_legacy_flat_worktrees \"\$PWD\"" "$LLM_START" \
    || red "expected llm-start.sh to call warn_legacy_flat_worktrees \"\$PWD\""
green "warning is gated on SWARM_WORKTREE_GROUPING=project, called with \$PWD"

# ============================================================================
heading "All legacy-flat-worktree warning shape tests passed"
# ============================================================================
green "warn_legacy_flat_worktrees(): silent when clean, reports+lists real legacy worktrees, excludes sibling repos"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
