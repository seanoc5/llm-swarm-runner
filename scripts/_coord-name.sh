#!/usr/bin/env bash
# _coord-name.sh — the deterministic harness session name of a project's
# claude coordinator (issue #421, ADR 0005 Option 1).
#
# Sourced by coordinator-claude.sh (launches the coordinator with
# `claude --name <this>`) and coord-doorbell.sh (addresses SendMessage to it),
# so the two can never derive the name differently. ListAgents lists only
# live sessions, so one name per project is enough to find "my swarm's
# coordinator" without grepping a global list. Two live coordinators for the
# same project basename would collide; the swarm already runs one per project.

# coord_session_name <project-dir> -> swarm-<basename>, restricted to
# [A-Za-z0-9._-] so it is safe in argv and in a SendMessage `to`.
coord_session_name() {
    local base
    base="$(basename "${1:?coord_session_name: project dir required}")"
    printf 'swarm-%s\n' "$(printf '%s' "$base" | LC_ALL=C tr -c 'A-Za-z0-9._\n-' '-')"
}
