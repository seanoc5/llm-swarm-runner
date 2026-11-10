#!/usr/bin/env bash
#
# test-shape-provision-cap-discards-worktree.sh — Regression test for issue
# #794: a cap refusal (exit 3) must not leave behind the empty worktree the
# same call just created, because coordinator-watch.sh's idle_capacity skips
# issues that already have a worktree. A worktree that existed beforehand
# must survive the refusal.
set -euo pipefail

red() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
T=$(mktemp -d -t shape-prov-cap-XXXXXX)
trap 'rm -rf "$T"' EXIT

for fn in drop_pending_marker refuse_cap discard_fresh_worktree; do
    body="$(sed -n "/^${fn}() {/,/^}/p" "$PROVISION")"
    [ -n "$body" ] || red "could not extract $fn"
    eval "$body"
done
grep -q '^WT_CREATED_NOW=0' "$PROVISION" || red "WT_CREATED_NOW default missing"
# Creation sites set the flag; the admitted path clears it.
[ "$(grep -c '^ *WT_CREATED_NOW=1' "$PROVISION")" -eq 2 ] || red "expected 2 creation sites setting WT_CREATED_NOW=1"
grep -q '^    WT_CREATED_NOW=0$' "$PROVISION" || red "admitted path does not clear WT_CREATED_NOW"

git init -q "$T/proj" && git -C "$T/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cd "$T/proj"
ISSUE=794; BRANCH="fix/issue-794"; EVENTS_LOG="$T/events.log"; : > "$EVENTS_LOG"
log_event() { shift; echo "$*" >> "$EVENTS_LOG"; }

run_refusal() { ( refuse_cap host_max_workers "cap" "hint" total=15 ) 2>&1 >/dev/null || true; }

# Fresh worktree + flag -> removed along with branch.
WT="$T/wt-issue-794"
git worktree add -q "$WT" -b "$BRANCH"
out="$( WT_CREATED_NOW=1; run_refusal )"
[ ! -e "$WT" ] || red "fresh worktree survived a cap refusal"
git show-ref --verify --quiet "refs/heads/$BRANCH" && red "branch survived"
grep -q 'cap.refused reason=host_max_workers' <<<"$out" || red "reason line missing"
grep -q 'reason=cap_refused' "$EVENTS_LOG" || red "worktree.discarded not logged"
green "fresh worktree discarded on cap refusal"

# Pre-existing worktree (flag 0) -> kept.
git worktree add -q "$WT" -b "$BRANCH"
( WT_CREATED_NOW=0; run_refusal ) >/dev/null
[ -d "$WT" ] || red "pre-existing worktree was removed"
green "pre-existing worktree kept"

# --- #816: every failing exit discards, and never under the cap lock --------
git worktree remove --force "$WT"; git branch -D "$BRANCH" >/dev/null
body="$(sed -n "/^on_exit() {/,/^}/p" "$PROVISION")"
[ -n "$body" ] || red "could not extract on_exit"
eval "$body"
grep -q '^trap on_exit EXIT$' "$PROVISION" || red "on_exit is not registered as the EXIT trap"
[ "$(grep -c "^ *trap .* EXIT" "$PROVISION")" -eq 1 ] || red "a second EXIT trap would clobber on_exit"

# exit 2 (e.g. gh outage) after creation -> worktree and branch gone.
git worktree add -q "$WT" -b "$BRANCH"
( WT_CREATED_NOW=1; trap on_exit EXIT; exit 2 ) >/dev/null 2>&1 || true
[ ! -e "$WT" ] || red "exit 2 left the fresh worktree behind"
git show-ref --verify --quiet "refs/heads/$BRANCH" && red "branch survived exit 2"
grep -q 'reason=exit_2' "$EVENTS_LOG" || red "exit_2 discard not logged"
green "exit 2 after worktree creation leaves no worktree"

# exit 0 and a pre-existing worktree are untouched.
git worktree add -q "$WT" -b "$BRANCH"
( WT_CREATED_NOW=1; trap on_exit EXIT; exit 0 ) >/dev/null 2>&1
[ -d "$WT" ] || red "successful exit removed the worktree"
( WT_CREATED_NOW=0; trap on_exit EXIT; exit 2 ) >/dev/null 2>&1 || true
[ -d "$WT" ] || red "exit 2 removed a pre-existing worktree"
git worktree remove --force "$WT"; git branch -D "$BRANCH" >/dev/null
green "exit 0 and pre-existing worktrees kept"

# The cap lock is released before removal (both paths).
LOCK="$T/cap.lock"
probe_lock() { # run by the git wrapper: can another process take the lock now?
    if flock -n "$LOCK" true; then echo free >> "$T/lockstate"; else echo held >> "$T/lockstate"; fi
}
git() { if [ "$1" = worktree ] && [ "$2" = remove ]; then probe_lock; fi; command git "$@"; }
for path in refuse on_exit; do
    : > "$T/lockstate"
    command git worktree add -q "$WT" -b "$BRANCH"
    (
        exec 9>"$LOCK"; flock 9
        WT_CREATED_NOW=1
        if [ "$path" = refuse ]; then refuse_cap spawn_stagger "m" "" since=1
        else trap on_exit EXIT; exit 2; fi
    ) >/dev/null 2>&1 || true
    [ "$(cat "$T/lockstate")" = "free" ] || red "cap lock held during worktree removal ($path): $(cat "$T/lockstate")"
done
unset -f git
green "cap lock released before the worktree is removed"
