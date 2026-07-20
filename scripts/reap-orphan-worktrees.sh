#!/usr/bin/env bash
#
# reap-orphan-worktrees.sh — bulk-reap stale wt-issue-* worktrees whose work
# is preserved elsewhere.
#
# Complements kill-finished-workers.sh, which iterates LIVE iss-* tmux
# windows. This script iterates wt-issue-N DIRECTORIES under the project
# parent, so it catches worktrees that outlived their tmux session (common
# after a session restart — tmux dies, the on-disk worktrees do not).
#
# Default safety predicate (--pr-finalized mode, three conditions):
#   1. Worktree dir mtime is at least --min-age-days N (default 2) old
#      — buffer against accidentally nuking a worker you just dispatched.
#   2. Clean tree: no uncommitted / staged / untracked files in the worktree.
#   3. PR for fix/issue-N is MERGED or CLOSED on GitHub.
#
# When all three hold, calls kill-worktree.sh <N> for that worktree.
# kill-worktree.sh deletes the local branch but never touches origin, so
# even a CLOSED-without-merge case remains recoverable via `gh pr reopen N`.
#
# Stricter mode: --merged-only (condition 3 requires MERGED, not CLOSED).
# No-network mode: --no-pr-check (replaces condition 3 with a cherry check
# against origin/<default-branch> — every local commit must already be on
# the default branch, by patch ID).

set -euo pipefail

