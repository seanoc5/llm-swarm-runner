#!/usr/bin/env bash
#
# test-shape-merge-pr-number.sh — regression test for #324:
# swarm-merge.sh must accept a PR number as well as an issue number.
# GitHub shares one numbering sequence across issues and PRs, so #N is
# always exactly one object; swarm-merge.sh now probes
# `gh api repos/{owner}/{repo}/issues/N --jq '.pull_request != null'`
# to tell them apart, then:
#   - given an issue: resolves its linked PR (pre-#324 behavior, unchanged)
#   - given a PR: walks back to an issue so the issue-keyed cleanup (tmux
#     window / worktree reap wait) still runs, preferring the fix/issue-N
#     branch name (the actual key of the local artifacts) over the PR's
#     closingIssuesReferences (free-text, can be empty or name a different
#     issue than the worker's own branch)
#   - given a PR with NEITHER a matching branch name nor a closing-issue
#     reference: still merges, but explicitly skips (rather than
#     silently no-ops) the issue-keyed cleanup
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

TEST_DIR=$(mktemp -d -t shape-merge-prnum-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/bin"
# tmux stub: never reports any window alive, so the reap-wait loop (when it
# runs at all) resolves immediately via the worktree-absent path.
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "list-windows" ] && exit 0
exit 0
EOF
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

REPO="$TEST_DIR/main/some-project"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# ============================================================================
heading "Test 1: issue number given — unchanged pre-#324 behavior"
# ============================================================================
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/500")
        echo "false"; exit 0 ;;
    "issue view")
        case "$*" in
            *closedByPullRequestsReferences*) echo "77"; exit 0 ;;
        esac
        exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"fix/issue-500","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

OUT=$(timeout 5 "$MERGE" 500 --no-kill 2>&1) || red "issue-number path failed:\n$OUT"
echo "$OUT" | grep -q "issue #500 → PR #77" || red "expected issue→PR resolution line, got:\n$OUT"
echo "$OUT" | grep -q "merged for issue #500" || red "expected final line to name issue #500, got:\n$OUT"
green "issue number still resolves PR the old way"

# ============================================================================
heading "Test 2: PR number given, branch doesn't encode an issue — uses the closing-issue reference"
# ============================================================================
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/315")
        echo "true"; exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"some-other-branch","title":"fake","closingIssuesReferences":[{"number":310}]}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

OUT=$(timeout 5 "$MERGE" 315 --no-kill 2>&1) || red "PR-number-with-linked-issue path failed:\n$OUT"
echo "$OUT" | grep -q "closing-issue reference #310" || red "expected closing-issue-reference resolution line, got:\n$OUT"
echo "$OUT" | grep -q "merged for issue #310" || red "expected final line to name issue #310, got:\n$OUT"
echo "$OUT" | grep -qi "skipping tmux/worktree" && red "should NOT skip issue-keyed cleanup when a linked issue exists:\n$OUT"
green "PR number falls back to its closing-issue reference when the branch doesn't encode one; cleanup still issue-keyed"

# ============================================================================
heading "Test 2b: PR number given, branch AND closing-issue reference disagree — branch wins"
# ============================================================================
# self-review caveat (round 2) on the #324 PR: local artifacts (tmux window,
# worktree, branch) are keyed on the branch name provision-worker.sh assigned
# at spawn time, not on whatever issue# the PR body happens to cite. Using
# closingIssuesReferences as primary would let a PR body that cites a
# *different* issue kill/remove an unrelated worker's live session. The
# branch name must win whenever it parses as fix/issue-N.
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/316")
        echo "true"; exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"fix/issue-999","title":"fake","closingIssuesReferences":[{"number":310}]}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

OUT=$(timeout 5 "$MERGE" 316 --no-kill 2>&1) || red "PR-number branch-vs-reference precedence path failed:\n$OUT"
echo "$OUT" | grep -q "branch name encodes issue #999" || red "expected branch-name resolution line, got:\n$OUT"
echo "$OUT" | grep -q "merged for issue #999" || red "expected final line to name issue #999 (branch, not the #310 closing reference), got:\n$OUT"
echo "$OUT" | grep -q "issue #310" && red "must NOT use the mismatched closing-issue reference #310 when the branch names a different issue:\n$OUT"
green "branch name (#999) wins over a disagreeing closing-issue reference (#310) — never touches a different worker's artifacts"

