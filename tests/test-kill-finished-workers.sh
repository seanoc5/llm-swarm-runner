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

# issue #466 self-review: the issue-closed reap path enforces its own
# REAP_ISSUE_CLOSED_MIN_IDLE_MIN-minute idle floor regardless of --idle-min.
# Every tmux window this suite creates is brand new (idle 0m), so default
# to 0 here for the whole file; Test 14 overrides it per-invocation to
# exercise the real (nonzero) default directly.
export REAP_ISSUE_CLOSED_MIN_IDLE_MIN=0

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
# (fetch_pr_state's shape, issue #386) is the only PR query the script
# sends; it always outputs a tab-separated "state<TAB>createdAt<TAB>number"
# triple regardless of the exact --json/-q args, mirroring real gh -q's raw
# (unquoted) output. fix/issue-42/44/45 have PRs (createdAt set 1h in the
# future so pr_predates_worktree never blocks them against these
# just-created fixture worktrees); anything else has no PR (gh exits 1,
# like the real CLI's "no pull requests found").
#
# `gh issue view <N> --json state -q .state` (fetch_issue_state's shape,
# issue #466) outputs the raw state string, like real gh -q. Issue 47
# (clean+pushed no-PR task) and 48 (dirty no-PR task) are CLOSED; issue 49
# (still-open no-PR task) is OPEN; anything else has no issue at all.
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
        fix/issue-52) printf 'CLOSED\t$FUTURE_ISO\t552\n'; exit 0 ;;
    esac
    # real gh's exact message on a branch with no PR at all — fetch_pr_state
    # (issue #466 self-review) keys off this text to tell "confirmed no PR"
    # apart from a lookup failure, so the stub must say it verbatim.
    echo "no pull requests found for branch \"\$3\"" >&2
    exit 1
fi
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
    case "\$3" in
        47) echo CLOSED; exit 0 ;;
        48) echo CLOSED; exit 0 ;;
        49) echo OPEN; exit 0 ;;
    esac
    exit 1
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

# A real "origin" (bare repo) so issue #466's clean-worktree guard has an
# actual upstream to compare against — @{upstream} / `git rev-list
# upstream..HEAD` need a real remote-tracking ref, not something the gh
# stub can fake.
ORIGIN_DIR="$TEST_DIR/origin.git"
git init -q --bare "$ORIGIN_DIR"
git -C "$PROJECT_DIR" remote add origin "$ORIGIN_DIR"
DEFAULT_BRANCH="$(git -C "$PROJECT_DIR" symbolic-ref --short HEAD)"
git -C "$PROJECT_DIR" push -q origin "$DEFAULT_BRANCH"

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

# ============================================================================
heading "Test 7: no-PR task reaped once its GitHub issue closes (issue #466)"
# ============================================================================
# iss-47 never had a PR at all (gh stub has no fix/issue-47 case → 'no PR
# found'). It's a live window that never parks (plain shell, no listener
# marker) and never gets a merged PR — exactly the carve/ruling/research
# shape #466 describes. Issue 47 is CLOSED and the worktree is clean and
# fully pushed, so default mode must still reap it.

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-47 "$TEST_DIR/wt-issue-47"
git -C "$TEST_DIR/wt-issue-47" push -q -u origin fix/issue-47
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-47

RUN_LOG7="$TEST_DIR/run7.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG7" 2>&1
RC7=$?
set -e
[ "$RC7" -eq 0 ] || red "expected exit 0, got $RC7. Output:
$(cat "$RUN_LOG7")"

if "$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-47'; then
    red "iss-47 (no PR, issue CLOSED, clean+pushed) survived default mode. Output:
$(cat "$RUN_LOG7")"
fi
green "iss-47 (no PR, issue CLOSED, clean+pushed) reaped by DEFAULT mode"

grep -q 'iss-47.*issue-closed.*kill' "$RUN_LOG7" \
    || red "expected iss-47's kill line to cite the issue-closed reason. Output:
$(cat "$RUN_LOG7")"
green "kill line cites issue-closed as the reason"

