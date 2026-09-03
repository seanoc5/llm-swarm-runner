#!/usr/bin/env bash
#
# test-shape-merge-worktree-dir.sh — regression test for #325:
# swarm-merge.sh's step-5 reap check must derive WORKTREE_DIR via the
# shared swarm_worktree_dir() helper (scripts/_load-env.sh), not a
# hardcoded flat-layout path. A hardcoded path makes the check silently
# inert under SWARM_WORKTREE_GROUPING=project: it never finds the real
# worktree, so it always reports "reaped after 0s" even when the worktree
# is still very much alive.
#
# Two layers, per the issue's own suggestion:
#   1. Derivation: swarm_worktree_dir() itself gives different, correctly
#      shaped paths for flat vs project grouping.
#   2. Integration: swarm-merge.sh's actual reap-check output reflects an
#      alive worktree under project grouping (proving swarm-merge.sh
#      really uses the helper's result, not just that the helper exists).
#
# Stubs `gh` and `tmux` via PATH override — no GitHub auth, no tmux server.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
[ -f "$LOAD_ENV" ] || red "not found: $LOAD_ENV"
[ -x "$MERGE" ]    || red "not executable: $MERGE"

TEST_DIR=$(mktemp -d -t shape-merge-wtdir-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ============================================================================
heading "Test 1: swarm_worktree_dir() derivation differs between groupings"
# ============================================================================
PROJECT_DIR="$TEST_DIR/main/some-project"
mkdir -p "$PROJECT_DIR"

FLAT_PATH=$(
    export SWARM_WORKTREE_GROUPING=flat
    . "$LOAD_ENV" "$PROJECT_DIR" >/dev/null
    swarm_worktree_dir "$PROJECT_DIR" 943
)
PROJECT_PATH=$(
    export SWARM_WORKTREE_GROUPING=project
    . "$LOAD_ENV" "$PROJECT_DIR" >/dev/null
    swarm_worktree_dir "$PROJECT_DIR" 943
)

[ "$FLAT_PATH" = "$TEST_DIR/main/wt-issue-943" ] \
    || red "flat path wrong: $FLAT_PATH"
[ "$PROJECT_PATH" = "$TEST_DIR/main/some-project-worktrees/wt-issue-943" ] \
    || red "project path wrong: $PROJECT_PATH"
[ "$FLAT_PATH" != "$PROJECT_PATH" ] \
    || red "flat and project paths must differ, both were: $FLAT_PATH"
green "flat → $FLAT_PATH"
green "project → $PROJECT_PATH"
green "derivation differs between groupings, matches documented layout"

# ─────────────────────── Stub gh + tmux ────────────────────────────────────

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/943")
        echo "false"; exit 0 ;;
    "issue view")
        case "$*" in
            *closedByPullRequestsReferences*) echo "77"; exit 0 ;;
            *state*)                          echo "OPEN"; exit 0 ;;
        esac
        exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"fix/issue-9","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Never reports the iss-N window alive — isolates the test to the
# worktree-path half of the reap check.
[ "${1:-}" = "list-windows" ] && exit 0
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

# Fixture repo so swarm-merge can resolve a main worktree.
REPO="$TEST_DIR/main/some-project"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# ============================================================================
heading "Test 2: project grouping — reap check finds the real (project-grouped) worktree"
# ============================================================================
# Real PR/issue number irrelevant; gh stub always resolves PR #77 as MERGED,
# skipping the merge/self-review/migration gates entirely so this test is
# scoped to the step-5 reap check alone.
REAL_WT="$TEST_DIR/main/some-project-worktrees/wt-issue-943"
mkdir -p "$REAL_WT/.git"

OUT=$(SWARM_WORKTREE_GROUPING=project timeout 4 "$MERGE" 943 --no-kill 2>&1) || true
echo "$OUT" | grep -q "reaped after" \
    && red "reap check falsely reported reaped — WORKTREE_DIR did not match the real (project-grouped) worktree:\n$OUT"
green "project grouping: worktree correctly detected as alive (no false 'reaped ✓')"

rm -rf "$REAL_WT"

# ============================================================================
heading "Test 3: flat grouping — reap check still finds the worktree (no regression)"
# ============================================================================
REAL_WT="$TEST_DIR/main/wt-issue-943"
mkdir -p "$REAL_WT/.git"

OUT=$(SWARM_WORKTREE_GROUPING=flat timeout 4 "$MERGE" 943 --no-kill 2>&1) || true
echo "$OUT" | grep -q "reaped after" \
    && red "reap check falsely reported reaped under flat grouping:\n$OUT"
green "flat grouping: worktree correctly detected as alive (no false 'reaped ✓')"

rm -rf "$REAL_WT"

# ============================================================================
heading "Test 4: project grouping — reap check reports reaped once the real worktree is gone"
# ============================================================================
OUT=$(SWARM_WORKTREE_GROUPING=project timeout 10 "$MERGE" 943 --no-kill 2>&1) || true
echo "$OUT" | grep -q "reaped after 0s" \
    || red "expected immediate 'reaped after 0s' once the project-grouped worktree is absent:\n$OUT"
green "project grouping: absent worktree correctly reported as reaped"

# ============================================================================
heading "All swarm-merge WORKTREE_DIR shape tests passed"
# ============================================================================
green "swarm_worktree_dir() derivation + swarm-merge.sh reap check honor SWARM_WORKTREE_GROUPING"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
