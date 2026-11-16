#!/usr/bin/env bash
#
# _claude-trust.sh — pre-accept Claude Code's "do you trust this folder?"
# dialog in a per-container ~/.claude.json copy (issue #950). Sourced by
# sandbox.sh; safe to source anywhere (defines one function, no side effects).
#
# Why: the CLI keeps trust under projects["<absolute cwd>"].hasTrustDialogAccepted.
# A container whose copy has no entry for its worktree opens on the dialog and
# nobody answers it (oconeco-site iss-232, 2026-11-14: woken twice, parked on
# the dialog each time, sidelined as "stalled"). The cwd the CLI sees is the
# symlink-resolved path (sandbox.sh realpath's PROJECT_DIR) but the path the
# operator/worktree registry knows can be the symlinked one, so callers pass
# BOTH spellings.

# claude_config_trust_paths <config-file> <abs-path>...
# Sets hasTrustDialogAccepted=true for each path, keeping every other field
# of the file and of the project entry. No-op (rc 0) without jq, or when the
# file is missing/empty/not a JSON object — never turns a bad file into a
# worse one; sandbox.sh and worker-listener.sh own repairing those. Writes in
# place (cat >) like worker-listener.sh's repair, so a file that is already
# bind-mounted into a running container keeps its inode.
claude_config_trust_paths() {
    local cfg="${1:-}"; shift || true
    [ -n "$cfg" ] && [ "$#" -gt 0 ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    [ -s "$cfg" ] && jq -e 'type == "object"' "$cfg" >/dev/null 2>&1 || return 0
    local paths_json tmp
    paths_json="$(printf '%s\n' "$@" | grep -v '^$' | sort -u | jq -R . | jq -s .)" || return 0
    tmp="$(mktemp "$cfg.trust.XXXXXX")" || return 0
    if jq --argjson p "$paths_json" '
            reduce $p[] as $d (.;
                .projects = ((.projects // {}) | if type == "object" then . else error("projects is not an object") end)
                | .projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true}))
        ' "$cfg" > "$tmp" 2>/dev/null \
       && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
        cmp -s "$tmp" "$cfg" || cat "$tmp" > "$cfg" 2>/dev/null || true
    fi
    rm -f "$tmp"
    return 0
}
