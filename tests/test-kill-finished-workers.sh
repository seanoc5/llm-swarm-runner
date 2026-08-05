#!/usr/bin/env bash
#
# test-kill-finished-workers.sh — Non-LLM regression test for
# kill-finished-workers.sh (issue #223).
#
# The #223 bug: one worktree with a corrupt registration (its
# .git/worktrees/<wt> metadata pruned while the dir survived — common
# after a docker/session restart) made `git -C <wt> symbolic-ref` exit
# 128 inside worktree_branch(), and set -e aborted the ENTIRE reap pass
# — after kill decisions were made but before any kill executed. The
# watcher swallows the script's output, so autoclose was silently
# disabled for the whole swarm as long as the sick worktree existed.
#
# Strategy: real git fixture + real tmux server on a throwaway private
# socket (PATH shim so the script's bare `tmux` calls land there), gh
# stubbed via the same PATH shim dir. Windows are ordered so the corrupt
# worktree is processed BEFORE the healthy reap-eligible one — proving a
# sick worktree no longer takes down the reaps queued behind it.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_FINISHED="$SCRIPT_DIR/../scripts/kill-finished-workers.sh"
[ -x "$KILL_FINISHED" ] || red "kill-finished-workers.sh not executable: $KILL_FINISHED"

REAL_TMUX="$(command -v tmux)" || red "tmux not installed"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t kill-finished-XXXXXX)
TEST_SOCK="kfw-test-$$"
cleanup() {
    "$REAL_TMUX" -L "$TEST_SOCK" kill-server 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────── Shims: tmux (private socket) + gh ──────────────────
# kill-finished-workers.sh calls bare `tmux` and `gh`; a PATH shim dir
# redirects both without touching the script under test.

SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCK" "\$@"
EOF
chmod +x "$SHIM_DIR/tmux"

# gh stub: `gh pr view <branch> --json state -q .state` is the only shape
# the script uses. fix/issue-42 has a MERGED PR (reap-eligible); anything
# else has no PR (gh exits 1, like the real CLI's "no pull requests found").
GH_LOG="$TEST_DIR/gh.log"
cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ] && [ "\$3" = "fix/issue-42" ]; then
    echo "MERGED"
    exit 0
fi
exit 1
EOF
chmod +x "$SHIM_DIR/gh"

# ─────────────────────── Fixture: git repo + worktrees ──────────────────────

PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR"
git init -q "$PROJECT_DIR"
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name "Test"
echo hello > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" commit -q -m init

# Flat grouping: worktrees are siblings of the project dir.
export SWARM_WORKTREE_GROUPING=flat
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-42 "$TEST_DIR/wt-issue-42"
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-43 "$TEST_DIR/wt-issue-43"

# Corrupt #43's registration the same way the wild does it: the metadata
# dir under .git/worktrees vanishes while the worktree dir survives.
rm -rf "$PROJECT_DIR/.git/worktrees/wt-issue-43"
set +e
git -C "$TEST_DIR/wt-issue-43" symbolic-ref --quiet --short HEAD 2>/dev/null
CORRUPT_RC=$?
set -e
[ "$CORRUPT_RC" -eq 128 ] \
    || red "fixture self-check: expected git rc 128 from the corrupt worktree, got $CORRUPT_RC"
green "fixture: wt-issue-43 registration is corrupt (git exits 128 there)"

# ─────────────────────── Fixture: tmux session + windows ────────────────────
# SESSION_NAME derives from \$PWD basename → llm-proj. iss-43 (corrupt)
# is window 1 so the decision loop hits it BEFORE iss-42 (reap-eligible).

SESSION="llm-proj"
"$SHIM_DIR/tmux" new-session -d -s "$SESSION" -n iss-43
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-42
"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-42' \
    || red "fixture: tmux session/windows did not come up on private socket"

# ============================================================================
heading "Test 1: corrupt worktree no longer aborts the reap pass (issue #223)"
# ============================================================================

RUN_LOG="$TEST_DIR/run.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" \
    "$KILL_FINISHED" --pr-finalized --idle-min 0 --yes) > "$RUN_LOG" 2>&1
RC=$?
set -e

[ "$RC" -eq 0 ] || red "expected exit 0, got $RC (the #223 abort). Output:
$(cat "$RUN_LOG")"
green "script exited 0 with a corrupt worktree in the window list"

# ============================================================================
heading "Test 2: corrupt-worktree window is skipped, not killed"
# ============================================================================

grep -q 'iss-43.*skip' "$RUN_LOG" \
    || red "expected an explicit skip line for iss-43. Output:
$(cat "$RUN_LOG")"
"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-43' \
    || red "iss-43 window was killed — an unresolvable branch must never be reaped"
green "iss-43 skipped with its window preserved"

# ============================================================================
heading "Test 3: reap-eligible window BEHIND the corrupt one still gets reaped"
# ============================================================================

if "$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-42'; then
    red "iss-42 (PR MERGED) survived — the corrupt worktree still blocks reaps queued behind it. Output:
$(cat "$RUN_LOG")"
fi
grep -q 'Done\. Closed 1 window(s)\.' "$RUN_LOG" \
    || red "expected the 'Done. Closed 1 window(s).' summary the watcher parses. Output:
$(cat "$RUN_LOG")"
green "iss-42 reaped and killed=1 summary emitted despite the corrupt sibling"

grep -q 'reap\.window .*issue=42' "$PROJECT_DIR/.swarm/events.log" \
    || red "expected a reap.window event for issue 42 in events.log"
green "reap.window event recorded for issue 42"

echo
green "ALL TESTS PASSED"