# ============================================================================
heading "Test 8: clean-worktree guard blocks reap — uncommitted changes (issue #466)"
# ============================================================================
# iss-48: same no-PR, issue-CLOSED shape as iss-47, but the worktree has an
# untracked file. The clean-worktree guard must block the reap even though
# every other condition is satisfied.

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-48 "$TEST_DIR/wt-issue-48"
echo "still working" > "$TEST_DIR/wt-issue-48/scratch.txt"
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-48

RUN_LOG8="$TEST_DIR/run8.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG8" 2>&1
RC8=$?
set -e
[ "$RC8" -eq 0 ] || red "expected exit 0, got $RC8. Output:
$(cat "$RUN_LOG8")"

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-48' \
    || red "iss-48 (issue CLOSED, but DIRTY worktree) was killed — clean-worktree guard must block this"
grep -q 'iss-48.*uncommitted/untracked changes.*skip' "$RUN_LOG8" \
    || red "expected iss-48's skip line to cite uncommitted/untracked changes. Output:
$(cat "$RUN_LOG8")"
green "iss-48 (issue CLOSED, dirty worktree) preserved — clean-worktree guard held"

# ============================================================================
heading "Test 9: clean-worktree guard blocks reap — unpushed commit (issue #466)"
# ============================================================================
# iss-51: tree is clean (the local commit IS committed), but it's ahead of
# its own pushed upstream by one commit. Closing the issue is not proof
# that commit reached anywhere outside this worktree.

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-51 "$TEST_DIR/wt-issue-51"
git -C "$TEST_DIR/wt-issue-51" push -q -u origin fix/issue-51
echo "local-only change" >> "$TEST_DIR/wt-issue-51/README.md"
git -C "$TEST_DIR/wt-issue-51" commit -q -am "local-only commit"
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-51
# gh stub has no issue-51 case; extend it in place so this one scenario
# doesn't need its own shim rebuild.
sed -i "s/49) echo OPEN; exit 0 ;;/49) echo OPEN; exit 0 ;;\n        51) echo CLOSED; exit 0 ;;/" "$SHIM_DIR/gh"

RUN_LOG9="$TEST_DIR/run9.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG9" 2>&1
RC9=$?
set -e
[ "$RC9" -eq 0 ] || red "expected exit 0, got $RC9. Output:
$(cat "$RUN_LOG9")"

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-51' \
    || red "iss-51 (issue CLOSED, 1 unpushed commit) was killed — clean-worktree guard must block this"
grep -q 'iss-51.*unpushed commit.*skip' "$RUN_LOG9" \
    || red "expected iss-51's skip line to cite an unpushed commit. Output:
$(cat "$RUN_LOG9")"
green "iss-51 (issue CLOSED, 1 unpushed commit) preserved — clean-worktree guard held"

# ============================================================================
heading "Test 10: an OPEN issue leaves a no-PR task alone (issue #466)"
# ============================================================================

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-49 "$TEST_DIR/wt-issue-49"
git -C "$TEST_DIR/wt-issue-49" push -q -u origin fix/issue-49
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-49

RUN_LOG10="$TEST_DIR/run10.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG10" 2>&1
RC10=$?
set -e
[ "$RC10" -eq 0 ] || red "expected exit 0, got $RC10. Output:
$(cat "$RUN_LOG10")"

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-49' \
    || red "iss-49 (no PR, issue still OPEN) was killed — must never reap while the issue is open"
green "iss-49 (no PR, issue OPEN) preserved"

# ============================================================================
heading "Test 11: --merged-only mode also reaps a no-PR task via the issue-closed fallback (issue #466)"
# ============================================================================
# Before #466, --merged-only/--pr-finalized ONLY ever looked at PR state, so
# a no-PR task was permanently unreachable under the pr-gated modes the
# watcher actually runs (cleanup_eligible_workers always passes
# --merged-only or --pr-finalized, never bare default mode). iss-50 proves
# the fallback now fires there too — even under --merged-only, the
# STRICTEST mode. iss-52 (a FRESH branch with its own CLOSED-without-merge
# PR — iss-45 doesn't survive this far: Test 6's own --pr-finalized pass
# already reaped it as PR-finalized, independent of #466) rides along in
# the same run to prove a branch that DOES have a PR is still judged solely
# on that PR's state, never the issue's: --merged-only's own "not MERGED"
# rejection must still hold for it.

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-50 "$TEST_DIR/wt-issue-50"
git -C "$TEST_DIR/wt-issue-50" push -q -u origin fix/issue-50
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-50
sed -i "s/49) echo OPEN; exit 0 ;;/49) echo OPEN; exit 0 ;;\n        50) echo CLOSED; exit 0 ;;/" "$SHIM_DIR/gh"

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-52 "$TEST_DIR/wt-issue-52"
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-52

