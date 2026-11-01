#!/usr/bin/env bash
#
# test-kill-worktree-saved-work.sh — Non-LLM regression test for the
# saved-work (G1) and reap-grace (G2) behavior in kill-worktree.sh.
#
# Before this change, the watcher's autoclose (kill-finished-workers.sh
# --pr-finalized --with-worktree --yes → kill-worktree.sh) printed
# "N commit(s) ahead, M uncommitted change(s)" and then ran
# `git worktree remove --force` + `git branch -D`: unpushed commits and
# uncommitted edits were destroyed. Since 2026-10-18 about 1 reap in 5
# happened mid-task.
#
# Fixtures: a bare "origin", a clone as the project, real git worktrees,
# a gh stub that records PR comments, and a private tmux socket.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
KILL_FINISHED="$SCRIPT_DIR/../scripts/kill-finished-workers.sh"
REAP_ORPHAN="$SCRIPT_DIR/../scripts/reap-orphan-worktrees.sh"
[ -x "$KILL_WT" ] || red "kill-worktree.sh not executable: $KILL_WT"
REAL_TMUX="$(command -v tmux)" || red "tmux not installed"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t kill-wt-saved-XXXXXX)
TEST_SOCK="kwsave-test-$$"
cleanup() {
    "$REAL_TMUX" -L "$TEST_SOCK" kill-server 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCK" "\$@"
EOF
GH_LOG="$TEST_DIR/gh-comments.log"
cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
# PR #42 exists (MERGED) for every branch; comments are recorded.
case "\$1 \$2" in
    "pr view")
        case "\$*" in
            *state,createdAt,number*) printf 'MERGED\t%s\t42\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
            *) echo 42 ;;
        esac ;;
    "pr comment") shift 2; printf '%s\n' "\$*" >> "$GH_LOG" ;;
    "pr list") : ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$SHIM_DIR/tmux" "$SHIM_DIR/gh"
export PATH="$SHIM_DIR:$PATH"
export SWARM_WORKTREE_GROUPING=flat
# Exercise THIS checkout's scripts even when the caller's env points at another.
LLM_SWARM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export LLM_SWARM_DIR

# new_project <name> — bare origin + clone with master pushed.
new_project() {
    local name="$1"
    git init -q --bare "$TEST_DIR/$name-origin.git"
    git clone -q "$TEST_DIR/$name-origin.git" "$TEST_DIR/$name" 2>/dev/null
    git -C "$TEST_DIR/$name" config user.email test@example.com
    git -C "$TEST_DIR/$name" config user.name Test
    git -C "$TEST_DIR/$name" checkout -q -b master
    echo hello > "$TEST_DIR/$name/README.md"
    git -C "$TEST_DIR/$name" add README.md
    git -C "$TEST_DIR/$name" commit -q -m init
    git -C "$TEST_DIR/$name" push -q origin master
    git -C "$TEST_DIR/$name" remote set-head origin master
}

# new_worker <project> <issue> — worktree on fix/issue-N with one commit
# pushed to origin (so "already on the PR" is the baseline).
new_worker() {
    local proj="$TEST_DIR/$1" n="$2" wt="$TEST_DIR/wt-issue-$2"
    git -C "$proj" worktree add -q -b "fix/issue-$n" "$wt" master
    echo "pushed work" > "$wt/pushed-$n.txt"
    git -C "$wt" add "pushed-$n.txt"
    git -C "$wt" commit -q -m "pushed $n"
    git -C "$wt" push -q origin "fix/issue-$n"
    mkdir -p "$wt/.swarm/logs"
    echo log > "$wt/.swarm/logs/worker.log"
}

new_window() {
    local proj="$1" n="$2"
    tmux has-session -t "llm-$proj" 2>/dev/null \
        || tmux new-session -d -s "llm-$proj" -n placeholder
    tmux new-window -d -t "llm-$proj" -n "iss-$n"
}

window_live() { tmux list-windows -t "llm-$1" -F '#W' 2>/dev/null | grep -qx "iss-$2"; }

# run <log> <project> <args...> — runs kill-worktree.sh from the project dir.
run() {
    local log="$1" proj="$2"; shift 2
    set +e
    (cd "$TEST_DIR/$proj" && "$KILL_WT" "$@") > "$log" 2>&1
    RC=$?
    set -e
}

new_project proj

