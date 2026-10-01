#!/usr/bin/env bash
#
# test-shape-merge-worktree-dir.sh — regression test for #325, updated for
# #465: swarm-merge.sh's reap step must actually find and remove the real
# worktree under SWARM_WORKTREE_GROUPING=project, not a hardcoded
# flat-layout path.
#
# #325's original bug: swarm-merge.sh derived WORKTREE_DIR itself, with a
# hardcoded flat-layout path — silently inert under project grouping, since
# it never found the real worktree. #325's fix routed that derivation
# through the shared swarm_worktree_dir() helper.
#
# #465 removed swarm-merge.sh's own wait-loop/derivation entirely: it now
# reaps by calling kill-worktree.sh <issue> <project-dir> directly and lets
# THAT script resolve the real path (swarm_worktree_dir() plus, per #407,
# git's own worktree registry as the stronger signal — see
# test-kill-worktree-path-resolution.sh for that resolution logic's own
# coverage). So the #325 regression this file guards against now has to be
# caught one level up: swarm-merge.sh must still actually delegate to
# kill-worktree.sh (not re-derive a path of its own), and a real worktree
# under project grouping must actually be removed by the time swarm-merge.sh
# finishes — not silently left behind.
#
# Three layers:
#   1. Derivation: swarm_worktree_dir() itself gives different, correctly
#      shaped paths for flat vs project grouping (unchanged from #325).
#   2. Integration: running swarm-merge.sh end-to-end (no --no-kill) against
#      a REAL project-grouped worktree actually removes it.
#   3. --no-kill: the same real worktree is left completely alone.
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
#
# gh always resolves issue #943 → PR #77, already MERGED — this test is
# scoped to the reap step, not the merge/gate logic, so the PR is reported
# pre-merged to skip straight to "[4/6] already MERGED — proceeding to
# cleanup". tmux never reports the iss-943 window alive.

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/943")
        echo "false"; exit 0 ;;
    "issue view")
        case "$*" in
            *closedByPullRequestsReferences*) echo "77"; exit 0 ;;
            *state*)                          echo "CLOSED"; exit 0 ;;
        esac
        exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"fix/issue-943","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
    "issue list")
        echo '[]'; exit 0 ;;
esac
exit 0
EOF
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Never reports the iss-N window alive.
[ "${1:-}" = "list-windows" ] && exit 0
[ "${1:-}" = "has-session" ] && exit 1
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

# Fixture repo so swarm-merge can resolve a main worktree, with a real
# branch so a real `git worktree add` can check it out.
REPO="$TEST_DIR/main/some-project"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git branch fix/issue-943

# ============================================================================
heading "Test 2: project grouping — swarm-merge.sh removes the real worktree via kill-worktree.sh"
# ============================================================================
REAL_WT="$TEST_DIR/main/some-project-worktrees/wt-issue-943"
mkdir -p "$(dirname "$REAL_WT")"
git worktree add -q "$REAL_WT" fix/issue-943

OUT=$(cd "$REPO" && SWARM_WORKTREE_GROUPING=project timeout 15 "$MERGE" 943 2>&1) \
    || red "swarm-merge.sh exited non-zero against a real project-grouped worktree:\n$OUT"
echo "$OUT" | grep -q "reaped" \
    || red "expected swarm-merge.sh's reap step to report success, got:\n$OUT"
[ -d "$REAL_WT" ] \
    && red "real project-grouped worktree is still present after swarm-merge.sh ran — #325 regressed:\n$OUT"
git -C "$REPO" show-ref --verify --quiet refs/heads/fix/issue-943 \
    && red "branch fix/issue-943 still present after reap — kill-worktree.sh should have deleted it:\n$OUT"
green "project-grouped worktree and its branch were actually removed"

# ============================================================================
heading "Test 3: --no-kill — the real worktree is left completely alone"
# ============================================================================
git -c user.email=t@t -c user.name=t branch fix/issue-943
REAL_WT2="$TEST_DIR/main/some-project-worktrees/wt-issue-943-2"
# Re-derive at a fresh path (the first was already removed above) using the
# SAME issue number, to confirm --no-kill really skips the whole step.
mkdir -p "$(dirname "$REAL_WT2")"
git worktree add -q "$REAL_WT2" fix/issue-943

OUT=$(cd "$REPO" && SWARM_WORKTREE_GROUPING=project timeout 15 "$MERGE" 943 --no-kill 2>&1) \
    || red "swarm-merge.sh --no-kill exited non-zero:\n$OUT"
echo "$OUT" | grep -q "no-kill set; leaving tmux window / worktree alone" \
    || red "expected the --no-kill skip message, got:\n$OUT"
echo "$OUT" | grep -q "reaped" \
    && red "--no-kill must not report a reap at all:\n$OUT"
[ -d "$REAL_WT2" ] \
    || red "--no-kill removed the worktree anyway — #465's --no-kill contract broke:\n$OUT"
git -C "$REPO" show-ref --verify --quiet refs/heads/fix/issue-943 \
    || red "--no-kill deleted the branch anyway:\n$OUT"
green "--no-kill left the real worktree and its branch completely untouched"

git -C "$REPO" worktree remove --force "$REAL_WT2" >/dev/null 2>&1 || true

# ============================================================================
heading "All swarm-merge WORKTREE_DIR shape tests passed"
# ============================================================================
green "swarm_worktree_dir() derivation + swarm-merge.sh's kill-worktree.sh delegation honor SWARM_WORKTREE_GROUPING"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
