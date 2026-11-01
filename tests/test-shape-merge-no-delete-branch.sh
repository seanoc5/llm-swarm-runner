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
retarget_ln=$(grep -n 'gh pr edit "\$CHILD" --base "\$PR_BASE"' "$SCRIPT" | head -1 | cut -d: -f1)
delete_ln=$(grep -n 'git push origin --delete "\$PR_BRANCH"' "$SCRIPT" | head -1 | cut -d: -f1)
[ -n "$retarget_ln" ] || fail "swarm-merge.sh no longer retargets stacked child PRs (issue #670)"
[ "$retarget_ln" -lt "$delete_ln" ] || fail "child PRs must be retargeted before the head branch is deleted (issue #670)"
ok "stacked child PRs are retargeted before the remote branch is deleted"
grep -q 'KEEP_BRANCH=1' "$SCRIPT" || fail "a failed retarget must keep the branch (issue #670)"
ok "a failed retarget keeps the remote branch"
grep -q 'if ! CHILD_PRS=\$(gh pr list' "$SCRIPT" || fail "a failed child-PR lookup must keep the branch too (issue #670 self-review)"
ok "a failed child-PR lookup keeps the remote branch"
echo "All #489/#670 shape tests passed."
