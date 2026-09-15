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
#   migration-collision-check.sh --ref <ref>
#
#   --ref    post-merge watchdog mode (#305): scan a SINGLE tree (e.g.
#            origin/master, HEAD) for the same collisions instead of a PR's
#            base+head union. The merge gate only fires for merges routed
#            through swarm-merge.sh — manual `gh pr merge`/UI merges bypass
#            it, and every real-world collision burst so far arrived that
#            way. Run this against the default branch on each coordinator
#            wake to catch those within minutes. Needs only git (no gh);
#            refs under origin/ are freshened with a best-effort fetch.
#            Not combinable with a PR# or --post.
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
#            assignments — no project venv or DB required. The same
#            revision id claimed by more than one file → collision (#350).
#            A revision id never referenced as another file's down_revision
#            is a head; more than one head → collision.
#
# Remediation (Flyway, PR mode): a collision verdict carries the exact fix —
#            which file loses (the one only the PR head has; base-side files
#            are already applied downstream and never move), the next free
#            version (max across base ∪ head ∪ every other open PR's changed
#            files, so a merge burst doesn't hand out the next PR's number),
#            and the git mv / commit / push lines to paste on the PR branch.
#            A PR-internal duplicate (no base-side claimant) is named as
#            such with no mv line — which one loses is the worker's call.
#            Deliberately NOT auto-applied: ~1 collision/week across swarms
#            vs. a branch-mutating code path with its own refuse-list (#162).
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
REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --post) POST=1 ;;
        --ref)
            shift
            [ $# -gt 0 ] || { echo "ERROR: --ref needs a ref argument" >&2; exit 1; }
            REF="$1" ;;
        -h|--help) sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        *)  [ -z "$PR" ] || { echo "ERROR: multiple PR numbers" >&2; exit 1; }
            PR="$1" ;;
    esac
    shift
done
if [ -n "$REF" ]; then
    [ -z "$PR" ] || { echo "ERROR: --ref and a PR# are mutually exclusive" >&2; exit 1; }
    [ "$POST" = 0 ] || { echo "ERROR: --post needs a PR#; not valid with --ref" >&2; exit 1; }
else
    [ -n "$PR" ] || { echo "Usage: $0 <PR#> [--post]  |  $0 --ref <ref>" >&2; exit 1; }
    command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }
fi
command -v git >/dev/null 2>&1 || { echo "ERROR: git required" >&2; exit 1; }

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"
MIGRATION_GLOB="${MIGRATION_GLOB:-**/db/migration/**/V*__*.sql}"

# --- resolve refs to scan ----------------------------------------------------
#
# SCAN_REFS holds the tree(s) whose UNION is checked. PR mode: base + head
# (later entries win when the same path must be read, so head stays
# preferred for Alembic content). --ref mode: just the one tree.

