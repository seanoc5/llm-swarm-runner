#!/usr/bin/env bash
#
# test-shape-provision-existing-pr-branch.sh — Regression test for issue #818:
# re-provisioning an issue whose worktree was reaped while its PR is open must
# base the worktree on origin/fix/issue-N, not the default branch (a push from
# the default-branch base would diverge from / replace the open PR).
# The worktree-creation block is extracted from provision-worker.sh with sed.
set -euo pipefail

red() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
TEST_DIR=$(mktemp -d -t shape-provision-pr-branch-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

body="$(sed -n '/^BASE_REF="\$DEFAULT_REMOTE_REF"/,/^# Gitignored files/p' "$PROVISION" | sed '$d')"
echo "$body" | grep -q 'worktree add' || red "could not extract the worktree block from $PROVISION"

cd "$TEST_DIR"
git init -q --bare origin.git
git init -q -b master seed && cd seed
git config user.email t@t; git config user.name t
git commit -q --allow-empty -m base
git remote add origin ../origin.git && git push -q origin master
git checkout -q -b fix/issue-7 && git commit -q --allow-empty -m pr-work && git push -q origin fix/issue-7
PR_SHA="$(git rev-parse HEAD)"
git checkout -q master && git commit -q --allow-empty -m master-moves && git push -q origin master
git branch -D fix/issue-7 -q

provision() {  # $1 = clone dir
    ( cd "$1"; ISSUE=7; BRANCH="fix/issue-7"; WT="$TEST_DIR/wt-$(basename "$1")"
      DEFAULT_REMOTE_REF=origin/master; WT_CREATED_NOW=0
      log_event() { :; }
      eval "$body" >/dev/null
      git -C "$WT" rev-parse HEAD )
}

cd "$TEST_DIR"
git clone -q origin.git c1; git -C c1 config user.email t@t; git -C c1 config user.name t
got="$(provision "$TEST_DIR/c1")"
[ "$got" = "$PR_SHA" ] || red "no local branch: worktree on $got, expected PR head $PR_SHA"
[ "$(git -C c1 rev-parse --abbrev-ref fix/issue-7@{upstream})" = "origin/fix/issue-7" ] || red "upstream not origin/fix/issue-7"
green "no local branch: based on origin/fix/issue-7 with upstream"

git clone -q origin.git c2
git -C c2 branch fix/issue-7 "$PR_SHA~1"   # stale local branch, nothing unique
got="$(provision "$TEST_DIR/c2")"
[ "$got" = "$PR_SHA" ] || red "stale local branch: worktree on $got, expected $PR_SHA"
green "stale local branch fast-forwarded to origin/fix/issue-7"

git clone -q origin.git c3
git -C c3 branch fix/issue-7 origin/fix/issue-7 && git -C c3 config user.email t@t && git -C c3 config user.name t
git -C c3 update-ref refs/heads/fix/issue-7 "$(git -C c3 commit-tree -p "$PR_SHA" -m local "$PR_SHA^{tree}")"
if provision "$TEST_DIR/c3" 2>/dev/null; then red "local-only commits were silently discarded"; fi
green "local-only commits still refused"

# Merged PR whose remote branch was deleted: cached origin/fix/issue-7 lingers
# (fetch without --prune). Must base on master, not the old branch.
git clone -q origin.git c4
git --git-dir=origin.git branch -q -D fix/issue-7   # remote branch gone; c4 cached ref stays
git -C c4 config user.email t@t; git -C c4 config user.name t
git -C c4 show-ref --verify -q refs/remotes/origin/fix/issue-7 || red "test setup: cached ref missing"
got="$(provision "$TEST_DIR/c4")"
[ "$got" = "$(git -C c4 rev-parse origin/master)" ] || red "deleted remote branch: worktree on $got, expected origin/master"
green "deleted remote branch (stale cached ref) ignored; based on master"

# Unreachable remote (#840): ls-remote fails, so "empty output" must not read as
# "branch deleted". Keep the cached origin/fix/issue-7 and warn on stderr.
# Re-create the remote branch at the PR commit, then stub only ls-remote to fail.
git --git-dir=origin.git update-ref refs/heads/fix/issue-7 "$PR_SHA"
git clone -q origin.git c5; git -C c5 config user.email t@t; git -C c5 config user.name t
got="$( cd c5; ISSUE=7; BRANCH="fix/issue-7"; WT="$TEST_DIR/wt-c5"
        DEFAULT_REMOTE_REF=origin/master; WT_CREATED_NOW=0
        log_event() { :; }
        git() { if [ "${1:-}" = ls-remote ]; then return 128; fi; command git "$@"; }
        eval "$body" >/dev/null 2>"$TEST_DIR/c5.err"
        git -C "$WT" rev-parse HEAD )"
[ "$got" = "$PR_SHA" ] || red "ls-remote failure: worktree on $got, expected cached origin/fix/issue-7 ($PR_SHA)"
grep -q 'WARN: git ls-remote failed' "$TEST_DIR/c5.err" || red "ls-remote failure: no WARN on stderr"
green "failing ls-remote keeps cached origin/fix/issue-7 and warns"
