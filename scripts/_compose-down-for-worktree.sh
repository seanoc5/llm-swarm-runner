#!/usr/bin/env bash
#
# _compose-down-for-worktree.sh — bring down a worktree's docker compose
# stack before the worktree itself is removed.
#
# Worker worktrees sometimes bring up a docker compose stack (e.g. a
# throwaway Postgres for integration tests). If the worktree is deleted
# without tearing the stack down first, the containers survive — orphaned,
# still holding their port bindings — and quietly intercept connections
# from later runs on the same port. See issue #105.
#
# Usage:
#   _compose-down-for-worktree.sh <worktree_path>
#
# Behavior:
#   - No-op (exit 0) if <worktree_path>/docker-compose.yml is absent.
#   - Otherwise runs, bounded to 30s:
#       docker compose -f <worktree_path>/docker-compose.yml \
#           --project-directory <worktree_path> \
#           down --remove-orphans --volumes
#     The project name resolves from --project-directory's basename
#     (e.g. wt-issue-254) unless the worktree's .env sets
#     COMPOSE_PROJECT_NAME — --project-directory picks that up too.
#   - Always exits 0. Compose failures (daemon down, timeout, stack
#     error) are logged as warnings, never fatal — half-cleanup beats no
#     cleanup, and callers must proceed with worktree removal either way.
set -uo pipefail

WT="${1:?usage: _compose-down-for-worktree.sh <worktree_path>}"
COMPOSE_FILE="$WT/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
    exit 0
fi

PROJECT_NAME="$(basename "$WT")"
echo "  compose: found $COMPOSE_FILE (project ~$PROJECT_NAME) — bringing down..."

if timeout 30s docker compose -f "$COMPOSE_FILE" --project-directory "$WT" down --remove-orphans --volumes; then
    echo "  ✓ compose down (project $PROJECT_NAME)"
else
    RC=$?
    echo "  WARN: compose down failed or timed out (exit $RC) for project $PROJECT_NAME — continuing with worktree removal" >&2
fi

exit 0
