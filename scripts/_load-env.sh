#!/usr/bin/env bash
# _load-env.sh — sourceable env loader for llm-swarm-runner scripts.
#
# Applies <project>/.swarm/.env, then <sandbox>/.env (host-level, gitignored),
# then <sandbox>/.env.example to the current shell, leaving already-set
# variables untouched. Caller-supplied env wins.
#
# Usage:
#   . "$LLM_SWARM_DIR/scripts/_load-env.sh" [project-dir]
#
# Final precedence (highest wins):
#   1. shell env (anything already exported)
#   2. <project-dir>/.swarm/.env      per-project durable override
#   3. <sandbox>/.env                 this machine's defaults (gitignored)
#   4. <sandbox>/.env.example         shipped defaults (tracked)
#
# Tier 3 is where a host's physical reality goes -- HOST_MAX_WORKERS sized to
# this box's RAM, FAND_DATA_ROOT, and so on -- so those values don't have to be
# repeated in every project's .swarm/.env and never get committed upstream.
#
# Parsing rules:
#   - blanks and # comments skipped
#   - KEY=VALUE only (export prefix tolerated, stripped)
#   - surrounding single or double quotes on VALUE stripped
#   - inline comments NOT supported (kept literal — keep .env entries clean)

# Don't enable -u / -e here; this is sourced into scripts that may not have
# them. Use guards on each var read instead.

_apply_env_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    local line k v
    while IFS= read -r line || [ -n "$line" ]; do
        # blank / comment
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # KEY=VAL with optional `export ` prefix
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            k="${BASH_REMATCH[2]}"
            v="${BASH_REMATCH[3]}"
            # strip optional surrounding quotes
            if [[ "$v" =~ ^\".*\"$ ]] || [[ "$v" =~ ^\'.*\'$ ]]; then
                v="${v:1:${#v}-2}"
            fi
            # only export if unset (empty-but-set values from caller still win)
            [ -z "${!k+x}" ] && export "$k=$v"
        fi
    done < "$f"
    # Force success — the last iteration's body may return non-zero when
    # the final `[ -z "${!k+x}" ] && export ...` short-circuits because the
    # var was already set in the caller's env. That non-zero would propagate
    # out of the function and trip `set -e` in the caller, killing the
    # script silently before it produces any output. The coordinator
    # diagnosed this in the wild after a watcher pane died on startup with
    # POLL_SECS pre-set in the tmux session env. (See events.log /
    # provision-worker.sh sourcing chain.)
    return 0
}

# Expand ${FAND_DATA_ROOT} references inside EXTRA_MOUNTS after both env
# files are applied, so the resolved FAND_DATA_ROOT (caller env > project
# .swarm/.env > sandbox .env.example) feeds the bind-mount spec consumed
# by sandbox.sh and provision-worker.sh. See fand-poc ADR-0008. The
# allow-list form expands ONLY ${FAND_DATA_ROOT}; any other `$` in
# EXTRA_MOUNTS is left literal, so we don't accidentally pull in
# unrelated shell vars.
_expand_extra_mounts() {
    [ -n "${EXTRA_MOUNTS:-}" ] || return 0
    [[ "$EXTRA_MOUNTS" == *'${FAND_DATA_ROOT}'* ]] || return 0
    if ! command -v envsubst >/dev/null 2>&1; then
        echo "warn: envsubst not found; EXTRA_MOUNTS contains \${FAND_DATA_ROOT} but cannot expand" >&2
        return 0
    fi
    EXTRA_MOUNTS="$(FAND_DATA_ROOT="${FAND_DATA_ROOT:-}" envsubst '${FAND_DATA_ROOT}' <<< "$EXTRA_MOUNTS")"
    export EXTRA_MOUNTS
}

_load_env_main() {
    local proj sandbox
    proj="${1:-$PWD}"
    # Caller may pre-set LLM_SWARM_DIR; otherwise infer from this script's path.
    sandbox="${LLM_SWARM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    _apply_env_file "$proj/.swarm/.env"        # project override
    _apply_env_file "$sandbox/.env"            # this host's defaults (gitignored)
    _apply_env_file "$sandbox/.env.example"    # ship defaults
    _expand_extra_mounts                       # resolve ${FAND_DATA_ROOT} sentinel
}

_load_env_main "$@"

# --- Worktree path derivation (public; survives the unset below) ------------
#
# Derive the worktree directory for issue N belonging to PROJECT_DIR.
# Honors SWARM_WORKTREE_GROUPING (default `flat` for backward compat).
#
#   flat     — <parent>/wt-issue-N            (original layout, since v0)
#   project  — <parent>/<project>-worktrees/wt-issue-N
#
# Project grouping avoids the cross-project namespace collision that hits
# when multiple sibling repos under the same parent dir all issue
# `wt-issue-N` paths and a deleted-then-recreated sibling worktree
# clobbers a live one. See fand-guide/.swarm-policy.md "Worktree namespace
# collisions" and the orphan-cleanup standing authorization in operator
# memory.
#
# Usage:
#   . _load-env.sh "$PROJECT_DIR"
#   WT=$(swarm_worktree_dir "$PROJECT_DIR" "$ISSUE")
swarm_worktree_dir() {
    local project_dir="$1"
    local issue="$2"
    local parent base
    parent="$(dirname "$project_dir")"
    base="$(basename "$project_dir")"
    case "${SWARM_WORKTREE_GROUPING:-flat}" in
        project)
            echo "$parent/${base}-worktrees/wt-issue-$issue"
            ;;
        flat|"")
            echo "$parent/wt-issue-$issue"
            ;;
        *)
            echo "warn: unknown SWARM_WORKTREE_GROUPING='${SWARM_WORKTREE_GROUPING}', falling back to 'flat'" >&2
            echo "$parent/wt-issue-$issue"
            ;;
    esac
}

# Derive the discovery directory (where to scan for *this project's* worktrees).
# Caller appends /wt-issue-* to walk.
swarm_worktree_parent() {
    local project_dir="$1"
    local parent base
    parent="$(dirname "$project_dir")"
    base="$(basename "$project_dir")"
    case "${SWARM_WORKTREE_GROUPING:-flat}" in
        project)
            echo "$parent/${base}-worktrees"
            ;;
        flat|""|*)
            echo "$parent"
            ;;
    esac
}

# Cleanup internal-only helpers from caller scope so they don't leak.
# `swarm_worktree_dir` and `swarm_worktree_parent` are public — left in scope.
unset -f _apply_env_file _expand_extra_mounts _load_env_main