# ============================================================================
heading "Test 1: clean worktree (everything pushed) → removed now, nothing saved"
# ============================================================================
new_worker proj 81
new_window proj 81
run "$TEST_DIR/t1.log" proj 81 --grace
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC: $(cat "$TEST_DIR/t1.log")"
[ ! -d "$TEST_DIR/wt-issue-81" ] || red "clean worktree was not removed"
window_live proj 81 && red "window iss-81 still alive"
ls "$TEST_DIR/proj/.swarm/reaped/"iss-81-*.saved.txt >/dev/null 2>&1 && red "clean worktree must not write a saved-work manifest"
[ ! -e "$TEST_DIR/proj/.swarm/reap-deferred/iss-81" ] || red "clean worktree must not get a grace marker"
grep -q 'SAVED WORK\|reap grace' "$TEST_DIR/t1.log" && red "clean reap printed save/grace output: $(cat "$TEST_DIR/t1.log")"
green "clean worktree removed immediately, no save, no marker"

# ============================================================================
heading "Test 2: unpushed commit + --grace → bundle saved, removal deferred (exit 75)"
# ============================================================================
new_worker proj 82
new_window proj 82
WT2="$TEST_DIR/wt-issue-82"
echo "unpushed" > "$WT2/unpushed.txt"
git -C "$WT2" add unpushed.txt
git -C "$WT2" commit -q -m "unpushed 82"
UNPUSHED_SHA="$(git -C "$WT2" rev-parse HEAD)"
: > "$GH_LOG"
run "$TEST_DIR/t2.log" proj 82 --grace
[ "$RC" -eq 75 ] || red "expected exit 75 (deferred), got $RC: $(cat "$TEST_DIR/t2.log")"
grep -q 'Unsaved work: 1 commit(s) on no remote' "$TEST_DIR/t2.log" || red "expected 1 unsaved commit: $(cat "$TEST_DIR/t2.log")"
BUNDLE="$(ls "$TEST_DIR/proj/.swarm/reaped/"iss-82-*.bundle 2>/dev/null | head -1)"
[ -n "$BUNDLE" ] || red "no bundle written: $(cat "$TEST_DIR/t2.log")"
git -C "$TEST_DIR/proj" bundle verify "$BUNDLE" >/dev/null 2>&1 || red "bundle does not verify"
[ "$(git bundle list-heads "$BUNDLE" | awk '{print $1}')" = "$UNPUSHED_SHA" ] || red "bundle head is not the unpushed commit"
green "bundle holds exactly the unpushed tip and verifies"
[ -d "$WT2" ] || red "worktree removed despite grace"
git -C "$TEST_DIR/proj" show-ref --verify --quiet refs/heads/fix/issue-82 || red "branch deleted despite grace"
window_live proj 82 && red "window iss-82 should be closed even while the worktree is kept"
MARKER="$TEST_DIR/proj/.swarm/reap-deferred/iss-82"
[ -f "$MARKER" ] || red "no grace marker written"
grep -q "^saved=.*$BUNDLE" "$MARKER" || red "marker does not name the bundle: $(cat "$MARKER")"
green "worktree + branch kept, window closed, marker written"
grep -q 'reap.worktree.saved_work.*issue=82 .*commits=1' "$TEST_DIR/proj/.swarm/events.log" || red "no reap.worktree.saved_work event"
grep -q 'reap.worktree.deferred.*issue=82' "$TEST_DIR/proj/.swarm/events.log" || red "no reap.worktree.deferred event"
grep -q 'SWARM_WORK_SAVED' "$GH_LOG" || red "no SWARM_WORK_SAVED PR comment: $(cat "$GH_LOG")"
grep -q "git -C $TEST_DIR/proj fetch $BUNDLE" "$GH_LOG" || red "PR comment lacks the restore command"
green "events logged and PR comment names the bundle + restore command"

run "$TEST_DIR/t2b.log" proj 82
[ "$RC" -eq 75 ] || red "a second call inside the grace must defer again (75), got $RC: $(cat "$TEST_DIR/t2b.log")"
grep -q 'reap grace: unsaved work kept in place until' "$TEST_DIR/t2b.log" || red "expected grace message"
[ -d "$WT2" ] || red "worktree removed inside the grace"
green "a later reap pass (no --grace) inside the grace defers again"

RESTORE="$TEST_DIR/restore-82"
git clone -q "$TEST_DIR/proj-origin.git" "$RESTORE" 2>/dev/null
git -C "$RESTORE" fetch -q "$BUNDLE" refs/heads/fix/issue-82:refs/heads/rescue/issue-82
[ "$(git -C "$RESTORE" rev-parse rescue/issue-82)" = "$UNPUSHED_SHA" ] || red "bundle did not restore the unpushed commit"
green "bundle restores the unpushed commit into a fresh clone"

