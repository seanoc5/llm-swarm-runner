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

# gh stub: `gh pr view <branch> --json state,createdAt,number -q '...'`
# (fetch_pr_state's shape, issue #386) is the only query the script sends;
# it always outputs a tab-separated "state<TAB>createdAt<TAB>number" triple
# regardless of the exact --json/-q args, mirroring real gh -q's raw
# (unquoted) output. fix/issue-42/44/45 have PRs (createdAt set 1h in the
# future so pr_predates_worktree never blocks them against these
# just-created fixture worktrees); anything else has no PR (gh exits 1,
# like the real CLI's "no pull requests found").
GH_LOG="$TEST_DIR/gh.log"
FUTURE_ISO="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    case "\$3" in
        fix/issue-42) printf 'MERGED\t$FUTURE_ISO\t542\n'; exit 0 ;;
        fix/issue-44) printf 'MERGED\t$FUTURE_ISO\t544\n'; exit 0 ;;
        fix/issue-45) printf 'CLOSED\t$FUTURE_ISO\t545\n'; exit 0 ;;
    esac
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
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-44 "$TEST_DIR/wt-issue-44"
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-45 "$TEST_DIR/wt-issue-45"

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
# iss-44/iss-45 (used by Test 4, default-mode parked-OR-merged) are created
# later, AFTER Test 1-3 run --pr-finalized — adding them here would also
# reap them in that earlier pass (--pr-finalized bypasses parked
# entirely) and break Test 3's exact "Closed 1 window(s)" assertion.

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

# ============================================================================
heading "Test 4: default mode reaps a non-parked MERGED PR (issue #386)"
# ============================================================================
# iss-44/iss-45 are fresh tmux windows (plain shell prompt — never parked,
# no "[polling for next brief" marker), simulating the interactive claude
# REPL that never exits on its own. fix/issue-44 has a MERGED PR;
# fix/issue-45 has a CLOSED-without-merge PR.

"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-44
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-45

RUN_LOG2="$TEST_DIR/run2.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG2" 2>&1
RC2=$?
set -e
[ "$RC2" -eq 0 ] || red "expected exit 0, got $RC2. Output:
$(cat "$RUN_LOG2")"

if "$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-44'; then
    red "iss-44 (PR MERGED, never parked) survived default mode — the #386 fix isn't reaping parked-OR-merged. Output:
$(cat "$RUN_LOG2")"
fi
green "iss-44 (MERGED, never parked) reaped by DEFAULT mode with no --merged-only/--pr-finalized flag"

grep -q 'iss-44.*PR-merged.*kill' "$RUN_LOG2" \
    || red "expected iss-44's kill line to cite the PR-merged reason. Output:
$(cat "$RUN_LOG2")"
green "kill line cites PR-merged as the reason (not a bare 'parked')"

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-45' \
    || red "iss-45 (PR CLOSED, not merged) was killed — default mode must NOT reap a closed-without-merge PR"
grep -q 'iss-45.*CLOSED (not merged).*skip.*pr-finalized' "$RUN_LOG2" \
    || red "expected iss-45's skip line to hint at --pr-finalized. Output:
$(cat "$RUN_LOG2")"
green "iss-45 (CLOSED, not merged) preserved, skip line hints at --pr-finalized"

# ============================================================================
heading "Test 5: 'nothing to kill' summary surfaces --pr-finalized when only closed-PR windows remain (issue #386)"
# ============================================================================
# Only iss-43 (unresolvable branch) and iss-45 (CLOSED-without-merge) are
# left — neither is default-mode reap-eligible, so KILL_LIST is empty and
# the summary line must name --pr-finalized instead of the old bare
# "Nothing to kill given current filters."

RUN_LOG3="$TEST_DIR/run3.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG3" 2>&1
RC3=$?
set -e
[ "$RC3" -eq 0 ] || red "expected exit 0, got $RC3. Output:
$(cat "$RUN_LOG3")"

