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
#   - Discovers the compose file the way `docker compose` itself does,
#     then falls back to any docker-compose*.y*ml / compose*.y*ml in the
#     worktree root. The previous version hardcoded `docker-compose.yml`
#     and silently exit-0'd for every other name, which leaked 51 GB of
#     named volumes across projects using `docker-compose.yaml`,
#     `docker-compose.test.yml` and `compose.yaml` (2026-08-17, issue #303).
#   - Runs, bounded to 60s:
#       docker compose -f <file> --project-directory <wt> \
#           down --remove-orphans --volumes
#   - Then sweeps by compose LABEL for anything the file-based teardown
#     missed: containers and volumes tagged
#     com.docker.compose.project=<project>. This is the belt-and-braces
#     path — it works even when the compose file is unreadable, the
#     timeout fires, or the stack was started from a file that has since
#     been deleted along with the worktree. Removing by that label can
#     only ever touch objects belonging to this worktree's project, so
#     it is safe to run unconditionally.
#   - Always exits 0. Compose failures (daemon down, timeout, stack
#     error) are logged as warnings, never fatal — half-cleanup beats no
#     cleanup, and callers must proceed with worktree removal either way.
set -uo pipefail

WT="${1:?usage: _compose-down-for-worktree.sh <worktree_path>}"

# Compose's own file-discovery precedence, then anything else that looks
# like a compose file. `-f` accepts only one primary here; projects that
# split across override files still get caught by the label sweep below.
find_compose_file() {
    local f
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        [ -f "$WT/$f" ] && { printf '%s\n' "$WT/$f"; return 0; }
    done
    # Non-standard names, e.g. fand-etl's docker-compose.test.yml.
    f=$(find "$WT" -maxdepth 1 \( -name 'docker-compose*.y*ml' -o -name 'compose*.y*ml' \) 2>/dev/null | sort | head -1)
    [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
    return 1
}

# COMPOSE_PROJECT_NAME in the worktree's .env wins, matching what compose
# itself would use when the stack came up — otherwise the label sweep
# would look for the wrong project and find nothing.
PROJECT_NAME="$(basename "$WT")"
if [ -f "$WT/.env" ]; then
    _p=$(grep -sE '^[[:space:]]*COMPOSE_PROJECT_NAME=' "$WT/.env" | tail -1 | cut -d= -f2- | tr -d '"'\'' ')
    [ -n "${_p:-}" ] && PROJECT_NAME="$_p"
fi

if COMPOSE_FILE="$(find_compose_file)"; then
    echo "  compose: found $COMPOSE_FILE (project $PROJECT_NAME) — bringing down..."
    if timeout 60s docker compose -f "$COMPOSE_FILE" --project-directory "$WT" \
            down --remove-orphans --volumes; then
        echo "  ✓ compose down (project $PROJECT_NAME)"
    else
        RC=$?
        echo "  WARN: compose down failed or timed out (exit $RC) for project $PROJECT_NAME — falling back to label sweep" >&2
    fi
else
    echo "  compose: no compose file in $WT — checking for a labelled stack anyway (project $PROJECT_NAME)"
fi

# --- Label sweep -----------------------------------------------------------
# Everything compose creates carries com.docker.compose.project. Removing
# by that label can only ever touch objects belonging to THIS worktree's
# project, so it is safe to run unconditionally — including when the
# file-based teardown above already succeeded (it then finds nothing).
_filter="label=com.docker.compose.project=$PROJECT_NAME"

_containers=$(docker ps -aq --filter "$_filter" 2>/dev/null)
if [ -n "$_containers" ]; then
    echo "  sweep: removing $(printf '%s\n' "$_containers" | wc -l) leftover container(s) for project $PROJECT_NAME"
    # shellcheck disable=SC2086
    docker rm -f -v $_containers >/dev/null 2>&1 || echo "  WARN: container sweep incomplete" >&2
fi

_volumes=$(docker volume ls -q --filter "$_filter" 2>/dev/null)
if [ -n "$_volumes" ]; then
    echo "  sweep: removing $(printf '%s\n' "$_volumes" | wc -l) leftover volume(s) for project $PROJECT_NAME"
    # shellcheck disable=SC2086
    docker volume rm -f $_volumes >/dev/null 2>&1 || echo "  WARN: volume sweep incomplete" >&2
fi

exit 0
