#!/usr/bin/env bash
#
# migration-collision-check.sh — detect duplicate Flyway version numbers and
# Alembic multi-head DAGs in the union of a PR head and its base branch.
#
# Parallel workers each compute "next free migration number/revision" against
# their own stale worktree base. A worker's own tests always pass — the
# collision only exists in the *union* of branches, so the only place it can
# be reliably caught is at merge time. This script is that gate; it does not
# fix the root cause (see #162, deferred) — detection-first per #294.
#
# Usage:
#   migration-collision-check.sh <PR#> [--post]
#
#   --post   also post the verdict as a PR comment with a
#            <!-- SWARM_MIGRATION_GATE: <clean|collision> --> marker.
#            Idempotent: skips posting when the latest marker comment
#            already carries the same verdict (same pattern as
#            scripts/stale-pr-nudges.sh's re-nudge suppression) — a
#            collision → collision re-run stays silent, but a
#            collision → clean transition (the fix landed) posts again.
#
# Detection:
#   Flyway   Union of migration-glob files (default
#            **/db/migration/**/V*__*.sql, override via MIGRATION_GLOB in
#            <project>/.swarm/.env) from the base tip and the PR head.
#            Files with the same version prefix (V106, V106.1 is a distinct
#            prefix from V106) but different filenames → collision. Catches
#            PR-vs-base dupes and PR-internal dupes (the union already
#            contains everything the PR head tree carries).
#   Alembic  Revision files under a `versions/` directory in that same
#            union. Static parse of `revision = ...` / `down_revision = ...`
#            assignments — no project venv or DB required. A revision id
#            never referenced as another file's down_revision is a head;
#            more than one head → collision.
#
# Exit codes:
#   0  clean — no collision detected
#   2  collision — duplicate Flyway version(s) and/or Alembic multi-head
#   4  skipped — no migration files found in the union (nothing to check)
#   1  error (gh/git failure, bad args)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR=""
POST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --post) POST=1 ;;
        -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        *)  [ -z "$PR" ] || { echo "ERROR: multiple PR numbers" >&2; exit 1; }
            PR="$1" ;;
    esac
    shift
