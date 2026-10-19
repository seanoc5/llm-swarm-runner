#!/usr/bin/env bash
#
# test-shape-merge-conflict-brief.sh — a conflicting PR whose worker is still
# on disk gets a resolve-conflicts brief queued into its inbox (exit 3)
# instead of a dead-end refusal; a second run doesn't queue a duplicate; no
# worker on disk keeps the old refusal (exit 1).
#
#   Test 1: CONFLICTING + live worktree → brief queued, exit 3, no merge call.
#   Test 2: same again → no second brief, still exit 3.
#   Test 3: DIRTY + --auto-low → brief path, re-run hint keeps --auto-low.
#   Test 4: CONFLICTING, no worktree → exit 1, no brief.
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

TEST_DIR=$(mktemp -d -t shape-merge-conflict-brief-XXXXXX)
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
exit 1
EOF
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

REPO="$TEST_DIR/main/some-project"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

export MIGRATION_GATE=0
export SWARM_WORKTREE_GROUPING=flat
export GH_LOG="$TEST_DIR/gh.log"
export PR_SHAPE_FILE="$TEST_DIR/pr-shape.json"
: > "$GH_LOG"

cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/"*) echo "true"; exit 0 ;;
    "pr merge") exit 1 ;;
    "pr view")
        case "$*" in
            *headRefName*) cat "$PR_SHAPE_FILE"; exit 0 ;;
        esac
        exit 1 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

# Flat grouping (the default): the worker lives at ../wt-issue-77.
WT="$TEST_DIR/main/wt-issue-77"
INBOX="$WT/.swarm/tasks/inbox"
mkdir -p "$INBOX" "$WT/.swarm/tasks/processing"

echo '{"state":"OPEN","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","headRefName":"fix/issue-77","title":"fake","baseRefName":"master"}' > "$PR_SHAPE_FILE"

# ============================================================================
heading "Test 1: CONFLICTING + live worktree → brief queued, exit 3"
# ============================================================================
set +e
OUT=$(timeout 10 "$MERGE" 101 --no-kill 2>&1)
RC=$?
set -e
[ "$RC" -eq 3 ] || red "expected exit 3, got $RC:\n$OUT"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge must not be called for a conflicting PR"
n=$(find "$INBOX" -name '*.md' | wc -l)
[ "$n" -eq 1 ] || red "expected exactly one brief in the inbox, found $n"
BRIEF=$(find "$INBOX" -name '*.md')
grep -q "swarm-merge:conflict-brief pr=101 " "$BRIEF" || red "brief lacks the dedupe marker:\n$(cat "$BRIEF")"
grep -q "origin/master" "$BRIEF" || red "brief should name the base branch:\n$(cat "$BRIEF")"
echo "$OUT" | grep -q "Re-run once it has pushed and CI is green: swarm-merge.sh 101$" \
    || red "expected a plain re-run hint, got:\n$OUT"
green "brief queued, exit 3, no merge attempted"

# ============================================================================
heading "Test 2: second run → no duplicate brief"
# ============================================================================
set +e
OUT=$(timeout 10 "$MERGE" 101 --no-kill 2>&1)
RC=$?
set -e
[ "$RC" -eq 3 ] || red "expected exit 3 on the second run, got $RC:\n$OUT"
n=$(find "$INBOX" -name '*.md' | wc -l)
[ "$n" -eq 1 ] || red "expected still one brief, found $n"
echo "$OUT" | grep -q "already queued" || red "expected an 'already queued' note, got:\n$OUT"
green "second run is idempotent"

# ============================================================================
heading "Test 3: DIRTY + --auto-low → brief path, hint keeps --auto-low"
# ============================================================================
rm -f "$INBOX"/*.md
echo '{"state":"OPEN","mergeable":"UNKNOWN","mergeStateStatus":"DIRTY","headRefName":"fix/issue-77","title":"fake","baseRefName":"master"}' > "$PR_SHAPE_FILE"
set +e
OUT=$(timeout 10 "$MERGE" 101 --no-kill --auto-low 2>&1)
RC=$?
set -e
[ "$RC" -eq 3 ] || red "expected exit 3, got $RC:\n$OUT"
[ "$(find "$INBOX" -name '*.md' | wc -l)" -eq 1 ] || red "expected one brief for the DIRTY case"
echo "$OUT" | grep -q "swarm-merge.sh 101 --auto-low" || red "re-run hint should keep --auto-low, got:\n$OUT"
green "DIRTY with --auto-low queues a brief and keeps the flag in the hint"

# ============================================================================
heading "Test 4: CONFLICTING, no worktree → exit 1, no brief"
# ============================================================================
rm -rf "$WT"
echo '{"state":"OPEN","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","headRefName":"fix/issue-77","title":"fake","baseRefName":"master"}' > "$PR_SHAPE_FILE"
set +e
OUT=$(timeout 10 "$MERGE" 101 --no-kill 2>&1)
RC=$?
set -e
[ "$RC" -eq 1 ] || red "expected exit 1 with no worker, got $RC:\n$OUT"
echo "$OUT" | grep -q "provision-worker.sh 77" || red "expected a respawn hint naming the issue, got:\n$OUT"
green "no worker → refusal with a respawn hint"

echo
green "all conflict-brief tests passed"