RUN_LOG11="$TEST_DIR/run11.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --merged-only --idle-min 0) > "$RUN_LOG11" 2>&1
RC11=$?
set -e
[ "$RC11" -eq 0 ] || red "expected exit 0, got $RC11. Output:
$(cat "$RUN_LOG11")"

if "$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-50'; then
    red "iss-50 (no PR, issue CLOSED, clean+pushed) survived --merged-only mode. Output:
$(cat "$RUN_LOG11")"
fi
grep -q 'iss-50.*issue-closed.*kill' "$RUN_LOG11" \
    || red "expected iss-50's kill line to cite issue-closed under --merged-only. Output:
$(cat "$RUN_LOG11")"
green "iss-50 (no PR, issue CLOSED, clean+pushed) reaped by --merged-only mode"

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-52' \
    || red "iss-52 (HAS a PR, CLOSED-without-merge) was reaped by the issue-closed fallback under --merged-only — a branch with a PR must be judged on the PR alone"
grep -q 'iss-52.*not MERGED.*skip.*merged-only' "$RUN_LOG11" \
    || red "expected iss-52's skip line to cite 'not MERGED' under --merged-only. Output:
$(cat "$RUN_LOG11")"
green "iss-52 (PR CLOSED-without-merge) still untouched under --merged-only — issue-closed fallback never applies to a branch that has a PR"

# ============================================================================
heading "Test 12: a failed PR lookup is never read as 'confirmed no PR' (issue #466 self-review)"
# ============================================================================
# fetch_pr_state's self-review fix: a transient `gh pr view` failure (network,
# auth, rate-limit — anything other than gh's own "no pull requests found")
# must set PR_LOOKUP_FAILED and must NOT unlock the issue-closed fallback,
# even though PR_STATE is empty in both cases. Without the guard, a branch
# with a real OPEN PR that gh simply failed to fetch this round could be
# reaped the moment its issue closes. fix/issue-53's stub exits 1 with an
# unrelated error message (not "no pull requests found") to simulate that.

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-53 "$TEST_DIR/wt-issue-53"
git -C "$TEST_DIR/wt-issue-53" push -q -u origin fix/issue-53
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-53
sed -i "s/50) echo CLOSED; exit 0 ;;/50) echo CLOSED; exit 0 ;;\n        53) echo CLOSED; exit 0 ;;/" "$SHIM_DIR/gh"
sed -i "s#552\\\\n'; exit 0 ;;#552\\\\n'; exit 0 ;;\n        fix/issue-53) echo \"error: GraphQL: something went wrong (rate limited)\" >\&2; exit 1 ;;#" "$SHIM_DIR/gh"

RUN_LOG12="$TEST_DIR/run12.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG12" 2>&1
RC12=$?
set -e
[ "$RC12" -eq 0 ] || red "expected exit 0, got $RC12. Output:
$(cat "$RUN_LOG12")"

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-53' \
    || red "iss-53 (PR lookup failed, issue CLOSED) was reaped — a failed lookup must never be treated as 'confirmed no PR'. Output:
$(cat "$RUN_LOG12")"
grep -q 'iss-53.*lookup failed' "$RUN_LOG12" \
    || red "expected iss-53's skip line to cite the failed lookup, not the issue-closed fallback. Output:
$(cat "$RUN_LOG12")"
green "iss-53 (PR lookup failed, issue CLOSED) preserved — PR_LOOKUP_FAILED guard held"