done
[ -n "$PR" ] || { echo "Usage: $0 <PR#> [--post]" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git required" >&2; exit 1; }

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"
MIGRATION_GLOB="${MIGRATION_GLOB:-**/db/migration/**/V*__*.sql}"

# --- resolve PR base/head refs ----------------------------------------------

PR_JSON="$(gh pr view "$PR" --json baseRefName,headRefName)" \
    || { echo "ERROR: gh pr view $PR failed" >&2; exit 1; }
BASE_REF="$(printf '%s' "$PR_JSON" | jq -r .baseRefName)"
HEAD_REF="$(printf '%s' "$PR_JSON" | jq -r .headRefName)"
[ -n "$BASE_REF" ] && [ "$BASE_REF" != "null" ] || { echo "ERROR: could not resolve base ref for PR #$PR" >&2; exit 1; }
[ -n "$HEAD_REF" ] && [ "$HEAD_REF" != "null" ] || { echo "ERROR: could not resolve head ref for PR #$PR" >&2; exit 1; }

BASE_LOCAL="refs/migration-collision-check/base-$$"
HEAD_LOCAL="refs/migration-collision-check/head-$$"
cleanup() {
    git update-ref -d "$BASE_LOCAL" >/dev/null 2>&1 || true
    git update-ref -d "$HEAD_LOCAL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git fetch -q origin "$BASE_REF:$BASE_LOCAL" "$HEAD_REF:$HEAD_LOCAL" \
    || { echo "ERROR: git fetch of $BASE_REF/$HEAD_REF failed" >&2; exit 1; }

# --- helpers -----------------------------------------------------------------

list_tree_files() {
    # $1 = ref; lists every path in that tree (one per line).
    git ls-tree -r --name-only "$1" 2>/dev/null || true
}

shopt -s extglob

matches_glob() {
    # $1 = path, $2 = glob pattern. bash [[ ]] matching gives a bare '*' no
    # special slash-boundary treatment (it already crosses '/'), but a
    # literal "**/ " segment needs to also match ZERO directories (e.g.
    # "**/db/migration/**/V*.sql" must match "db/migration/V1__x.sql" with
    # no subdirectory either side) — plain [[ ]] can't express that, so
    # translate each "**/ " into an extglob "optionally-present" group.
    local pattern="${2//\*\*\//?(*/)}"
    # glob matching is the intent, not literal == — disable SC2053.
    # shellcheck disable=SC2053
    [[ "$1" == $pattern ]]
}

# --- Flyway: duplicate version prefixes -------------------------------------

FLYWAY_FILES="$( { list_tree_files "$BASE_LOCAL"; list_tree_files "$HEAD_LOCAL"; } \
    | sort -u | while IFS= read -r f; do
        if matches_glob "$f" "$MIGRATION_GLOB"; then
            echo "$f"
        fi
    done )"

declare -A VERSION_FILES=()
if [ -n "$FLYWAY_FILES" ]; then
    while IFS= read -r f; do
        base="$(basename "$f")"
        if [[ "$base" =~ ^V([0-9]+(\.[0-9]+)*)__ ]]; then
            ver="${BASH_REMATCH[1]}"
            VERSION_FILES["$ver"]="${VERSION_FILES[$ver]:-}$f"$'\n'
        fi
    done <<< "$FLYWAY_FILES"
fi

FLYWAY_COLLISIONS=()
for ver in "${!VERSION_FILES[@]}"; do
    files="${VERSION_FILES[$ver]}"
    count="$(printf '%s' "$files" | grep -c .)"
    if [ "$count" -gt 1 ]; then
        names="$(printf '%s' "$files" | tr '\n' ' ' | sed 's/ $//')"
        FLYWAY_COLLISIONS+=("V$ver claimed by: $names")
    fi
done

# --- Alembic: multi-head DAG -------------------------------------------------

ALEMBIC_FILES="$( { list_tree_files "$BASE_LOCAL"; list_tree_files "$HEAD_LOCAL"; } \
    | sort -u | grep -E '(^|/)versions/[^/]+\.py$' || true )"

declare -A REVISIONS=()   # revision id -> filename
declare -A REFERENCED=()  # revision id referenced as someone's down_revision

if [ -n "$ALEMBIC_FILES" ]; then
    while IFS= read -r f; do
        if git cat-file -e "$HEAD_LOCAL:$f" 2>/dev/null; then
            content="$(git show "$HEAD_LOCAL:$f" 2>/dev/null || true)"
        else
            content="$(git show "$BASE_LOCAL:$f" 2>/dev/null || true)"
        fi
        # `grep | head` under pipefail still propagates grep's exit 1 on no
        # match even though head itself succeeds — pipefail reports the
        # rightmost NON-ZERO stage, not just the last stage's status. A
        # revision-less file (e.g. versions/__init__.py) would otherwise
        # kill the whole script via set -e. Each pipeline feeding an
        # assignment here needs its own `|| true`.
        rev_line="$(printf '%s\n' "$content" | grep -E '^[[:space:]]*revision[[:space:]]*(:[^=]*)?=' | head -1 || true)"
        rev="$(printf '%s\n' "$rev_line" | grep -oE "['\"][A-Za-z0-9_]+['\"]" | head -1 | tr -d "'\"" || true)"
        [ -n "$rev" ] || continue
        REVISIONS["$rev"]="$f"
        down_line="$(printf '%s\n' "$content" | grep -E '^[[:space:]]*down_revision[[:space:]]*(:[^=]*)?=' | head -1 || true)"
        while IFS= read -r d; do
            if [ -n "$d" ]; then
                REFERENCED["$d"]=1
            fi
        done < <(printf '%s\n' "$down_line" | grep -oE "['\"][A-Za-z0-9_]+['\"]" | tr -d "'\"")
    done <<< "$ALEMBIC_FILES"
fi

ALEMBIC_HEADS=()
for rev in "${!REVISIONS[@]}"; do
    if [ -z "${REFERENCED[$rev]:-}" ]; then
        ALEMBIC_HEADS+=("$rev (${REVISIONS[$rev]})")
    fi
done

# --- verdict -----------------------------------------------------------------

if [ -z "$FLYWAY_FILES" ] && [ -z "$ALEMBIC_FILES" ]; then
    echo "migration-collision-check: no migration files found in the union of $BASE_REF/$HEAD_REF — skipped"
    exit 4
fi

COLLISION=0
BODY_LINES=()
if [ "${#FLYWAY_COLLISIONS[@]}" -gt 0 ]; then
    COLLISION=1
    BODY_LINES+=("Duplicate Flyway version(s):")
    for c in "${FLYWAY_COLLISIONS[@]}"; do BODY_LINES+=("- $c"); done
    BODY_LINES+=("Remediation: rename the losing file(s) to the next free version.")
fi
if [ "${#ALEMBIC_HEADS[@]}" -gt 1 ]; then
    COLLISION=1
    BODY_LINES+=("Alembic multi-head DAG (${#ALEMBIC_HEADS[@]} heads):")
    for h in "${ALEMBIC_HEADS[@]}"; do BODY_LINES+=("- $h"); done
    BODY_LINES+=("Remediation: add an \`alembic merge\` revision joining the heads.")
fi

if [ "$COLLISION" = "1" ]; then
    VERDICT="collision"
    EXIT=2
else
    VERDICT="clean"
    EXIT=0
    BODY_LINES+=("No duplicate Flyway versions or Alembic multi-heads in the union of $BASE_REF/$HEAD_REF.")
fi

echo "PR #$PR migration-collision-check verdict: $VERDICT"
echo "---"
printf '%s\n' "${BODY_LINES[@]}"
echo "---"

# --- optionally post as a PR comment ----------------------------------------

if [ "$POST" = "1" ]; then
    LAST_VERDICT="$(gh pr view "$PR" --json comments --jq \
        '[.comments[] | select(.body | test("SWARM_MIGRATION_GATE:"))] | last | .body // empty' 2>/dev/null \
        | grep -oE 'SWARM_MIGRATION_GATE: (clean|collision)' | sed 's/^SWARM_MIGRATION_GATE: //' || true)"
    if [ "$LAST_VERDICT" = "$VERDICT" ]; then
        echo "post: skipped — PR #$PR already has a SWARM_MIGRATION_GATE: $VERDICT comment as the latest word"
    else
        COMMENT="$(printf '<!-- SWARM_MIGRATION_GATE: %s -->\n## Migration collision check\n\n%s\n\n<sub>scripts/migration-collision-check.sh — static detection of duplicate Flyway versions / Alembic multi-heads in the union of base and head branches (#294).</sub>\n' \
            "$VERDICT" "$(printf '%s\n' "${BODY_LINES[@]}")")"
        gh pr comment "$PR" --body "$COMMENT" \
            || { echo "ERROR: gh pr comment failed" >&2; exit 1; }
        echo "post: verdict comment added to PR #$PR"
    fi
fi

exit "$EXIT"