SCAN_REFS=()
if [ -n "$REF" ]; then
    # Freshen origin/* refs so "watchdog against origin/master" sees the
    # remote's current tip, not a stale local mirror; best-effort only.
    case "$REF" in
        origin/*) git fetch -q origin "${REF#origin/}" 2>/dev/null || true ;;
    esac
    git rev-parse --verify --quiet "$REF^{tree}" >/dev/null \
        || { echo "ERROR: ref '$REF' does not resolve to a tree" >&2; exit 1; }
    SCAN_REFS=("$REF")
    SCOPE_DESC="ref $REF"
else
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
    SCAN_REFS=("$BASE_LOCAL" "$HEAD_LOCAL")
    SCOPE_DESC="the union of $BASE_REF/$HEAD_REF"
fi

# --- helpers -----------------------------------------------------------------

list_tree_files() {
    # $1 = ref; lists every path in that tree (one per line).
    git ls-tree -r --name-only "$1" 2>/dev/null || true
}

list_scan_files() {
    # Union of every SCAN_REFS tree's paths, de-duplicated.
    local r
    for r in "${SCAN_REFS[@]}"; do list_tree_files "$r"; done | sort -u
}

show_scan_file() {
    # $1 = path. Print the file's content from the LAST SCAN_REFS tree that
    # has it (PR mode: head preferred over base; --ref mode: the one tree).
    local f="$1" i
    for (( i=${#SCAN_REFS[@]}-1; i>=0; i-- )); do
        if git cat-file -e "${SCAN_REFS[$i]}:$f" 2>/dev/null; then
            git show "${SCAN_REFS[$i]}:$f" 2>/dev/null || true
            return
        fi
    done
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

FLYWAY_FILES="$(list_scan_files | while IFS= read -r f; do
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

# --- Flyway: concrete remediation recipe (PR mode only) ---------------------
#
# The gate used to say "rename the losing file(s) to the next free version"
# and leave the operator to work out which file loses and what "next free"
# is. Both are mechanical, so compute them:
#   loser     = the claimant that exists ONLY in the PR head. Base-side files
#               are already applied to every DB tracking the base branch;
#               renaming one of those forces a `flyway repair` everywhere.
#   next free = max integer version across base ∪ head ∪ every OTHER open
#               PR's changed files (gh pr list --json files, best-effort) + 1.
#               Without the open-PR sweep the recipe hands out the number
#               the next PR in a merge burst already claimed.
# Multiple losers get consecutive numbers. A collision with no base-side
# claimant is PR-internal (the worker shipped two files at one version) —
# that's a worker bug, so the recipe just says so. --ref mode has no
# base/head split and keeps the generic line.
FLYWAY_RECIPE=()
if [ -z "$REF" ] && [ "${#FLYWAY_COLLISIONS[@]}" -gt 0 ]; then
    BASE_FLYWAY="$(list_tree_files "$BASE_LOCAL" | while IFS= read -r f; do
            matches_glob "$f" "$MIGRATION_GLOB" && echo "$f"
        done; true )"
    in_base() { printf '%s\n' "$BASE_FLYWAY" | grep -qxF -- "$1"; }

    # Migration files on every other open PR's head — same glob, same
    # version-prefix parse. gh failures (offline, stubbed, rate-limited)
    # degrade to "no other PRs considered", noted in the output.
    OTHER_PR_FILES="$(gh pr list --state open --limit 100 --json number,files \
        --jq ".[] | select(.number != $PR) | .files[].path" 2>/dev/null || true )"
    OTHER_PR_COUNT="$(gh pr list --state open --limit 100 --json number \
        --jq "[.[] | select(.number != $PR)] | length" 2>/dev/null || echo 0)"
    [[ "$OTHER_PR_COUNT" =~ ^[0-9]+$ ]] || OTHER_PR_COUNT=0

    max_ver=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        matches_glob "$f" "$MIGRATION_GLOB" || continue
        b="$(basename "$f")"
        if [[ "$b" =~ ^V([0-9]+) ]]; then
            n="${BASH_REMATCH[1]}"; n=$((10#$n))
            [ "$n" -gt "$max_ver" ] && max_ver="$n"
        fi
    done < <(printf '%s\n%s\n' "$FLYWAY_FILES" "$OTHER_PR_FILES")
    next_ver=$((max_ver + 1))

    FLYWAY_RECIPE+=("Remediation — rename the PR-side file(s) on branch $HEAD_REF; base-side ($BASE_REF) files are already applied downstream, never move those.")
    FLYWAY_RECIPE+=("  next free version: V$next_ver (max across $BASE_REF, $HEAD_REF, and $OTHER_PR_COUNT other open PR(s))")
    for c in "${FLYWAY_COLLISIONS[@]}"; do
        ver="${c%% claimed by:*}"                    # "V187"
        claimants="${c#* claimed by: }"              # space-joined paths
        base_side=(); head_side=()
        for f in $claimants; do
            if in_base "$f"; then base_side+=("$f"); else head_side+=("$f"); fi
        done
        if [ "${#base_side[@]}" -eq 0 ]; then
            FLYWAY_RECIPE+=("  $ver: every claimant is PR-side (PR-internal duplicate — the branch shipped two files at one version); renumber one of them to V$next_ver")
            next_ver=$((next_ver + 1))
            continue
        fi
        FLYWAY_RECIPE+=("  $ver: $BASE_REF owns $(basename "${base_side[0]}")")
        for f in "${head_side[@]}"; do
            # V<old>__rest → V<next>__rest; non-greedy on the FIRST "__" so a
            # description containing "__" survives intact.
            fb="$(basename "$f")"
            if [[ "$fb" =~ ^V[0-9.]+__(.*)$ ]]; then rest="${BASH_REMATCH[1]}"; else rest="$fb"; fi
            newf="$(dirname "$f")/V${next_ver}__${rest}"
            case "$f" in
                *.sql) ;;
                *) FLYWAY_RECIPE+=("    (Java/Kotlin-based migration — the class name must be renamed to match as well)") ;;
            esac
            FLYWAY_RECIPE+=("    git mv $f $newf")
            FLYWAY_RECIPE+=("    git commit -m \"fix(migration): renumber $ver → V$next_ver, $ver taken on $BASE_REF\"")
            FLYWAY_RECIPE+=("    git push origin $HEAD_REF")
            next_ver=$((next_ver + 1))
        done
    done
    FLYWAY_RECIPE+=("  then re-run: scripts/migration-collision-check.sh $PR")
fi

# --- Alembic: multi-head DAG -------------------------------------------------

ALEMBIC_FILES="$(list_scan_files | grep -E '(^|/)versions/[^/]+\.py$' || true )"

declare -A REVISION_FILES=()  # revision id -> newline-joined list of files claiming it
declare -A REFERENCED=()      # revision id referenced as someone's down_revision

if [ -n "$ALEMBIC_FILES" ]; then
    while IFS= read -r f; do
        content="$(show_scan_file "$f")"
        # `grep | head` under pipefail still propagates grep's exit 1 on no
        # match even though head itself succeeds — pipefail reports the
        # rightmost NON-ZERO stage, not just the last stage's status. A
        # revision-less file (e.g. versions/__init__.py) would otherwise
        # kill the whole script via set -e. Each pipeline feeding an
        # assignment here needs its own `|| true`.
        rev_line="$(printf '%s\n' "$content" | grep -E '^[[:space:]]*revision[[:space:]]*(:[^=]*)?=' | head -1 || true)"
        rev="$(printf '%s\n' "$rev_line" | grep -oE "['\"][A-Za-z0-9_]+['\"]" | head -1 | tr -d "'\"" || true)"
        [ -n "$rev" ] || continue
        # Keep every file claiming this id (not just the last one seen) so a
        # duplicate revision id — e.g. three files with revision="0075" —
        # is counted rather than silently overwritten in the map, same
        # pattern as VERSION_FILES above (#350).
        REVISION_FILES["$rev"]="${REVISION_FILES[$rev]:-}$f"$'\n'
        down_line="$(printf '%s\n' "$content" | grep -E '^[[:space:]]*down_revision[[:space:]]*(:[^=]*)?=' | head -1 || true)"
        while IFS= read -r d; do
            if [ -n "$d" ]; then
                REFERENCED["$d"]=1
            fi
        done < <(printf '%s\n' "$down_line" | grep -oE "['\"][A-Za-z0-9_]+['\"]" | tr -d "'\"")
    done <<< "$ALEMBIC_FILES"
fi

ALEMBIC_DUP_REVISIONS=()
for rev in "${!REVISION_FILES[@]}"; do
    files="${REVISION_FILES[$rev]}"
    count="$(printf '%s' "$files" | grep -c .)"
    if [ "$count" -gt 1 ]; then
        names="$(printf '%s' "$files" | tr '\n' ' ' | sed 's/ $//')"
        ALEMBIC_DUP_REVISIONS+=("$rev claimed by: $names")
    fi
done

ALEMBIC_HEADS=()
for rev in "${!REVISION_FILES[@]}"; do
    if [ -z "${REFERENCED[$rev]:-}" ]; then
        first_file="$(printf '%s' "${REVISION_FILES[$rev]}" | head -1)"
        ALEMBIC_HEADS+=("$rev ($first_file)")
    fi
done

# --- verdict -----------------------------------------------------------------

if [ -z "$FLYWAY_FILES" ] && [ -z "$ALEMBIC_FILES" ]; then
    echo "migration-collision-check: no migration files found in $SCOPE_DESC — skipped"
    exit 4
fi

COLLISION=0
BODY_LINES=()
if [ "${#FLYWAY_COLLISIONS[@]}" -gt 0 ]; then
    COLLISION=1
    BODY_LINES+=("Duplicate Flyway version(s):")
    for c in "${FLYWAY_COLLISIONS[@]}"; do BODY_LINES+=("- $c"); done
    if [ "${#FLYWAY_RECIPE[@]}" -gt 0 ]; then
        for c in "${FLYWAY_RECIPE[@]}"; do BODY_LINES+=("$c"); done
    else
        BODY_LINES+=("Remediation: rename the losing file(s) to the next free version.")
    fi
fi
if [ "${#ALEMBIC_DUP_REVISIONS[@]}" -gt 0 ]; then
    COLLISION=1
    BODY_LINES+=("Duplicate Alembic revision id(s):")
    for c in "${ALEMBIC_DUP_REVISIONS[@]}"; do BODY_LINES+=("- $c"); done
    BODY_LINES+=("Remediation: renumber the losing file(s) to a unique revision id.")
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
    BODY_LINES+=("No duplicate Flyway versions or Alembic multi-heads in $SCOPE_DESC.")
fi

if [ -n "$REF" ]; then
    echo "$SCOPE_DESC migration-collision-check verdict: $VERDICT"
else
    echo "PR #$PR migration-collision-check verdict: $VERDICT"
fi
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