# ============================================================================
heading "Test 3: reap-orphan-worktrees.sh respects an unexpired marker"
# ============================================================================
set +e
(cd "$TEST_DIR/proj" && "$REAP_ORPHAN" --min-age-days 0 --yes) > "$TEST_DIR/t3.log" 2>&1
set -e
grep -q 'wt-issue-82  \[reap grace for unsaved work until' "$TEST_DIR/t3.log" || red "orphan reaper did not report the grace: $(cat "$TEST_DIR/t3.log")"
[ -d "$WT2" ] || red "orphan reaper removed a worktree inside its grace"
green "orphan reaper skips the worktree during its grace"

# ============================================================================
heading "Test 4: grace expired → orphan reaper removes it; unchanged work is not re-saved"
# ============================================================================
sed -i.bak 's/^until=.*/until=1/' "$MARKER"
: > "$GH_LOG"
BUNDLES_BEFORE="$(ls "$TEST_DIR/proj/.swarm/reaped/"iss-82-*.bundle | wc -l)"
set +e
(cd "$TEST_DIR/proj" && "$REAP_ORPHAN" --min-age-days 0 --yes) > "$TEST_DIR/t4.log" 2>&1
set -e
grep -q 'wt-issue-82  \[reap grace over' "$TEST_DIR/t4.log" || red "orphan reaper did not pick up the expired grace: $(cat "$TEST_DIR/t4.log")"
[ ! -d "$WT2" ] || red "worktree still present after the grace expired: $(cat "$TEST_DIR/t4.log")"
git -C "$TEST_DIR/proj" show-ref --verify --quiet refs/heads/fix/issue-82 && red "branch still present after final removal"
[ ! -e "$MARKER" ] || red "marker not cleaned up after removal"
[ "$(ls "$TEST_DIR/proj/.swarm/reaped/"iss-82-*.bundle | wc -l)" = "$BUNDLES_BEFORE" ] || red "unchanged work was saved a second time"
grep -q 'unchanged since the save at deferral time' "$TEST_DIR/t4.log" || red "expected dedupe message: $(cat "$TEST_DIR/t4.log")"
[ -s "$GH_LOG" ] && red "unchanged work must not be announced on the PR twice"
[ -f "$BUNDLE" ] || red "earlier bundle vanished"
green "expired grace → removed, earlier save reused, no duplicate PR comment"

# ============================================================================
heading "Test 5: dirty worktree (no --grace) → patch + untracked tarball, removed now"
# ============================================================================
new_worker proj 83
WT5="$TEST_DIR/wt-issue-83"
echo "edited" >> "$WT5/README.md"
mkdir -p "$WT5/src"
echo "new file" > "$WT5/src/new.txt"
HEAD5="$(git -C "$WT5" rev-parse HEAD)"
run "$TEST_DIR/t5.log" proj 83
[ "$RC" -eq 0 ] || red "expected exit 0 (no --grace), got $RC: $(cat "$TEST_DIR/t5.log")"
[ ! -d "$WT5" ] || red "worktree not removed"
PATCH="$(ls "$TEST_DIR/proj/.swarm/reaped/"iss-83-*.patch 2>/dev/null | head -1)"
TGZ="$(ls "$TEST_DIR/proj/.swarm/reaped/"iss-83-*.untracked.tgz 2>/dev/null | head -1)"
[ -n "$PATCH" ] || red "no patch saved: $(cat "$TEST_DIR/t5.log")"
[ -n "$TGZ" ] || red "no untracked tarball saved: $(cat "$TEST_DIR/t5.log")"
ls "$TEST_DIR/proj/.swarm/reaped/"iss-83-*.bundle >/dev/null 2>&1 && red "pushed-only branch must not get a bundle"
tar -tzf "$TGZ" | grep -qx 'src/new.txt' || red "tarball lacks src/new.txt"
tar -tzf "$TGZ" | grep -q '^\.swarm' && red "tarball must exclude .swarm/"
grep -q '\.swarm' "$PATCH" && red "patch must exclude .swarm/"
RESTORE5="$TEST_DIR/restore-83"
git -C "$TEST_DIR/proj" worktree add -q --detach "$RESTORE5" "$HEAD5"
git -C "$RESTORE5" apply "$PATCH" || red "patch does not apply on the recorded HEAD"
tar -xzf "$TGZ" -C "$RESTORE5"
grep -q edited "$RESTORE5/README.md" && [ -f "$RESTORE5/src/new.txt" ] || red "restore incomplete"
grep -q "^head=$HEAD5" "$TEST_DIR/proj/.swarm/reaped/"iss-83-*.saved.txt || red "manifest lacks head="
green "patch + tarball saved, exclude .swarm, and restore onto the recorded HEAD"

