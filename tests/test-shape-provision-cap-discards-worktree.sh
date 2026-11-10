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
