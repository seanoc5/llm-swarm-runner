#!/usr/bin/env bash
#
# test-shape-merge-squash-flag.sh — regression test for #365:
# swarm-merge.sh must accept --squash as a no-op (it is already the only
# merge mode the script implements — the strict `-*` unknown-flag arm was
# rejecting the natural `gh pr merge --squash` idiom). --merge and --rebase
# must keep failing loudly, with a clearer message than the generic
# unknown-flag text, since they'd contradict what the script actually does.
# General unknown flags must still exit 2.
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

TEST_DIR=$(mktemp -d -t shape-merge-squash-XXXXXX)
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
[ "${1:-}" = "list-windows" ] && exit 0
exit 0
EOF
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

REPO="$TEST_DIR/main/some-project"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

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

# ============================================================================
heading "Test 1: --squash behaves exactly like no flag at all"
# ============================================================================
BASELINE=$(timeout 5 "$MERGE" 500 --no-kill 2>&1) || red "baseline (no --squash) failed:\n$BASELINE"
WITH_SQUASH=$(timeout 5 "$MERGE" 500 --squash --no-kill 2>&1) || red "--squash was rejected:\n$WITH_SQUASH"
[ "$BASELINE" = "$WITH_SQUASH" ] || red "--squash changed output vs. no flag:\nbaseline:\n$BASELINE\nwith --squash:\n$WITH_SQUASH"
green "--squash is a true no-op: output identical to omitting it"

# ============================================================================
heading "Test 2: --squash combines with other flags (order-independent)"
# ============================================================================
OUT=$(timeout 5 "$MERGE" --no-kill --squash 500 2>&1) || red "--squash before/around other flags failed:\n$OUT"
echo "$OUT" | grep -q "merged for issue #500" || red "expected normal merge completion, got:\n$OUT"
green "--squash combines with --no-kill regardless of position"

# ============================================================================
heading "Test 3: --merge and --rebase are rejected with a clear, specific message"
# ============================================================================
for flag in --merge --rebase; do
    set +e
    OUT=$(timeout 5 "$MERGE" 500 "$flag" --no-kill 2>&1)
    RC=$?
    set -e
    [ "$RC" -ne 0 ] || red "$flag should have failed, got exit 0:\n$OUT"
    echo "$OUT" | grep -q "swarm-merge.sh always squashes" || red "expected the specific $flag rejection message, got:\n$OUT"
    green "$flag rejected with a clear, non-generic message"
done

# ============================================================================
heading "Test 4: unrecognized flags still exit 2 with the generic message"
# ============================================================================
set +e
OUT=$(timeout 5 "$MERGE" 500 --bogus-flag --no-kill 2>&1)
RC=$?
set -e
[ "$RC" -eq 2 ] || red "expected exit 2 for an unknown flag, got $RC:\n$OUT"
echo "$OUT" | grep -q "unknown flag '--bogus-flag'" || red "expected the generic unknown-flag message, got:\n$OUT"
green "unrelated unknown flags are still rejected with exit 2 — no relaxation of the strict parser"

# ============================================================================
heading "All swarm-merge --squash flag tests passed"
# ============================================================================
green "swarm-merge.sh accepts --squash as a no-op per #365"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
