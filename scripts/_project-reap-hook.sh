#!/usr/bin/env bash
#
# _project-reap-hook.sh — run a project's own cleanup hook for a worktree that
# is about to be reaped (issue #741).
#
# Why: some projects keep per-worktree state outside the worktree (fand-etl
# creates one Postgres test database per worktree on a tmpfs). Reaping the
# directory leaves that state behind; only the project knows how to drop it,
# and only for THIS worktree (a project-wide "clean everything idle" target
# would also drop live workers' databases).
#
# Usage:
#   _project-reap-hook.sh <worktree_path> <issue> [project_dir]
#
# Hook lookup: $SWARM_REAP_HOOK if set, else <project_dir>/.swarm/reap-hook.sh
# (the main checkout's copy, not the worktree's). Missing or non-executable
# means no hook: exit 0 silently. The hook runs from project_dir, bounded by
# SWARM_REAP_HOOK_TIMEOUT (default 60 s), with
#   $1 = worktree path   $2 = issue number
#   SWARM_REAP_WORKTREE, SWARM_REAP_ISSUE, SWARM_REAP_PROJECT_DIR in its env.
# The worktree still exists when the hook runs, so it can read its .env etc.
# A failing hook is reported on stderr and exits 1; callers treat that as a
# warning and keep reaping (cleanup must never block a reap).
set -uo pipefail

wt="${1:?usage: _project-reap-hook.sh <worktree_path> <issue> [project_dir]}"
issue="${2:?usage: _project-reap-hook.sh <worktree_path> <issue> [project_dir]}"
project_dir="${3:-$PWD}"

hook="${SWARM_REAP_HOOK:-$project_dir/.swarm/reap-hook.sh}"
[ -f "$hook" ] && [ -x "$hook" ] || exit 0

echo "  - running project reap hook: $hook"
(cd "$project_dir" && SWARM_REAP_WORKTREE="$wt" SWARM_REAP_ISSUE="$issue" SWARM_REAP_PROJECT_DIR="$project_dir" \
    timeout --kill-after=10 "${SWARM_REAP_HOOK_TIMEOUT:-60}" "$hook" "$wt" "$issue")
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "  WARN: project reap hook exited $rc (continuing; its per-worktree state may be left behind)" >&2
    exit 1
fi
exit 0