grep -q 'Nothing to kill given current filters\. 1 window(s) have a closed (non-merged) PR — rerun with --pr-finalized to reap them\.' "$RUN_LOG3" \
    || red "expected the enriched 'nothing to kill' summary naming --pr-finalized. Output:
$(cat "$RUN_LOG3")"
green "'nothing to kill' summary correctly points at --pr-finalized instead of staying silent"


# ============================================================================
heading "Test 6: windowless worktrees with finalized PRs are reaped (issue #406)"
# ============================================================================
# By this point iss-42 and iss-44's tmux windows are already gone (Tests 3
# and 4 reaped them WITHOUT --with-worktree), but their worktrees
# (fix/issue-42, fix/issue-44 — both MERGED) still sit on disk untouched —
# exactly the "tmux session restart" scenario issue #406 describes:
# nothing keys off tmux windows here, so a windowless worktree with a
# finalized PR must still be reachable. wt-issue-46 is a fresh worktree
# with NO PR at all (also windowless) that must be left completely alone.

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-42' \
    && red "fixture assumption broken: iss-42 window should already be gone (Test 3)"
"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-44' \
    && red "fixture assumption broken: iss-44 window should already be gone (Test 4)"

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-46 "$TEST_DIR/wt-issue-46"

# Leave an unprocessed brief in windowless wt-issue-44 so the salvage
# acceptance criterion is exercised too, not just removal.
mkdir -p "$TEST_DIR/wt-issue-44/.swarm/tasks/inbox"
echo "queued follow-up" > "$TEST_DIR/wt-issue-44/.swarm/tasks/inbox/20260101-000000-44.md"

RUN_LOG6="$TEST_DIR/run6.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" \
    "$KILL_FINISHED" --pr-finalized --with-worktree --idle-min 0 --yes) > "$RUN_LOG6" 2>&1
RC6=$?
set -e
[ "$RC6" -eq 0 ] || red "expected exit 0, got $RC6. Output:
$(cat "$RUN_LOG6")"
green "script exited 0 scanning windowless worktrees"

grep -q 'iss-42.*no-window,PR-finalized.*kill' "$RUN_LOG6" \
    || red "expected a windowless kill line for iss-42 citing no-window/PR-finalized. Output:
$(cat "$RUN_LOG6")"
green "windowless kill line correctly cites the no-window/PR-finalized reasons"

[ -d "$TEST_DIR/wt-issue-42" ] && red "wt-issue-42 (windowless, MERGED) worktree still present after reap"
git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/fix/issue-42 \
    && red "branch fix/issue-42 still present after reap"
green "wt-issue-42 (windowless, MERGED) worktree + branch removed"

[ -d "$TEST_DIR/wt-issue-44" ] && red "wt-issue-44 (windowless, MERGED) worktree still present after reap"
git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/fix/issue-44 \
    && red "branch fix/issue-44 still present after reap"
green "wt-issue-44 (windowless, MERGED) worktree + branch removed"

SALVAGE_DIR44="$PROJECT_DIR/.swarm/salvaged/iss-44"
[ -f "$SALVAGE_DIR44/inbox/20260101-000000-44.md" ] \
    || red "queued brief in windowless wt-issue-44's inbox was not salvaged before removal"
green "unprocessed brief in windowless wt-issue-44 was salvaged, not destroyed"

[ -d "$TEST_DIR/wt-issue-46" ] \
    || red "wt-issue-46 (windowless, NO PR) worktree was removed — must be untouched"
git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/fix/issue-46 \
    || red "branch fix/issue-46 was deleted — a worktree with no PR must never be reaped"
green "wt-issue-46 (windowless, no PR) left completely untouched"

[ -d "$TEST_DIR/wt-issue-43" ] \
    || red "wt-issue-43 (corrupt registration, still no resolvable branch) worktree was removed"
green "wt-issue-43 (corrupt registration) left untouched"

echo
green "ALL TESTS PASSED"
