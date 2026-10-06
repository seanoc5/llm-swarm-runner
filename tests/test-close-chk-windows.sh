#!/usr/bin/env bash
#
# test-close-chk-windows.sh — self-review finding on PR #566 (issue #550,
# scoped delta): kill-worktree.sh and kill-finished-workers.sh's
# window-only reap path both call _load-env.sh's swarm_close_chk_windows()
# to close a stale `chk-N` fallback check window when reaping issue N's
# worktree — the window master's coordinator-watch.sh opens only when no
# iss-N window exists left to host the check as a pane instead.
#
# Kills by INDEX, not name, because a crashed or duplicated check run can
# leave two windows sharing the same `chk-N` name, and `tmux kill-window -t
# session:name` silently no-ops against a duplicate (matches neither, or
# the wrong one — see issue #550's evidence: chk-999 x2, chk-1000 x3).
#
# Requires: tmux.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"
[ -f "$LOAD_ENV" ] || red "_load-env.sh not found: $LOAD_ENV"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"

SOCK="test-chk-windows-$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

tmux() { command tmux -L "$SOCK" "$@"; }

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        green "$desc"
    else
        red "$desc (expected [$expected] got [$actual])"
    fi
}

window_names() {
    tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' '
}

# shellcheck source=../scripts/_load-env.sh
source "$LOAD_ENV" >/dev/null 2>&1 || true
command -v swarm_close_chk_windows >/dev/null 2>&1 || red "swarm_close_chk_windows not defined after sourcing _load-env.sh"

SESSION="chk-windows-test"
tmux new-session -d -s "$SESSION" -n coordinator 'sleep 300'

heading "Test 1: a bare chk-N window is closed, other windows are untouched"
tmux new-window -d -t "$SESSION" -n "iss-42" 'sleep 300'
tmux new-window -d -t "$SESSION" -n "chk-42" 'sleep 300'
swarm_close_chk_windows "$SESSION" 42
got="$(window_names)"
if printf '%s' "$got" | tr ' ' '\n' | grep -qx "chk-42"; then got_has_chk=present; else got_has_chk=absent; fi
check "chk-42 window gone" "absent" "$got_has_chk"
if printf '%s' "$got" | tr ' ' '\n' | grep -qx "iss-42"; then got_has_iss=present; else got_has_iss=absent; fi
check "iss-42 window left alone" "present" "$got_has_iss"

heading "Test 2: an idle-marker-renamed chk-N:pass window is also matched and closed"
tmux new-window -d -t "$SESSION" -n "chk-43:pass" 'sleep 300'
swarm_close_chk_windows "$SESSION" 43
if window_names | tr ' ' '\n' | grep -qx "chk-43:pass"; then got=present; else got=absent; fi
check "chk-43:pass window closed despite the idle-marker suffix" "absent" "$got"

heading "Test 3: duplicate chk-N windows (crashed/re-run check) are BOTH closed by index, not silently no-op'd by name"
tmux new-window -d -t "$SESSION" -n "chk-44" 'sleep 300'
tmux new-window -d -t "$SESSION" -n "chk-44" 'sleep 300'
dup_count_before="$(window_names | tr ' ' '\n' | grep -cx "chk-44" || true)"
check "two chk-44 windows exist before closing (duplicate scenario set up)" "2" "$dup_count_before"
swarm_close_chk_windows "$SESSION" 44
dup_count_after="$(window_names | tr ' ' '\n' | grep -cx "chk-44" || true)"
check "both chk-44 duplicates closed, not just one" "0" "$dup_count_after"

heading "Test 4: a chk-N window for a DIFFERENT issue number is never touched"
tmux new-window -d -t "$SESSION" -n "chk-99" 'sleep 300'
swarm_close_chk_windows "$SESSION" 44
if window_names | tr ' ' '\n' | grep -qx "chk-99"; then got=present; else got=absent; fi
check "chk-99 (unrelated issue) left alone by a close for issue 44" "present" "$got"
tmux kill-window -t "$SESSION:chk-99" 2>/dev/null || true

heading "Test 5: no matching chk-N window is a silent no-op, not an error"
rc=0
swarm_close_chk_windows "$SESSION" 12345 || rc=$?
check "no-match call still returns success" "0" "$rc"

heading "Test 6: no tmux session at all is a silent no-op, not an error"
rc=0
swarm_close_chk_windows "no-such-session-$$" 1 || rc=$?
check "missing-session call still returns success" "0" "$rc"

green "All swarm_close_chk_windows tests passed"
