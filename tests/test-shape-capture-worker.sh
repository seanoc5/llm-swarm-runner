#!/usr/bin/env bash
#
# test-shape-capture-worker.sh — Non-LLM shape tests for capture-worker.sh
# (issue #219): tags known UI-chrome lines inline, and --verify checks a
# fixture session transcript for whether text was actually submitted.
#
# Stubs `tmux` via PATH override — no live tmux server. The stub serves
# canned pane fixtures for iss-* windows and records what it was asked for.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE="$SCRIPT_DIR/../scripts/capture-worker.sh"
[ -x "$CAPTURE" ] || red "not executable: $CAPTURE"

TEST_DIR=$(mktemp -d -t shape-capture-worker-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR"
SESSION="llm-myproject"

# ─────────────────────── Stub tmux on PATH ────────────────────────
export PANE_DIR="$TEST_DIR/panes"
export WINDOWS_FILE="$TEST_DIR/windows.txt"
mkdir -p "$PANE_DIR"
: > "$WINDOWS_FILE"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-L" ] && shift 2
case "$1" in
    has-session)
        exit 0 ;;
    list-windows)
        cat "$WINDOWS_FILE"
        exit 0 ;;
    capture-pane)
        args="$*"
        win="${args##*:}"
        win="${win%% *}"
        cat "$PANE_DIR/$win" 2>/dev/null
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

set_windows() { printf '%s\n' "$@" > "$WINDOWS_FILE"; }

# ============================================================================
heading "Test 1: known UI-chrome lines get tagged, real output does not"
# ============================================================================
cat > "$PANE_DIR/iss-1" <<'PANE'
some normal tool output
※ recap: worker did a thing
✻ Brewed for 3s
❯ Loop in Radesh and John on this PR for review
plain response text
PANE
set_windows iss-1
OUT=$("$CAPTURE" "$PROJECT_DIR" iss-1 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 for dump mode, got $RC: $OUT"
echo "$OUT" | grep -q '^\[UI-CHROME\] ※ recap: worker did a thing' || red "recap line not tagged: $OUT"
echo "$OUT" | grep -q '^\[UI-CHROME\] ✻ Brewed for 3s' || red "spinner line not tagged: $OUT"
echo "$OUT" | grep -q '^some normal tool output$' || red "real output line was mangled: $OUT"
echo "$OUT" | grep -q '^plain response text$' || red "real response line was mangled: $OUT"
# The composer-suggestion line has no distinguishing plain-text marker of its
# own (that's the whole problem #219 reports) — capture-worker.sh does not
# claim to detect it by pattern; it must go untagged, same as real input.
echo "$OUT" | grep -q '^❯ Loop in Radesh and John on this PR for review$' || red "composer-suggestion line should render untagged (indistinguishable by design): $OUT"
green "known chrome markers tagged [UI-CHROME]; real output passes through untouched"

# ============================================================================
heading "Test 2: --verify FOUND when text is in the session transcript"
# ============================================================================
WT_DIR="$(dirname "$PROJECT_DIR")/wt-issue-2"
SLUG="$(printf '%s' "$WT_DIR" | tr '/' '-')"
FAKE_HOME="$TEST_DIR/fakehome"
mkdir -p "$FAKE_HOME/.claude/projects/$SLUG"
printf '{"role":"user","content":"please loop in Radesh on this PR"}\n' \
    > "$FAKE_HOME/.claude/projects/$SLUG/session1.jsonl"

OUT=$(HOME="$FAKE_HOME" "$CAPTURE" "$PROJECT_DIR" iss-2 --verify "loop in Radesh" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 for a real transcript hit, got $RC: $OUT"
echo "$OUT" | grep -q "^FOUND" || red "expected FOUND, got: $OUT"
echo "$OUT" | grep -q "session1.jsonl" || red "expected matching file named in output, got: $OUT"
green "--verify: text present in transcript → FOUND, exit 0"

# ============================================================================
heading "Test 3: --verify NOT FOUND when text never appears in the transcript"
# ============================================================================
OUT=$(HOME="$FAKE_HOME" "$CAPTURE" "$PROJECT_DIR" iss-2 --verify "delete production database" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 1 ] || red "expected exit 1 for a transcript miss, got $RC: $OUT"
echo "$OUT" | grep -q "^NOT FOUND" || red "expected NOT FOUND, got: $OUT"
green "--verify: text absent from transcript → NOT FOUND, exit 1"

# ============================================================================
heading "Test 4: --verify against a worktree with no transcript dir is a setup error"
# ============================================================================
OUT=$(HOME="$FAKE_HOME" "$CAPTURE" "$PROJECT_DIR" iss-999 --verify "anything" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 2 ] || red "expected exit 2 for missing transcript dir, got $RC: $OUT"
green "--verify: no transcript dir for the worktree → usage/setup error, exit 2"

# ============================================================================
heading "All capture-worker shape tests passed"
# ============================================================================
green "chrome tagging and transcript-verify both behave as documented"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