usage() {
    cat <<EOF
reap-orphan-worktrees.sh — bulk-reap stale wt-issue-* worktrees safe to discard

USAGE
    reap-orphan-worktrees.sh [FLAGS]

DESCRIPTION
    Iterates wt-issue-N directories under the project's worktree parent.
    Parent resolution honors SWARM_WORKTREE_GROUPING:
        flat     -> \$(dirname \$PROJECT)                   (default)
        project  -> \$(dirname \$PROJECT)/\$(basename \$PROJECT)-worktrees
    For each:
      - skip if younger than --min-age-days
      - skip if the tree has uncommitted / untracked files
      - skip if the preservation gate fails (default: PR not finalized)
    Survivors get kill-worktree.sh <N> applied.

FLAGS
    -h, --help                  Show this help and exit
    -n, --dry-run               List what would be reaped; take no action
    -y, --yes                   Skip the confirmation prompt
        --min-age-days N        Require worktree dir at least N days old
                                (default: REAP_MIN_AGE_DAYS or 2)
        --pr-finalized          Reap when PR is MERGED or CLOSED (default)
        --merged-only           STRICT: only reap when PR is MERGED
        --no-pr-check           Skip gh entirely; require every local commit
                                to be on origin/<default-branch> by patch ID
                                (i.e., \`git cherry\` against the default
                                branch reports no '+' lines)
    -p, --project DIR           Project dir (default: \$PWD). Worktrees live
                                under \$(dirname \$DIR)/wt-issue-* (flat layout)
                                or \$(dirname \$DIR)/\$(basename \$DIR)-worktrees/wt-issue-*
                                (project layout). Set via SWARM_WORKTREE_GROUPING.

ENV
    REAP_MIN_AGE_DAYS           Default for --min-age-days (overridden by flag)

EXAMPLES
    reap-orphan-worktrees.sh --dry-run                     # preview
    reap-orphan-worktrees.sh                               # default: 2-day floor, PR-finalized
    reap-orphan-worktrees.sh --min-age-days 0 --yes        # aggressive (no age floor)
    reap-orphan-worktrees.sh --merged-only --yes           # safest
    reap-orphan-worktrees.sh --no-pr-check --yes           # offline / no gh

EXIT
    0    success (or nothing to reap)
    1    invalid args / not a git repo / user aborted confirmation
EOF
}

# Defaults --------------------------------------------------------------------
PROJECT_DIR="$PWD"
DRY=0
YES=0
MERGED_ONLY=0
PR_FINALIZED=1     # default mode
PR_CHECK=1
MIN_AGE_DAYS="${REAP_MIN_AGE_DAYS:-2}"

require_value() {
    if [ -z "${2:-}" ] || [[ "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            usage; exit 0 ;;
        -n|--dry-run)         DRY=1; shift ;;
        -y|--yes)             YES=1; shift ;;
        --merged-only)        MERGED_ONLY=1; PR_FINALIZED=0; PR_CHECK=1; shift ;;
        --pr-finalized)       PR_FINALIZED=1; MERGED_ONLY=0; PR_CHECK=1; shift ;;
        --no-pr-check)        PR_CHECK=0; PR_FINALIZED=0; MERGED_ONLY=0; shift ;;
        --min-age-days)       require_value "$1" "${2:-}"; MIN_AGE_DAYS="$2"; shift 2 ;;
        --min-age-days=*)     MIN_AGE_DAYS="${1#*=}"; shift ;;
        -p|--project)         require_value "$1" "${2:-}"; PROJECT_DIR="$2"; shift 2 ;;
        --project=*)          PROJECT_DIR="${1#*=}"; shift ;;
        -*)                   echo "ERROR: unknown flag: $1 (try --help)" >&2; exit 1 ;;
        *)                    echo "ERROR: unexpected positional arg: $1 (try --help)" >&2; exit 1 ;;
    esac
done

if ! [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --min-age-days must be a non-negative integer (got: $MIN_AGE_DAYS)" >&2
    exit 1
fi

# Resolve paths ---------------------------------------------------------------
if ! PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)"; then
    echo "ERROR: project dir not accessible: $PROJECT_DIR" >&2
    exit 1
fi
if [ ! -d "$PROJECT_DIR/.git" ] && ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: $PROJECT_DIR is not a git repository" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/kill-worktree.sh"

# Source the env loader to pick up SWARM_WORKTREE_GROUPING and get
# swarm_worktree_parent() to derive the scan dir.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"
PROJECT_PARENT="$(swarm_worktree_parent "$PROJECT_DIR")"

if [ ! -x "$KILL_WT" ]; then
    echo "ERROR: kill-worktree.sh not executable at $KILL_WT" >&2
    exit 1
fi

cd "$PROJECT_DIR"

# Determine the default branch (for --no-pr-check cherry check). Falls back
# to 'main' then 'master' if origin/HEAD isn't set.
DEFAULT_BRANCH=""
if ref=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
    DEFAULT_BRANCH="${ref#origin/}"
fi
if [ -z "$DEFAULT_BRANCH" ]; then
    if git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
        DEFAULT_BRANCH=main
    elif git rev-parse --verify --quiet refs/remotes/origin/master >/dev/null; then
        DEFAULT_BRANCH=master
    fi
fi
if [ "$PR_CHECK" = "0" ] && [ -z "$DEFAULT_BRANCH" ]; then
    echo "ERROR: --no-pr-check needs origin/<default-branch>; couldn't resolve one" >&2
    exit 1
fi

# Helpers ---------------------------------------------------------------------

# Returns 0 if worktree has no porcelain output (nothing uncommitted, staged,
# or untracked). Untracked is included because it commonly represents real
# work-in-progress the user forgot to add.
is_clean_tree() {
    [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

# Returns 0 if every local commit on HEAD is patch-ID-equivalent to one
# already on origin/$DEFAULT_BRANCH. Used only under --no-pr-check.
all_commits_upstream() {
    local out
    out=$(git -C "$1" cherry "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || true)
    ! echo "$out" | grep -q '^+'
}

# Portable mtime (epoch seconds). GNU coreutils first, BSD fallback.
mtime_epoch() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Pre-fetch PR states for every branch in a single gh call -------------------
# Keyed by the branch name itself (headRefName), not derived from the
# wt-issue-N dirname — a worktree can be repurposed onto a different branch
# mid-life (checkout -B from a parked worker), which decouples the dirname
# from the branch actually checked out. See issue #97. Skipped under
# --no-pr-check.
declare -A PR_STATE=()
if [ "$PR_CHECK" = "1" ]; then
    while IFS=$'\t' read -r ref state; do
        [ -n "$ref" ] && PR_STATE["$ref"]="$state"
    done < <(gh pr list --state all --limit 500 --json headRefName,state \
                --jq '.[] | "\(.headRefName)\t\(.state)"' 2>/dev/null || true)
fi

# Walk wt-issue-* under the project parent -----------------------------------
NOW=$(date +%s)
shopt -s nullglob
declare -a CANDIDATES=()
declare -a SKIPPED=()
FOUND=0

echo "=== reap-orphan-worktrees ==="
echo "  project:        $PROJECT_DIR"
echo "  scan dir:       $PROJECT_PARENT  (SWARM_WORKTREE_GROUPING=${SWARM_WORKTREE_GROUPING:-flat})"
echo "  min-age-days:   $MIN_AGE_DAYS"
if [ "$MERGED_ONLY" = "1" ]; then
    echo "  preservation:   PR must be MERGED"
elif [ "$PR_FINALIZED" = "1" ]; then
    echo "  preservation:   PR must be MERGED or CLOSED"
else
    echo "  preservation:   every commit must be on origin/$DEFAULT_BRANCH (--no-pr-check)"
fi
echo

for WT in "$PROJECT_PARENT"/wt-issue-*/; do
    WT="${WT%/}"
    NAME="$(basename "$WT")"
    ISSUE="${NAME#wt-issue-}"

    # Skip non-numeric tails (e.g., wt-issue-foo). Numeric only.
    if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
        echo "  $NAME  [non-numeric issue tag → skip]"
        continue
    fi

    FOUND=$((FOUND + 1))

    # Must look like a worktree (has a .git file/dir pointing into main repo).
    if [ ! -e "$WT/.git" ]; then
        echo "  $NAME  [no .git entry → skip (not a worktree)]"
        continue
    fi

    # 1. Age floor ------------------------------------------------------------
    if [ "$MIN_AGE_DAYS" -gt 0 ]; then
        MTIME=$(mtime_epoch "$WT" || echo "$NOW")
        AGE_DAYS=$(( (NOW - MTIME) / 86400 ))
        if [ "$AGE_DAYS" -lt "$MIN_AGE_DAYS" ]; then
            echo "  $NAME  [age ${AGE_DAYS}d < ${MIN_AGE_DAYS}d → skip]"
            SKIPPED+=("$NAME(age)")
            continue
        fi
    fi

    # 2. Clean tree -----------------------------------------------------------
    if ! is_clean_tree "$WT"; then
        echo "  $NAME  [uncommitted / untracked files → skip]"
        SKIPPED+=("$NAME(dirty)")
        continue
    fi

    # 3. Preservation gate ----------------------------------------------------
    if [ "$MERGED_ONLY" = "1" ] || [ "$PR_FINALIZED" = "1" ]; then
        # Look up PR state for the branch actually checked out in this
        # worktree, not the dirname-derived fix/issue-N — a repurposed
        # worker (checkout -B onto a different branch mid-life) decouples
        # the two. See issue #97.
        BRANCH="$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        if [ -z "$BRANCH" ]; then
            echo "  $NAME  [detached HEAD → skip (can't resolve a branch to check)]"
            SKIPPED+=("$NAME(detached)")
            continue
        fi
        state="${PR_STATE[$BRANCH]:-}"
        if [ -z "$state" ]; then
            if git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
                detail="no PR (pushed to origin/$BRANCH, none found)"
            else
                detail="no PR ($BRANCH unpushed)"
            fi
        else
            detail="PR $BRANCH state=$state"
        fi
    fi
    if [ "$MERGED_ONLY" = "1" ]; then
        if [ "$state" != "MERGED" ]; then
            echo "  $NAME  [$detail → skip (merged-only mode)]"
            SKIPPED+=("$NAME(pr=${state:-NONE})")
            continue
        fi
        reason="PR-MERGED($BRANCH)"
    elif [ "$PR_FINALIZED" = "1" ]; then
        if [ "$state" != "MERGED" ] && [ "$state" != "CLOSED" ]; then
            echo "  $NAME  [$detail → skip (pr-finalized mode)]"
            SKIPPED+=("$NAME(pr=${state:-NONE})")
            continue
        fi
        reason="PR-$state($BRANCH)"
    else
        if ! all_commits_upstream "$WT"; then
            echo "  $NAME  [local commits not on origin/$DEFAULT_BRANCH → skip]"
            SKIPPED+=("$NAME(unupstreamed)")
            continue
        fi
        reason="cherry-clean"
    fi

    echo "  $NAME  [clean, $reason → reap]"
    CANDIDATES+=("$ISSUE")
done

if [ "$FOUND" -eq 0 ]; then
    echo "No wt-issue-* directories under $PROJECT_PARENT."
    exit 0
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    echo
    echo "Nothing to reap given current filters. (${#SKIPPED[@]} skipped of $FOUND scanned.)"
    exit 0
fi

if [ "$DRY" = "1" ]; then
    echo
    echo "DRY-RUN — no action taken. Would reap: ${CANDIDATES[*]}"
    exit 0
fi

if [ "$YES" != "1" ]; then
    cat <<EOF

About to reap ${#CANDIDATES[@]} worktree(s): ${CANDIDATES[*]}
Each call: kill-worktree.sh removes wt-issue-N + fix/issue-N + iss-N tmux window.
Local branches deleted; origin branches preserved. Uncommitted work was
screened out above, but --force is still used.

EOF
    read -r -p "Type 'yes' to proceed: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

echo
for ISSUE in "${CANDIDATES[@]}"; do
    "$KILL_WT" "$ISSUE" "$PROJECT_DIR" || echo "  WARN: kill-worktree.sh exited non-zero for #$ISSUE (continuing)"
    echo
done

echo "Done. Reaped ${#CANDIDATES[@]} worktree(s) (skipped ${#SKIPPED[@]} of $FOUND scanned)."
