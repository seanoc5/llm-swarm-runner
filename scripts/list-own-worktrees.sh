#!/usr/bin/env bash
#
# list-own-worktrees.sh — print this project's OWN worker worktree
# directories, one per line.
#
# issue #357: coordinator triage/monitoring commands (prompts/coordinator.md,
# coordinator-watch.sh's wake prompts) used to glob "$WORKSPACE/wt-issue-*"
# directly. Under SWARM_WORKTREE_GROUPING=flat (the historical default),
# $WORKSPACE is the project's PARENT directory — shared with any sibling
# repo checked out alongside it (e.g. /opt/work/ holding both this project's
# worktrees and an unrelated sysadmin swarm's). A same-named wt-issue-N
# belonging to a different project's repo then silently matches, and issue
# numbers carry no project identity to catch the mixup.
#
# This is a thin CLI wrapper around _load-env.sh's swarm_own_worktree_dirs(),
# which is the actual source of truth: `git worktree list` run against THIS
# project's own repo, the authoritative registry of every worktree git
# actually created for it, regardless of directory naming or
# SWARM_WORKTREE_GROUPING layout. A foreign directory that merely happens to
# be named wt-issue-N can never appear, because it was never `git worktree
# add`-ed against this repo.
#
# Usage:
#   list-own-worktrees.sh [--all] [project-dir]     # default project-dir: $PWD
#
# Output: one absolute worktree path per line, excluding the project's own
# main worktree, restricted to the wt-issue-<N> naming convention this
# project's tooling creates (provision-worker.sh / swarm_worktree_dir).
#
# FLAGS
#   --all       Include non-numbered worktrees too (rare: a manual
#               `git worktree add` outside the swarm tooling).
#   -h, --help  Show this help and exit
#
# EXAMPLES
#   list-own-worktrees.sh
#   for wt in $(list-own-worktrees.sh); do cat "$wt"/.swarm/tasks/done/*.json 2>/dev/null; done
#   ls "$(list-own-worktrees.sh | sed 's|$|/.swarm/tasks/outbox/*.md|')" 2>/dev/null
set -euo pipefail

MODE=""
PROJECT_DIR="$PWD"
for a in "$@"; do
    case "$a" in
        --all) MODE="all" ;;
        -h|--help)
            sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) echo "ERROR: unknown flag: $a (try --help)" >&2; exit 1 ;;
        *) PROJECT_DIR="$a" ;;
    esac
done

PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || {
    echo "ERROR: project dir not accessible: $PROJECT_DIR" >&2
    exit 1
}
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "ERROR: not a git repository: $PROJECT_DIR" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

swarm_own_worktree_dirs "$PROJECT_DIR" "$MODE"
