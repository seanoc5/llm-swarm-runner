#!/usr/bin/env bash
# Shape test for issue #489: swarm-merge.sh must never pass --delete-branch to
# gh pr merge. On gh >= 2.100 that flag's local-delete step runs
# `git worktree remove` on the linked worktree holding the PR branch — the
# live worker's worktree — bypassing kill-worktree.sh's salvage and event
# logging. The remote branch is deleted explicitly after the merge instead.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/swarm-merge.sh"
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }

if grep -vE '^\s*#' "$SCRIPT" | grep -q -- '--delete-branch'; then
    fail "swarm-merge.sh still passes --delete-branch (issue #489: removes the live worker worktree on gh >= 2.100)"
fi
ok "swarm-merge.sh never passes --delete-branch to gh pr merge"

grep -q 'git push origin --delete "\$PR_BRANCH"' "$SCRIPT" \
    || fail "swarm-merge.sh no longer deletes the remote branch after merge"
ok "swarm-merge.sh deletes the remote branch explicitly after merge"

# issue #629 follow-up: the real merge call now also pins to the verified
# commit via "${MATCH_ARGS[@]}" (--match-head-commit); match that addition
# optionally so this still proves the exit is captured (never swallowed),
# without pinning to the exact pre-#629 argument list.
grep -qE 'gh pr merge "\$PR_NUM" --squash( "\$\{MATCH_ARGS\[@\]\}")? \|\| MERGE_RC=\$\?' "$SCRIPT" \
    || fail "a refused gh pr merge must abort the script (issue #492)"
ok "gh pr merge's exit is captured rather than swallowed"
# Every worker merge now goes through worker-merge.sh, and the worker prompts
# no longer warn about the flag, so the script carries the rule.
if grep -vE '^\s*#' "$HERE/../scripts/worker-merge.sh" | grep -q -- '--delete-branch'; then
    fail "worker-merge.sh passes --delete-branch (issue #489: removes the worker's own worktree)"
fi
ok "worker-merge.sh never passes --delete-branch"

# issue #670: GitHub auto-closes (not retargets) a PR whose base branch is
# deleted, so open stacked children must be retargeted BEFORE the delete.
# Order: the call site precedes the remote-branch delete.
call_ln=$(grep -n '^      retarget_stacked_children$' "$SCRIPT" | head -1 | cut -d: -f1)
delete_ln=$(grep -n 'git push origin --delete "\$PR_BRANCH"' "$SCRIPT" | head -1 | cut -d: -f1)
[ -n "$call_ln" ] || fail "swarm-merge.sh no longer calls retarget_stacked_children (issue #670)"
[ "$call_ln" -lt "$delete_ln" ] || fail "child PRs must be retargeted before the head branch is deleted (issue #670)"
ok "retarget_stacked_children runs before the remote branch is deleted"
grep -q 'if \[ "\$KEEP_BRANCH" = 1 \]' "$SCRIPT" || fail "KEEP_BRANCH must gate the remote delete (issue #670)"
ok "KEEP_BRANCH gates the remote delete"

# Behavioral: run the real function against a fake `gh` on PATH.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
# fake gh: logs every call; FAKE_CHILDREN = children of the parent branch;
# FAKE_LIST_FAIL=1 / FAKE_EDIT_FAIL=1 simulate failures.
echo "gh $*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "pr list") [ "${FAKE_LIST_FAIL:-0}" = 1 ] && exit 1
             for c in ${FAKE_CHILDREN:-}; do echo "$c"; done; exit 0 ;;
  "pr edit") [ "${FAKE_EDIT_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"
# Pull just the function out of the script (the script itself isn't sourceable).
sed -n '/^retarget_stacked_children() {/,/^}/p' "$SCRIPT" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || fail "could not extract retarget_stacked_children from swarm-merge.sh"

run_fn() { # env: FAKE_* ; prints output, sets KEEP in $TMP/keep
  FAKE_GH_LOG="$TMP/gh.log"; : > "$FAKE_GH_LOG"; export FAKE_GH_LOG
  PATH="$TMP/bin:$PATH" bash -c '
    c_amber() { printf "%s" "$1"; }
    log_event() { echo "event $*" >> "$FAKE_GH_LOG"; }
    PR_NUM=684 PR_BRANCH=feat/parent PR_BASE=master PR_HEAD_SHA=abc1234
    . "$1"
    retarget_stacked_children
    echo "$KEEP_BRANCH" > "$2"
  ' _ "$TMP/fn.sh" "$TMP/keep"
}

out=$(FAKE_CHILDREN="701" run_fn)
grep -q 'gh pr edit 701 --base master' "$TMP/gh.log" || fail "child #701 was not retargeted to the default branch"
[ "$(cat "$TMP/keep")" = 0 ] || fail "successful retarget must not keep the branch"
grep -q 'result=ok' "$TMP/gh.log" || fail "successful retarget must log merge.retarget ok"
grep -q 'git rebase --onto origin/master abc1234' <<<"$out" || fail "retarget message must tell the child to rebase (issue #670 review): $out"
ok "one stacked child: retargeted to master, branch deletable, rebase command printed"

out=$(FAKE_CHILDREN="" run_fn)
grep -q 'gh pr edit' "$TMP/gh.log" && fail "no children must not call gh pr edit"
[ "$(cat "$TMP/keep")" = 0 ] || fail "no children must leave the branch deletable"
ok "no children: no-op, branch deletable"

out=$(FAKE_CHILDREN="701" FAKE_EDIT_FAIL=1 run_fn)
[ "$(cat "$TMP/keep")" = 1 ] || fail "failed retarget must keep the branch"
ok "failed retarget keeps the branch"

out=$(FAKE_LIST_FAIL=1 run_fn)
[ "$(cat "$TMP/keep")" = 1 ] || fail "failed child lookup must keep the branch"
ok "failed child lookup keeps the branch"
echo "All #489/#670 shape tests passed."
