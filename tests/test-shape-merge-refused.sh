#!/usr/bin/env bash
#
# test-shape-merge-refused.sh — regression test for #492:
# swarm-merge.sh must not report "Done. PR #N merged" and run cleanup when
# `gh pr merge` refuses the merge. The real incident (fand-etl,
# 2026-09-27): five PRs merged in sequence each printed a "Done. ... merged"
# line and exited 0, but three of them were left OPEN with
# mergeStateStatus DIRTY — the script tolerated every `gh pr merge` failure
# unconditionally instead of checking whether the PR was actually merged.
#
# The fix re-queries `gh pr view` after a failed `gh pr merge` and only
# tolerates the failure when the PR is actually MERGED (the case
# --delete-branch's now-removed local-delete step used to produce — see
# issue #489). This test covers both branches of that check:
#
#   Test 1: gh pr merge fails, re-query shows state=OPEN (mergeStateStatus
#           DIRTY)  → non-zero exit, no "Done." line, steps 5-7 (reap wait,
#           tmux/worktree kill, branch sweep) never reached.
#   Test 2: gh pr merge fails, re-query shows state=MERGED (the harmless
#           local-delete-style case) → proceeds, exits 0, reaches "Done."
#
# Stubs `gh` and `tmux` via PATH override — no GitHub auth, no tmux server.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
[ -x "$MERGE" ] || red "not executable: $MERGE"

TEST_DIR=$(mktemp -d -t shape-merge-refused-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

REPO="$TEST_DIR/main/some-project"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

export MIGRATION_GATE=0   # not what this test exercises; keep it out of the way
export GH_LOG="$TEST_DIR/gh.log"
: > "$GH_LOG"

# POST_STATE_FILE controls what the post-merge re-query reports; each test
# below overwrites it before invoking swarm-merge.sh.
export POST_STATE_FILE="$TEST_DIR/post-state.json"

# The normal stub: initial PR_JSON fetch reports a clean, mergeable OPEN PR;
# `gh pr merge` always refuses (that's what Tests 1-2 exercise); the
# post-merge re-query (issue #492) reads $POST_STATE_FILE, set per test.
write_normal_gh_stub() {
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/"*) echo "true"; exit 0 ;;
    "pr merge") exit 1 ;;   # always refuses — that's what this test exercises
    "pr view")
        case "$*" in
            *comments*)             echo '{"comments":[]}'; exit 0 ;;
            # swarm-merge.sh's post-merge re-query (issue #492): no
            # "mergeable" in the field list, so this doesn't collide with
            # the initial PR_JSON fetch below.
            *state,mergeStateStatus*) cat "$POST_STATE_FILE"; exit 0 ;;
            *state,mergeable*)      echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"fix/issue-77","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"
}
write_normal_gh_stub

# ============================================================================
heading "Test 0: mergeStateStatus already DIRTY on the initial fetch → refuse before ever calling gh pr merge"
# ============================================================================
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/"*) echo "true"; exit 0 ;;
    "pr merge") exit 1 ;;
    "pr view")
        case "$*" in
            *comments*)             echo '{"comments":[]}'; exit 0 ;;
            *state,mergeable*)      echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"DIRTY","headRefName":"fix/issue-77","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

set +e
OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1)
RC=$?
set -e

[ "$RC" -ne 0 ] || red "expected non-zero exit when mergeStateStatus is already DIRTY, got 0:\n$OUT"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge must never be called once the pre-merge DIRTY gate refuses:\n$(cat "$GH_LOG")"
echo "$OUT" | grep -qi "DIRTY" || red "expected the refusal to name mergeStateStatus=DIRTY, got:\n$OUT"
green "mergeStateStatus=DIRTY on the initial fetch refuses before gh pr merge is ever called"
: > "$GH_LOG"
write_normal_gh_stub

# ============================================================================
heading "Test 1: gh pr merge fails, re-query shows still OPEN → refuse, no cleanup"
# ============================================================================
echo '{"state":"OPEN","mergeStateStatus":"DIRTY"}' > "$POST_STATE_FILE"

set +e
OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1)
RC=$?
set -e

[ "$RC" -ne 0 ] || red "expected non-zero exit when the PR is still OPEN after a refused merge, got 0:\n$OUT"
echo "$OUT" | grep -q "Done\." && red "must not print a 'Done.' line when the merge was refused:\n$OUT"
echo "$OUT" | grep -qE '\[5/7\]|\[6/7\]|\[7/7\]' && red "must not reach steps 5-7 (reap wait / kill / sweep) after a refused merge:\n$OUT"
echo "$OUT" | grep -q "state=OPEN" || red "expected the remedy hint to name the actual state, got:\n$OUT"
echo "$OUT" | grep -qi "rebase" || red "expected a rebase-and-retry remedy hint, got:\n$OUT"
green "refused merge (still OPEN) exits non-zero with no 'Done.' and no cleanup steps"

# ============================================================================
heading "Test 2: gh pr merge fails, re-query shows MERGED → tolerate, proceed, exit 0"
# ============================================================================
echo '{"state":"MERGED","mergeStateStatus":"MERGED"}' > "$POST_STATE_FILE"

OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1) || red "expected exit 0 once the re-query confirms MERGED:\n$OUT"
echo "$OUT" | grep -q "Done\." || red "expected a 'Done.' completion line once MERGED is confirmed, got:\n$OUT"
grep -q "pr merge 77" "$GH_LOG" || red "gh pr merge 77 was not called"
green "refused-but-actually-MERGED case tolerates the failure and completes"

# ============================================================================
heading "All #492 shape tests passed"
# ============================================================================
green "swarm-merge.sh only tolerates a refused gh pr merge when the PR is confirmed MERGED"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