# ============================================================================
heading "Test 13: worktree_safe_to_reap on a real provision-worker.sh-shaped branch (issue #466 self-review)"
# ============================================================================
# Tests 7-12 all push with `-u origin <own-branch-name>`, which gives the
# branch an upstream of its own name. A real worker branch never does that:
# provision-worker.sh creates it as `git worktree add -b BRANCH
# $DEFAULT_REMOTE_REF` (scripts/provision-worker.sh:351), which makes git set
# its upstream to the DEFAULT branch's remote-tracking ref, not to a
# same-named remote branch that may not even exist yet. For the common no-PR
# case — no commits made at all, task delivered as an issue comment —
# worktree_safe_to_reap must still read that as "0 ahead of upstream, safe",
# even though upstream here is origin/<default>, not origin/fix/issue-54.

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-54 "$TEST_DIR/wt-issue-54" "origin/$DEFAULT_BRANCH"
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-54
sed -i "s/53) echo CLOSED; exit 0 ;;/53) echo CLOSED; exit 0 ;;\n        54) echo CLOSED; exit 0 ;;/" "$SHIM_DIR/gh"

git -C "$TEST_DIR/wt-issue-54" rev-parse --symbolic-full-name '@{upstream}' | grep -qx "refs/remotes/origin/$DEFAULT_BRANCH" \
    || red "fixture bug: fix/issue-54's upstream isn't origin/$DEFAULT_BRANCH as provision-worker.sh's shape requires"

RUN_LOG13="$TEST_DIR/run13.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG13" 2>&1
RC13=$?
set -e
[ "$RC13" -eq 0 ] || red "expected exit 0, got $RC13. Output:
$(cat "$RUN_LOG13")"

if "$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-54'; then
    red "iss-54 (no-commit no-PR task, provision-worker.sh-shaped upstream) survived default mode. Output:
$(cat "$RUN_LOG13")"
fi
grep -q 'iss-54.*issue-closed.*kill' "$RUN_LOG13" \
    || red "expected iss-54's kill line to cite issue-closed. Output:
$(cat "$RUN_LOG13")"
green "iss-54 (no commits, upstream = origin/$DEFAULT_BRANCH per provision-worker.sh's own shape) reaped by DEFAULT mode"

# ============================================================================
heading "Test 14: the issue-closed idle floor holds even with --idle-min 0 (issue #466 self-review)"
# ============================================================================
# The watcher's real auto-reap pass always calls this script with
# --idle-min 0 (coordinator-watch.sh's cleanup_eligible_workers), so that
# CLI flag can never be trusted as the safety net for the issue-closed
# fallback — it would let a still-running worker's window (and worktree) be
# destroyed the instant its issue closes, for any reason, not just the
# coordinator's planned close. REAP_ISSUE_CLOSED_MIN_IDLE_MIN enforces its
# own floor regardless. This is the one test in the file that does NOT
# override it to 0, to prove the real (nonzero) default actually holds.

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-55 "$TEST_DIR/wt-issue-55"
git -C "$TEST_DIR/wt-issue-55" push -q -u origin fix/issue-55
"$SHIM_DIR/tmux" new-window -t "$SESSION" -n iss-55
sed -i "s/54) echo CLOSED; exit 0 ;;/54) echo CLOSED; exit 0 ;;\n        55) echo CLOSED; exit 0 ;;/" "$SHIM_DIR/gh"

RUN_LOG14="$TEST_DIR/run14.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" env -u REAP_ISSUE_CLOSED_MIN_IDLE_MIN \
    "$KILL_FINISHED" --idle-min 0) > "$RUN_LOG14" 2>&1
RC14=$?
set -e
[ "$RC14" -eq 0 ] || red "expected exit 0, got $RC14. Output:
$(cat "$RUN_LOG14")"

"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-55' \
    || red "iss-55 (no PR, issue CLOSED, clean+pushed, but freshly active — idle 0m) was reaped despite --idle-min 0 giving it no cover — the issue-closed floor must hold on its own. Output:
$(cat "$RUN_LOG14")"
grep -q 'iss-55.*floor.*actively running' "$RUN_LOG14" \
    || red "expected iss-55's skip line to cite the issue-closed idle floor. Output:
$(cat "$RUN_LOG14")"
green "iss-55 (idle 0m, real default floor, --idle-min 0) preserved — issue-closed floor isn't defeated by the CLI flag"

echo
green "ALL TESTS PASSED"
