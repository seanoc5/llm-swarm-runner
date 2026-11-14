#!/usr/bin/env bash
# _coord-name.sh — the deterministic harness session name of a project's
# claude coordinator (issue #421, ADR 0005 Option 1).
#
# Sourced by coordinator-claude.sh (launches the coordinator with
# `claude --name <this>`) and coord-doorbell.sh (addresses SendMessage to it),
# so the two can never derive the name differently. ListAgents lists only
# live sessions, so one name per project is enough to find "my swarm's
# coordinator" without grepping a global list.
#
# The name carries a short hash of the project's physical absolute path so two
# projects with the same folder name (e.g. /a/app and /b/app) never share a
# session name — otherwise a wake could land in the other swarm's coordinator
# and still be logged as delivered.

# coord_session_name <project-dir> -> swarm-<basename>-<8 hex of path hash>,
# basename restricted to [A-Za-z0-9._-] so it is safe in argv and in a
# SendMessage `to`.
coord_session_name() {
    local dir abs base hash
    dir="${1:?coord_session_name: project dir required}"
    abs="$(cd "$dir" 2>/dev/null && pwd -P)" || abs="${dir%/}"
    base="$(basename "$abs")"
    hash="$(printf '%s' "$abs" | sha1sum 2>/dev/null | cut -c1-8)"
    [ -n "$hash" ] || hash="$(printf '%s' "$abs" | cksum | cut -d' ' -f1)"
    printf 'swarm-%s-%s\n' "$(printf '%s' "$base" | LC_ALL=C tr -c 'A-Za-z0-9._\n-' '-')" "$hash"
}