# ============================================================================
heading "Test 6: SWARM_REAP_GRACE_SECS=0 → removed now even with --grace, still saved"
# ============================================================================
new_worker proj 84
WT6="$TEST_DIR/wt-issue-84"
echo x > "$WT6/x.txt"; git -C "$WT6" add x.txt; git -C "$WT6" commit -q -m "unpushed 84"
set +e
(cd "$TEST_DIR/proj" && SWARM_REAP_GRACE_SECS=0 "$KILL_WT" 84 --grace) > "$TEST_DIR/t6.log" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || red "expected exit 0 with grace disabled, got $RC: $(cat "$TEST_DIR/t6.log")"
[ ! -d "$WT6" ] || red "worktree kept although SWARM_REAP_GRACE_SECS=0"
ls "$TEST_DIR/proj/.swarm/reaped/"iss-84-*.bundle >/dev/null 2>&1 || red "no bundle with grace disabled"
[ ! -e "$TEST_DIR/proj/.swarm/reap-deferred/iss-84" ] || red "marker written with grace disabled"
green "grace 0 → removed immediately, bundle still saved"

# ============================================================================
heading "Test 7: squash-merged branch whose remote ref was deleted → counts as clean"
# ============================================================================
new_worker proj 85
SQ="$TEST_DIR/squash"
git clone -q "$TEST_DIR/proj-origin.git" "$SQ" 2>/dev/null
git -C "$SQ" config user.email t@e; git -C "$SQ" config user.name T
git -C "$SQ" merge -q --squash origin/fix/issue-85 >/dev/null
git -C "$SQ" commit -q -m "squash #85"
echo later > "$SQ/later.txt"; git -C "$SQ" add later.txt; git -C "$SQ" commit -q -m later
git -C "$SQ" push -q origin master
git -C "$TEST_DIR/proj" push -q origin --delete fix/issue-85
run "$TEST_DIR/t7.log" proj 85 --grace
[ "$RC" -eq 0 ] || red "squash-merged worktree should be removed now, got $RC: $(cat "$TEST_DIR/t7.log")"
grep -q 'Unsaved work: 0 commit(s) on no remote (1 more already landed on master)' "$TEST_DIR/t7.log" \
    || red "expected the landed commit to be recognised: $(cat "$TEST_DIR/t7.log")"
ls "$TEST_DIR/proj/.swarm/reaped/"iss-85-*.saved.txt >/dev/null 2>&1 && red "landed work must not be saved"
green "squash-merged + remote branch deleted → not treated as unpushed"

# ============================================================================
heading "Test 8: kill-finished-workers.sh --pr-finalized passes --grace (windowless worktree)"
# ============================================================================
new_worker proj 86
WT8="$TEST_DIR/wt-issue-86"
echo y > "$WT8/y.txt"
set +e
(cd "$TEST_DIR/proj" && "$KILL_FINISHED" --idle-min 0 --pr-finalized --with-worktree --yes) > "$TEST_DIR/t8.log" 2>&1
set -e
grep -q 'reap grace: worktree + branch kept until' "$TEST_DIR/t8.log" || red "autoclose path did not defer: $(cat "$TEST_DIR/t8.log")"
grep -q 'deferred: in-flight check-on-done claim or reap grace' "$TEST_DIR/t8.log" || red "caller did not report the deferral"
[ -d "$WT8" ] || red "autoclose removed a worktree with unsaved work"
ls "$TEST_DIR/proj/.swarm/reaped/"iss-86-*.untracked.tgz >/dev/null 2>&1 || red "autoclose deferral did not save the untracked file"
green "watcher autoclose path saves + defers"

set +e
(cd "$TEST_DIR/proj" && "$KILL_FINISHED" --idle-min 0 --pr-finalized --with-worktree --yes) > "$TEST_DIR/t8b.log" 2>&1
set -e
grep -q 'iss-86  \[no window; reap grace for unsaved work until .* → skip\]' "$TEST_DIR/t8b.log" \
    || red "next autoclose pass should skip the grace worktree: $(cat "$TEST_DIR/t8b.log")"
[ "$(grep -c 'reap.window.*issue=86 ' "$TEST_DIR/proj/.swarm/events.log")" = 1 ] \
    || red "a skipped grace worktree must not log another reap.window"
green "next autoclose pass skips it quietly during the grace"

sed -i.bak 's/^until=.*/until=1/' "$TEST_DIR/proj/.swarm/reap-deferred/iss-86"
set +e
(cd "$TEST_DIR/proj" && "$KILL_FINISHED" --idle-min 0 --pr-finalized --with-worktree --yes) > "$TEST_DIR/t8c.log" 2>&1
set -e
[ ! -d "$WT8" ] || red "autoclose pass after the grace did not remove the worktree: $(cat "$TEST_DIR/t8c.log")"
[ ! -e "$TEST_DIR/proj/.swarm/reap-deferred/iss-86" ] || red "marker left behind"
green "autoclose pass after the grace removes it"

echo
green "ALL TESTS PASSED"
