#!/usr/bin/env bash
#
# test-shape-stuck-workers.sh — Non-LLM shape tests for
# check-stuck-workers.sh (issue #194), focused on the IDLE-PARKED
# detection added in PR #176 (the `[polling for next brief` marker
# printed by worker-listener.sh's print_completion_block()).
#
# Stubs `tmux` and `docker` via PATH override — no live tmux server, no
# real containers. The stub tmux serves canned pane fixtures for a
# handful of iss-* windows and records what it was asked for.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/check-stuck-workers.sh"
[ -x "$CHECK" ] || red "not executable: $CHECK"

TEST_DIR=$(mktemp -d -t shape-stuck-workers-XXXXXX)
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
SOCKET="swarm-myproject"

# ─────────────────────── Stub tmux + docker on PATH ────────────────────────
#
# Fixture panes live as plain text files; PANE_DIR/<window> holds the
# captured content, WINDOWS lists the iss-* window names in order.
export PANE_DIR="$TEST_DIR/panes"
export WINDOWS_FILE="$TEST_DIR/windows.txt"
export TMUX_LOG="$TEST_DIR/tmux.log"
mkdir -p "$PANE_DIR"
: > "$TMUX_LOG"
: > "$WINDOWS_FILE"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TMUX_LOG"
# All our test invocations pass -L <socket> first; shift it off.
[ "$1" = "-L" ] && shift 2
case "$1" in
    has-session)
        exit 0 ;;
    list-windows)
        cat "$WINDOWS_FILE"
        exit 0 ;;
    list-panes)
        printf '0|0|bash\n'
        exit 0 ;;
    capture-pane)
        # -t SESSION:window — join args first; ${*##pattern} applies
        # per-positional-parameter rather than to the joined string.
        args="$*"
        win="${args##*:}"
        win="${win%% *}"
        cat "$PANE_DIR/$win" 2>/dev/null
        exit 0 ;;
esac
exit 0
EOF
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Pretend every window's container is alive so state detection isn't
# short-circuited by the container_alive=0 branch.
if [ "$1 $2" = "ps --format" ]; then
    cat "$PANE_DIR/../containers.txt" 2>/dev/null
    exit 0
fi
exit 0
EOF
chmod +x "$TEST_DIR/bin/tmux" "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH"

set_windows() {
    printf '%s\n' "$@" > "$WINDOWS_FILE"
    : > "$TEST_DIR/containers.txt"
    for w in "$@"; do
        echo "swarm-${SESSION}-${w}" >> "$TEST_DIR/containers.txt"
    done
}

# ============================================================================
heading "Test 1: IDLE-PARKED matches the PR #176 marker on a successful completion"
# ============================================================================
cat > "$PANE_DIR/iss-1" <<'PANE'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  TASK COMPLETE    exit=0    duration=42s
  PR #501 opened — gh pr view 501
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

What to do next:
  • Accept & merge:   gh pr merge 501 --squash
  • Reject:           gh pr close 501
  • Follow up here:   requeue.sh 1 "<follow-up brief>"
  • Leave it          this listener will pick up the next brief on inbox/

(Watcher detects PR-state changes; this slot frees automatically — see #32)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[12:00:00] [polling for next brief in wt-issue-1/inbox/ ...]
PANE
set_windows iss-1
OUT=$("$CHECK" "$PROJECT_DIR" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 for IDLE-PARKED-only session, got $RC: $OUT"
echo "$OUT" | grep -q "IDLE-PARKED" || red "expected IDLE-PARKED in output, got: $OUT"
green "success completion → [polling for next brief] → IDLE-PARKED, exit 0"

# ============================================================================
heading "Test 2: IDLE-PARKED also matches on a failed completion"
# ============================================================================
cat > "$PANE_DIR/iss-2" <<'PANE'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  TASK FAILED       exit=1    duration=12s
  Blocked: needs a decision on migration strategy
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

What to do next:
  • Investigate:      gh pr view, scrollback above, brief at inbox/2.md
  • Follow up here:   requeue.sh 2 "<follow-up brief>"
  • Leave it          this listener will pick up the next brief on inbox/

(Watcher detects PR-state changes; this slot frees automatically — see #32)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[12:05:00] [polling for next brief in wt-issue-2/inbox/ ...]
PANE
set_windows iss-2
OUT=$("$CHECK" "$PROJECT_DIR" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 for IDLE-PARKED-only session, got $RC: $OUT"
echo "$OUT" | grep -q "IDLE-PARKED" || red "expected IDLE-PARKED in output, got: $OUT"
green "failed completion → [polling for next brief] → still IDLE-PARKED, exit 0"

# ============================================================================
heading "Test 3: an active pane does NOT match IDLE-PARKED"
# ============================================================================
cat > "$PANE_DIR/iss-3" <<'PANE'
✻ Considering next steps… (esc to interrupt)

  Reading scripts/check-stuck-workers.sh
PANE
set_windows iss-3
OUT=$("$CHECK" "$PROJECT_DIR" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 for ACTIVE-only session, got $RC: $OUT"
echo "$OUT" | grep -q "IDLE-PARKED" && red "active pane should NOT be classified IDLE-PARKED: $OUT"
echo "$OUT" | grep -q "ACTIVE" || red "expected ACTIVE in output, got: $OUT"
green "active pane → ACTIVE, never IDLE-PARKED"

# ============================================================================
heading "Test 4: mixed session — one parked, one active — table shows both, exit 0"
# ============================================================================
set_windows iss-1 iss-3
OUT=$("$CHECK" "$PROJECT_DIR" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 for all-healthy mixed session, got $RC: $OUT"
echo "$OUT" | grep -q "iss-1.*IDLE-PARKED" || red "expected iss-1 row IDLE-PARKED, got: $OUT"
echo "$OUT" | grep -q "iss-3.*ACTIVE" || red "expected iss-3 row ACTIVE, got: $OUT"
green "mixed session: both rows present, correctly classified, exit 0"

# ============================================================================
heading "All check-stuck-workers shape tests passed"
# ============================================================================
green "IDLE-PARKED marker matches success + failure completions, never an active pane"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