# ============================================================================
heading "Test 3: PR number given, PR has NO linked issue — merges, skips cleanup, says so"
# ============================================================================
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/420")
        echo "true"; exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"some-branch","title":"fake","closingIssuesReferences":[]}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

OUT=$(timeout 5 "$MERGE" 420 --no-kill 2>&1) || red "PR-number-with-no-linked-issue path failed:\n$OUT"
echo "$OUT" | grep -qi "no linked issue — issue-keyed cleanup" || red "expected the no-linked-issue amber warning, got:\n$OUT"
echo "$OUT" | grep -qi "skipping tmux/worktree" || red "expected cleanup-skip lines when no issue is linked, got:\n$OUT"
echo "$OUT" | grep -q "merged (no linked issue)" || red "expected final line to say 'no linked issue', got:\n$OUT"
green "PR with no linked issue (neither branch nor closing reference) still merges; issue-keyed cleanup explicitly skipped, not silently no-opped"

# ============================================================================
heading "Test 3b: PR number given, no closing-issue reference, but branch name encodes the issue — falls back"
# ============================================================================
# self-review caveat (round 1) on the #324 PR: closingIssuesReferences only
# reflects closing keywords in the PR *body* — a title-only "(fixes #N)"
# leaves it empty. provision-worker.sh always names the branch fix/issue-N,
# so that's a cheap, reliable fallback before abandoning the live tmux
# window/worktree.
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/421")
        echo "true"; exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"fix/issue-333","title":"fake (title-only fixes #333)","closingIssuesReferences":[]}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

OUT=$(timeout 5 "$MERGE" 421 --no-kill 2>&1) || red "PR-number-with-branch-fallback path failed:\n$OUT"
echo "$OUT" | grep -q "branch name encodes issue #333" || red "expected branch-name fallback line, got:\n$OUT"
echo "$OUT" | grep -q "merged for issue #333" || red "expected final line to name issue #333 (from branch fallback), got:\n$OUT"
echo "$OUT" | grep -qi "skipping tmux/worktree" && red "should NOT skip issue-keyed cleanup once the branch-name fallback resolves an issue:\n$OUT"
green "no closing-issue reference but fix/issue-N branch name — falls back, cleanup stays issue-keyed"

# ============================================================================
heading "Test 4: number resolves as neither issue nor PR (probe fails, no linked PR either) — clear error"
# ============================================================================
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/99999")
        exit 1 ;;
    "issue view")
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

set +e
OUT=$(timeout 5 "$MERGE" 99999 --no-kill 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || red "expected non-zero exit for unresolvable number, got 0:\n$OUT"
echo "$OUT" | grep -q "could not resolve #99999 as an issue or PR" || red "expected explicit resolution-failure error, got:\n$OUT"
green "gh-api-probe failure with no fallback linked PR fails with a clear error"

# ============================================================================
heading "Test 5: gh api probe fails transiently, but the number IS a known issue — falls back, old behavior preserved"
# ============================================================================
# self-review caveat (round 3) on the #324 PR: the new gh-api classification
# probe is a hard prerequisite even for what used to be a plain issue-number
# call. A transient gh failure (rate limit, expired auth, network blip) must
# not regress an issue number that worked fine pre-#324 — fall back to the
# old gh issue view lookup instead of erroring immediately.
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/512")
        exit 1 ;;
    "issue view")
        case "$*" in
            *closedByPullRequestsReferences*) echo "88"; exit 0 ;;
        esac
        exit 0 ;;
    "pr view")
        case "$*" in
            *state,mergeable*) echo '{"state":"MERGED","mergeable":"MERGEABLE","headRefName":"fix/issue-512","title":"fake","closingIssuesReferences":[]}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

OUT=$(timeout 5 "$MERGE" 512 --no-kill 2>&1) || red "gh-api-probe-fails-but-issue-lookup-succeeds path failed:\n$OUT"
echo "$OUT" | grep -qi "could not classify.*falling back to issue lookup" || red "expected the probe-failure fallback notice, got:\n$OUT"
echo "$OUT" | grep -q "issue #512 → PR #88" || red "expected the fallback to still resolve issue→PR, got:\n$OUT"
echo "$OUT" | grep -q "merged for issue #512" || red "expected final line to name issue #512, got:\n$OUT"
green "transient gh api probe failure falls back to the pre-#324 issue-lookup path instead of erroring"

# ============================================================================
heading "All swarm-merge PR-number resolution tests passed"
# ============================================================================
green "swarm-merge.sh accepts issue numbers and PR numbers per #324"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
