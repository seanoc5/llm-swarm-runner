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

grep -qE 'if ! gh pr merge "\$PR_NUM" --squash; then' "$SCRIPT" \
    || fail "a refused gh pr merge must abort the script (issue #492)"
ok "a refused merge aborts before cleanup"
echo "All #489 shape tests passed."
