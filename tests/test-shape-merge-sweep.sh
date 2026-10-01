#!/usr/bin/env bash
#
# test-shape-merge-sweep.sh — regression test for issue #465's third fix:
# run_sweep used to make one `gh issue view` round-trip per local
# fix/issue-* branch; it now makes exactly one `gh issue list` call and
# matches branch numbers against it locally. A self-review finding on
# PR #526 noted no existing test actually exercised run_sweep deleting a
# real CLOSED branch through this batched path — every other test's `gh`
# stub returns `[]` for "issue list". This fixture populates a real listing
# and a real git repo with several local fix/issue-* branches, covering the
# CLOSED (delete), OPEN (keep — in-flight worker), and missing-from-the-
# listing (skip, same fail-safe UNKNOWN fallback a lookup error used to
# produce) cases in one pass of `swarm-merge.sh --sweep-only`.
#
# Stubs `gh` via PATH override; counts its invocations to also prove the
# batching itself (one call total, not one per branch — the actual point
# of issue #465's third fix).
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
[ -x "$MERGE" ] || red "not executable: $MERGE"

TEST_DIR=$(mktemp -d -t shape-merge-sweep-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

REPO="$TEST_DIR/repo"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Four local fix/issue-* branches: 801 CLOSED (must be deleted), 802 OPEN
# (must be kept — worker may be in flight), 803 absent from the gh listing
# entirely (must be skipped, not deleted — the fail-safe UNKNOWN path), and
# 804 CLOSED with a non-numeric-suffix branch name (fix/issue-804-retry, to
# confirm the leading-number extraction still works).
for n in 801 802 803; do
    git branch "fix/issue-$n"
done
git branch "fix/issue-804-retry"

# ─────────────────────── Stub gh ───────────────────────────────────────────
#
# One fixture call to `gh issue list` serves every branch; 803 is
# deliberately left out of the listing to exercise the missing-from-listing
# fallback. A call log proves run_sweep makes exactly one `gh issue list`
# call regardless of branch count — the actual batching this fix is about.
mkdir -p "$TEST_DIR/bin"
GH_CALL_LOG="$TEST_DIR/gh-calls.log"
: > "$GH_CALL_LOG"
cat > "$TEST_DIR/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_CALL_LOG"
if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "list" ]; then
    echo '[{"number":801,"state":"CLOSED"},{"number":802,"state":"OPEN"},{"number":804,"state":"CLOSED"}]'
    exit 0
fi
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"

# ============================================================================
heading "Test 1: --sweep-only deletes CLOSED, keeps OPEN, skips the branch missing from the listing"
# ============================================================================
OUT=$(timeout 15 "$MERGE" --sweep-only 2>&1) || red "swarm-merge.sh --sweep-only exited non-zero:\n$OUT"

git show-ref --verify --quiet refs/heads/fix/issue-801 \
    && red "fix/issue-801 (CLOSED) should have been deleted:\n$OUT"
green "fix/issue-801 (CLOSED) was deleted"

git show-ref --verify --quiet refs/heads/fix/issue-802 \
    || red "fix/issue-802 (OPEN) should have been kept — a kept branch means an in-flight worker's work wasn't destroyed:\n$OUT"
green "fix/issue-802 (OPEN) was kept"

git show-ref --verify --quiet refs/heads/fix/issue-803 \
    || red "fix/issue-803 (missing from the gh issue list listing) should have been kept, not deleted — the fail-safe UNKNOWN fallback must still apply under the batched lookup:\n$OUT"
green "fix/issue-803 (absent from the listing) was skipped, not deleted — fail-safe preserved"

git show-ref --verify --quiet refs/heads/fix/issue-804-retry \
    && red "fix/issue-804-retry (issue #804 CLOSED, suffixed branch name) should have been deleted — leading-number extraction broke:\n$OUT"
green "fix/issue-804-retry (CLOSED issue #804, suffixed branch name) was deleted"

echo "$OUT" | grep -q "deleted=2, kept_open=1, skipped=1" \
    || red "expected the sweep summary to report deleted=2, kept_open=1, skipped=1; got:\n$OUT"
green "sweep summary line matches: deleted=2, kept_open=1, skipped=1"

# ============================================================================
heading "Test 2: exactly one gh call total, regardless of branch count (the actual #465 fix)"
# ============================================================================
GH_ISSUE_LIST_CALLS=$(grep -c '^issue list' "$GH_CALL_LOG" || true)
[ "$GH_ISSUE_LIST_CALLS" -eq 1 ] \
    || red "expected exactly 1 'gh issue list' call for 4 branches; got $GH_ISSUE_LIST_CALLS. Call log:\n$(cat "$GH_CALL_LOG")"
green "run_sweep made exactly 1 'gh issue list' call for 4 branches — not one gh call per branch"

# ============================================================================
heading "Test 3: no local fix/issue-* branches at all — zero gh calls"
# ============================================================================
: > "$GH_CALL_LOG"
REPO2="$TEST_DIR/repo2"
mkdir -p "$REPO2" && cd "$REPO2"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

OUT=$(timeout 15 "$MERGE" --sweep-only 2>&1) || red "--sweep-only exited non-zero with no branches:\n$OUT"
echo "$OUT" | grep -q "deleted=0, kept_open=0, skipped=0" \
    || red "expected an all-zero summary with no fix/issue-* branches; got:\n$OUT"
[ ! -s "$GH_CALL_LOG" ] \
    || red "expected zero gh calls when there are no local fix/issue-* branches to sweep; got:\n$(cat "$GH_CALL_LOG")"
green "zero fix/issue-* branches → zero gh calls, all-zero summary"

# ============================================================================
heading "All swarm-merge sweep-batching shape tests passed"
# ============================================================================
green "run_sweep's single gh-issue-list batching deletes CLOSED, keeps OPEN, fail-safes on missing/UNKNOWN, and never calls gh per-branch"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
