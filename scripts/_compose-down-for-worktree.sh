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
#   - Resolves the project name the same way `docker compose` resolves it:
#     .env's COMPOSE_PROJECT_NAME, else the compose file's top-level
#     `name:`, else the worktree's basename — so the label sweep below
#     looks for what compose actually stamped, not a guess.
#   - Runs, bounded to 60s:
#       docker compose -f <file> --project-directory <wt> \
#           down --remove-orphans --volumes
#   - Then sweeps by compose LABEL for anything the file-based teardown
#     missed: containers, volumes and networks tagged
#     com.docker.compose.project=<project> (project name normalized the
#     same way compose itself does: lowercased, invalid chars deleted,
#     leading '_'/'-' trimmed). This is the belt-and-braces path — it
#     works even when the compose file is unreadable, the down times
#     out, or the stack was started from a file that has since been
#     deleted along with the worktree. Removing by that label can only
#     ever touch objects belonging to this worktree's project, so it is
#     safe to run unconditionally. Each sweep call is independently
#     bounded (20s) — a wedged daemon must not hang teardown forever any
#     more than a wedged `compose down` should (see its own 60s bound).
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

COMPOSE_FILE="$(find_compose_file)" || COMPOSE_FILE=""

# Project name, in the same precedence order `docker compose` itself
# resolves it (highest wins): a COMPOSE_PROJECT_NAME already exported in
# this script's own environment, else the worktree's .env, else a
# top-level `name:` in the compose file, else the worktree's basename.
# Getting this wrong means the label sweep looks for the wrong project
# and silently finds nothing.
PROJECT_NAME="$(basename "$WT")"
if [ -n "$COMPOSE_FILE" ]; then
    # Simple flat `name: foo` line — good enough for the common case;
    # anchors/multi-doc YAML fall through to the basename default rather
    # than risk mis-parsing. Strip a trailing YAML comment (unlike .env,
    # YAML genuinely supports `name: foo # comment` — without this, the
    # comment text gets glued onto the name after normalization).
    _n=$(grep -E '^name:[[:space:]]*' "$COMPOSE_FILE" 2>/dev/null | head -1 | cut -d: -f2- | sed -E 's/#.*//' | tr -d '"'\'' ')
    [ -n "${_n:-}" ] && PROJECT_NAME="$_n"
fi
if [ -f "$WT/.env" ]; then
    _p=$(grep -sE '^[[:space:]]*COMPOSE_PROJECT_NAME=' "$WT/.env" | tail -1 | cut -d= -f2- | tr -d '"'\'' ')
    [ -n "${_p:-}" ] && PROJECT_NAME="$_p"
fi
# An actually-exported COMPOSE_PROJECT_NAME outranks even .env — it's
# what `docker compose down` itself would honor first, since it inherits
# this script's environment. No caller in this codebase sets it, but
# nothing stops an external one from doing so.
[ -n "${COMPOSE_PROJECT_NAME:-}" ] && PROJECT_NAME="$COMPOSE_PROJECT_NAME"
# `docker compose` normalizes whatever name it's given the same way it
# normalizes a directory-basename-derived default: lowercase, DELETE (not
# replace) any character outside [a-z0-9_-], then trim leading '_'/'-'
# (compose-go's NormalizeProjectName; verified against the real binary —
# `wt-Upper.Name` -> `wt-uppername`, not `wt-upper_name`). Match that here,
# or an uppercase/punctuated worktree, `name:`, or .env value makes the
# sweep's filter never match what compose actually wrote — silently
# recreating the original leak, or worse, colliding with an unrelated
# project that happens to share the (wrongly-computed) normalized name.
PROJECT_NAME="$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]//g; s/^[_-]+//')"

if [ -n "$COMPOSE_FILE" ]; then
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
#
# Each call is bounded so a wedged daemon can't hang worktree removal
# indefinitely — the same failure mode `compose down`'s own timeout guards
# against above.
_dkr() { timeout 20s docker "$@"; }

if [ -z "$PROJECT_NAME" ]; then
    # Normalizes-to-empty is degenerate (e.g. a name of only punctuation);
    # a filter with no value would match nothing usable, so say so rather
    # than run pointless docker calls.
    echo "  WARN: project name normalized to empty for $WT — skipping label sweep" >&2
else
    _filter="label=com.docker.compose.project=$PROJECT_NAME"

    _containers=$(_dkr ps -aq --filter "$_filter" 2>/dev/null)
    if [ -n "$_containers" ]; then
        echo "  sweep: removing $(printf '%s\n' "$_containers" | wc -l) leftover container(s) for project $PROJECT_NAME"
        # shellcheck disable=SC2086
        _dkr rm -f -v $_containers >/dev/null 2>&1 || echo "  WARN: container sweep incomplete" >&2
    fi

    _volumes=$(_dkr volume ls -q --filter "$_filter" 2>/dev/null)
    if [ -n "$_volumes" ]; then
        echo "  sweep: removing $(printf '%s\n' "$_volumes" | wc -l) leftover volume(s) for project $PROJECT_NAME"
        # shellcheck disable=SC2086
        _dkr volume rm -f $_volumes >/dev/null 2>&1 || echo "  WARN: volume sweep incomplete" >&2
    fi

    _networks=$(_dkr network ls -q --filter "$_filter" 2>/dev/null)
    if [ -n "$_networks" ]; then
        echo "  sweep: removing $(printf '%s\n' "$_networks" | wc -l) leftover network(s) for project $PROJECT_NAME"
        # shellcheck disable=SC2086
        _dkr network rm $_networks >/dev/null 2>&1 || echo "  WARN: network sweep incomplete" >&2
    fi
fi

exit 0
