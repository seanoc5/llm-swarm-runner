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
#
# issue #357: appending /wt-issue-* to this directly (the original,
# still-supported pattern for callers that need a raw scan root) is only
# safe under SWARM_WORKTREE_GROUPING=project, where the directory is
# exclusive to this project. Under flat (the historical default), it's the
# project's PARENT dir — shared with any sibling repo checked out
# alongside it — so a same-named wt-issue-N belonging to a different
# project's swarm silently matches too, and issue numbers carry no project
# identity to catch the mixup. Prefer swarm_own_worktree_dirs() below,
# which is immune to this regardless of grouping mode.
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

# swarm_own_worktree_dirs <project_dir>
#
# issue #357: lists THIS project's own worker worktree directories, one per
# line — the fix for swarm_worktree_parent()'s cross-project glob exposure
# under flat grouping (see its header above). Source of truth is `git
# worktree list` run against $project_dir's own repo: the authoritative
# registry of every worktree git actually created for it, regardless of
# directory naming or SWARM_WORKTREE_GROUPING layout. A foreign directory
# that merely happens to be named wt-issue-N can never appear here, because
# it was never `git worktree add`-ed against this repo.
#
# Also picks up DANGLING-registration worktrees (issue #225: after a
# Docker daemon restart, a worktree dir can survive while the main repo's
# `.git/worktrees/<name>` administrative area backing it is gone — `git
# worktree list` no longer lists it at all, since that registry entry IS
# the thing that's missing). A self-review on this issue's own fix caught
# that routing sweep-swarm-outcomes.sh/swarm-scoreboard.sh through a
# healthy-only listing silently stopped them seeing outcomes/eval-log rows
# from a worktree in exactly this state — the same one
# reap-orphan-worktrees.sh still reaps by design. So both scan roots
# (flat and project grouping — the caller's SWARM_WORKTREE_GROUPING might
# differ from whatever a stale worktree was created under) are also
# globbed for wt-issue-N dirs `git worktree list` didn't already return,
# each verified by reading its own `.git` file's `gitdir:` target and
# requiring it resolve under $project_dir's own `<common-dir>/worktrees/`
# — the same ownership fact reap-orphan-worktrees.sh's reap_dangling()
# relies on before removing anything, so a foreign dangling worktree still
# can't be mistaken for this project's.
#
# Excludes the project's own main worktree. Restricted to the
# wt-issue-<N> naming convention this project's tooling creates
# (provision-worker.sh / swarm_worktree_dir) — pass a second arg of "all"
# to include non-numbered worktrees too (rare: a manual `git worktree add`
# outside the swarm tooling).
#
# Fail-quiet: if $project_dir isn't a git repo (or `git worktree list`
# otherwise errors), prints nothing rather than falling back to a glob —
# unlike is_our_worktree()'s fail-OPEN policy in coordinator-watch.sh
# (which exists to preserve pre-#357 behavior for an already-running
# watcher's event filter), a cold listing has no prior behavior to
# preserve, so failing quiet is the safer default for a script about to
# `rm -rf` or otherwise act on the result.
swarm_own_worktree_dirs() {
    local project_dir="$1" mode="${2:-}"
    local main_dir common_dir wt wt_real parent1 parent2 cand admin_dir
    main_dir="$(cd "$project_dir" 2>/dev/null && pwd -P)" || return 0
    common_dir="$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null)" || return 0
    case "$common_dir" in
        /*) ;;
        *) common_dir="$project_dir/$common_dir" ;;
    esac

    local -A seen=()
    while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        wt_real="$(cd "$wt" 2>/dev/null && pwd -P)" || wt_real="$wt"
        [ "$wt_real" = "$main_dir" ] && continue
        seen["$wt"]=1
    done < <(git -C "$project_dir" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10)}')

    parent1="$(dirname "$project_dir")"                                # flat
    parent2="$parent1/$(basename "$project_dir")-worktrees"            # project
    for cand in "$parent1"/wt-issue-*/ "$parent2"/wt-issue-*/; do
        cand="${cand%/}"
        [ -d "$cand" ] || continue
        [ -n "${seen[$cand]:-}" ] && continue
        [ -f "$cand/.git" ] || continue
        admin_dir="$(sed -n 's/^gitdir: //p' "$cand/.git" 2>/dev/null | head -n1)"
        case "$admin_dir" in
            "$common_dir/worktrees/"*) seen["$cand"]=1 ;;
        esac
    done

    for wt in "${!seen[@]}"; do
        if [ "$mode" = "all" ]; then
            echo "$wt"
        else
            case "$(basename "$wt")" in
                wt-issue-[0-9]*) echo "$wt" ;;
            esac
        fi
    done
}

# Cleanup internal-only helpers from caller scope so they don't leak.
# `swarm_worktree_dir`, `swarm_worktree_parent` and `swarm_own_worktree_dirs`
# are public — left in scope.
unset -f _apply_env_file _expand_extra_mounts _load_env_main
