#!/usr/bin/env bash
#
# test-shape-review.sh — Non-LLM shape tests for the self-review machinery
# (ringer concept #2; docs/ringer-adoptions.md):
#
#   - self-review-pr.sh   verdict parsing, exit codes, --post, idempotency,
#                         WORKER_SELF_REVIEW kill switch
#   - swarm-merge.sh      BLOCK-verdict merge gate + --override-review
#
# Stubs `gh`, `claude`, and `tmux` via PATH override — no GitHub auth, no
# LLM tokens, no tmux server.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$SCRIPT_DIR/../scripts/self-review-pr.sh"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
for s in "$REVIEW" "$MERGE"; do
    [ -x "$s" ] || red "not executable: $s"
done

TEST_DIR=$(mktemp -d -t shape-review-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────── Stub gh + claude + tmux ───────────────────────────

export GH_LOG="$TEST_DIR/gh.log"
export GH_COMMENTS_FILE="$TEST_DIR/comments.txt"
export CLAUDE_STUB_OUTPUT="$TEST_DIR/review-output.txt"
: > "$GH_COMMENTS_FILE"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "pr diff")    echo "diff --git a/f.txt b/f.txt"; exit 0 ;;
    "pr comment") exit 0 ;;
    "pr merge")   exit 0 ;;
    "pr view")
        case "$*" in
            *comments*)          cat "$GH_COMMENTS_FILE" 2>/dev/null; exit 0 ;;
            *title,body*)        printf 'Fake PR title\n\nFake PR body\n'; exit 0 ;;
            *state,mergeable*)   echo '{"state":"OPEN","mergeable":"MERGEABLE","headRefName":"fix/issue-9","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
    "issue view")
        case "$*" in
            *closedByPullRequestsReferences*) echo "77"; exit 0 ;;
            *state*)                          echo "OPEN"; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
cat > "$TEST_DIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # consume the payload from stdin
cat "$CLAUDE_STUB_OUTPUT"
EOF
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/claude" "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

# ============================================================================
heading "Test 1: APPROVE verdict → exit 0"
# ============================================================================
printf 'APPROVE\n' > "$CLAUDE_STUB_OUTPUT"
if OUT=$("$REVIEW" 42); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 for APPROVE, got $RC"
echo "$OUT" | grep -q "verdict: APPROVE" || red "verdict line missing"
green "APPROVE parsed, exit 0"

# ============================================================================
heading "Test 2: BLOCK verdict → exit 2; APPROVE_WITH_CAVEATS → exit 3"
# ============================================================================
printf 'BLOCK: missing null check in foo()\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2 for BLOCK, got $RC"
printf 'APPROVE_WITH_CAVEATS: no test for timeout path\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 3 ] || red "expected exit 3 for CAVEATS, got $RC"
green "BLOCK → 2, APPROVE_WITH_CAVEATS → 3"

# ============================================================================
heading "Test 3: unparseable output → exit 1"
# ============================================================================
printf 'I think this is probably fine?\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "expected exit 1 for unparseable, got $RC"
green "unparseable verdict → exit 1"

# ============================================================================
heading "Test 4: --post adds marker comment; idempotent on re-run"
# ============================================================================
printf 'BLOCK: broken invariant\n' > "$CLAUDE_STUB_OUTPUT"
: > "$GH_LOG"
if "$REVIEW" 42 --post >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "post run: expected exit 2, got $RC"
grep -q "pr comment 42" "$GH_LOG" || red "no pr comment call logged"
green "--post posts the verdict comment"

# Simulate the comment now existing → second --post must skip
printf '<!-- SWARM_SELF_REVIEW: BLOCK -->\nreview text\n' > "$GH_COMMENTS_FILE"
: > "$GH_LOG"
OUT=$("$REVIEW" 42 --post || true)
echo "$OUT" | grep -q "post: skipped" || red "expected idempotent skip"
grep -q "pr comment" "$GH_LOG" && red "comment posted despite existing marker"
green "idempotent: existing marker comment → post skipped"

# ============================================================================
heading "Test 5: WORKER_SELF_REVIEW=0 kill switch → exit 4"
# ============================================================================
if WORKER_SELF_REVIEW=0 "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 4 ] || red "expected exit 4 when kill switch set, got $RC"
green "WORKER_SELF_REVIEW=0 → skipped (exit 4)"

# ============================================================================
heading "Test 6: swarm-merge BLOCK gate"
# ============================================================================
# Fixture repo so swarm-merge can resolve a main worktree.
cd "$TEST_DIR"
mkdir repo && cd repo
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

printf '<!-- SWARM_SELF_REVIEW: BLOCK -->\nreview text\n' > "$GH_COMMENTS_FILE"
: > "$GH_LOG"
if "$MERGE" 9 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "merge should refuse on BLOCK verdict"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite BLOCK"
green "BLOCK verdict refuses merge, gh pr merge never called"

: > "$GH_LOG"
if "$MERGE" 9 --override-review >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "override-review merge failed (rc=$RC)"
grep -q "pr merge 77" "$GH_LOG" || red "gh pr merge not called under --override-review"
green "--override-review proceeds to merge"

# No verdict comment → merge proceeds (informational only)
: > "$GH_COMMENTS_FILE"
: > "$GH_LOG"
if "$MERGE" 9 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "merge without verdict comment should proceed (rc=$RC)"
grep -q "pr merge 77" "$GH_LOG" || red "gh pr merge not called in no-verdict case"
green "no verdict comment → merge proceeds"

# ============================================================================
heading "All self-review machinery shape tests passed"
green "verdict parsing, exit codes, --post idempotency, kill switch, merge gate"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
