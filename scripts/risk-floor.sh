#!/usr/bin/env bash
#
# risk-floor.sh — the lowest 🟢/🟡/🔴 rating a PR's diff allows (issue #731).
#
# The BLIND_MERGE_RISK marker is the authoring worker's self-rating, and a 🟢
# PR merges unattended with only the coordinator's own diff read behind it.
# Nothing checked that the rating matched the diff. This script is the
# deterministic (no AI) check: it prints the floor and the rule(s) that set
# it, so callers can refuse a rating below it.
#
# Usage:
#   risk-floor.sh <PR#>           read-only: print the floor and why
#   risk-floor.sh --apply <PR#>   also enforce it on the PR: when the body's
#                                 marker is below the floor, bump the marker
#                                 (and the footer's colour) and post a comment
#                                 naming the rule(s). Idempotent per head sha.
#
# Output (stdout), one item per line, the floor first:
#   floor: low|medium|high
#   rule: <name> — <what fired>        raises the floor
#   note: <name> — <what was seen>     advisory only, never raises the floor
#
# Exit codes:
#   0   ok (read-only: floor printed; --apply: the rating already met it)
#   10  --apply bumped the marker (the PR is now rated at the floor)
#   1   usage / gh error (callers fail toward requiring review)
#
# Rules (all raise the floor to medium; each is configurable). Patterns are
# extended regexes matched against the repo-relative path:
#   migrations  a changed path matches RISK_FLOOR_MIGRATION_RE
#               (default: Flyway db/migration/, Alembic alembic/versions/,
#               Rails/Django-style migrations/*.sql|py)
#   sensitive   a changed path matches RISK_FLOOR_SENSITIVE_RE (default: build
#               files, Dockerfiles, CI workflows, compose files, auth/security
#               config classes)
#   lines       additions + deletions exceed RISK_FLOOR_MAX_LINES (default 300)
#   tests       a test file (RISK_FLOOR_TEST_RE) is deleted, or a line matching
#               RISK_FLOOR_SKIP_RE (@Disabled, skip(), xit() …) is added to one
#   scope       advisory only: a changed file under no path the brief/issue
#               text mentions (too fuzzy to gate). Text comes from
#               RISK_FLOOR_BRIEF (a file), else the worker's brief under
#               .swarm/tasks/ for $TASK_ID, else the issue the PR body closes.
#               No text found = rule silently skipped.
#
# Settings (env; per project in <project>/.swarm/.env, see .env.example):
#   RISK_FLOOR_MAX_LINES, RISK_FLOOR_MIGRATION_RE, RISK_FLOOR_SENSITIVE_RE,
#   RISK_FLOOR_TEST_RE, RISK_FLOOR_SKIP_RE, RISK_FLOOR_BRIEF, and
#   RISK_FLOOR_DISABLE — space/comma list of rule names to turn off
#   (migrations sensitive lines tests scope).
#
# GH_REPO=<owner/name> points it at another repo (used by
# risk-floor-dryrun.sh); otherwise gh resolves the repo from the cwd.
set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USAGE="usage: risk-floor.sh [--apply] <PR#>"
APPLY=0
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        -h|--help) echo "$USAGE"; exit 0 ;;
        --) shift; break ;;
        *) echo "ERROR: unknown flag '$1' ($USAGE)" >&2; exit 1 ;;
    esac
done
PR="${1:?$USAGE}"
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "ERROR: PR number must be numeric, got '$PR' ($USAGE)" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

# Settings (RISK_FLOOR_*, TASK_ID) may live only in the project's .swarm/.env.
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

MAX_LINES="${RISK_FLOOR_MAX_LINES:-300}"
case "$MAX_LINES" in ''|*[!0-9]*) echo "ERROR: RISK_FLOOR_MAX_LINES must be a number, got '$MAX_LINES'" >&2; exit 1 ;; esac
MIGRATION_RE="${RISK_FLOOR_MIGRATION_RE:-(^|/)db/migration/|(^|/)alembic/versions/|(^|/)migrations/[^/]+\.(sql|py)$}"
SENSITIVE_RE="${RISK_FLOOR_SENSITIVE_RE:-(^|/)(build|settings)\.gradle(\.kts)?$|(^|/)pyproject\.toml$|(^|/)pom\.xml$|(^|/)Dockerfile(\.[A-Za-z0-9_-]+)?$|(^|/)docker-compose[^/]*\.ya?ml$|(^|/)\.github/workflows/|(^|/)[A-Za-z]*(Security|Auth)[A-Za-z]*(Config|Configuration|Filter)[A-Za-z]*\.(kt|java|py|ts)$}"
TEST_RE="${RISK_FLOOR_TEST_RE:-(^|/)(tests?|__tests__|spec)/|(^|/)src/test/|[Tt]ests?[A-Za-z]*\.(kt|java|py|ts|js|sh)$|_test\.(go|py)$|\.(test|spec)\.(ts|tsx|js)$}"
SKIP_RE="${RISK_FLOOR_SKIP_RE:-@Disabled|@Ignore|@pytest\.mark\.skip|pytest\.skip\(|@unittest\.skip|(it|test|describe)\.skip\(|(^|[^A-Za-z])x(it|describe)\(|t\.Skip\(|@Test\(enabled *= *false}"
_dis="${RISK_FLOOR_DISABLE:-}"; DISABLE=" ${_dis//,/ } "
rule_on() { [[ "$DISABLE" != *" $1 "* ]]; }

rank()  { case "$1" in low) echo 0 ;; medium) echo 1 ;; high) echo 2 ;; *) echo 1 ;; esac; }
emoji() { case "$1" in low) echo 🟢 ;; medium) echo 🟡 ;; high) echo 🔴 ;; esac; }

# --- changed files: path, status, additions, deletions -----------------------
FILES_TSV="$(gh api --paginate "repos/{owner}/{repo}/pulls/$PR/files" \
    --jq '.[] | [.filename, .status, .additions, .deletions] | @tsv' 2>/dev/null)" \
    || { echo "ERROR: couldn't list PR #$PR's changed files" >&2; exit 1; }
[ -n "$FILES_TSV" ] || { echo "ERROR: PR #$PR lists no changed files" >&2; exit 1; }

FLOOR=low
RULES=()
NOTES=()
raise() { # raise <level> <rule line>
    RULES+=("$2")
    [ "$(rank "$1")" -le "$(rank "$FLOOR")" ] || FLOOR="$1"
}
join_first() { # first 3 of stdin, "+N more" for the rest, comma separated
    awk 'NR<=3{a=a (NR>1?", ":"") $0} END{if(NR>3)a=a ", +" NR-3 " more"; print a}'
}

if rule_on migrations; then
    HITS="$(cut -f1 <<<"$FILES_TSV" | grep -E -- "$MIGRATION_RE" || true)"
    [ -z "$HITS" ] || raise medium "rule: migrations — touches a database migration ($(join_first <<<"$HITS"))"
fi
if rule_on sensitive; then
    HITS="$(cut -f1 <<<"$FILES_TSV" | grep -E -- "$SENSITIVE_RE" || true)"
    [ -z "$HITS" ] || raise medium "rule: sensitive — touches build, CI, container or auth/security config ($(join_first <<<"$HITS"))"
fi
if rule_on lines; then
    TOTAL="$(awk -F'\t' '{n+=$3+$4} END{print n+0}' <<<"$FILES_TSV")"
    [ "$TOTAL" -le "$MAX_LINES" ] || raise medium "rule: lines — $TOTAL lines changed, above the RISK_FLOOR_MAX_LINES limit of $MAX_LINES"
fi
if rule_on tests; then
    DELETED_TESTS="$(awk -F'\t' '$2=="removed"{print $1}' <<<"$FILES_TSV" | grep -E -- "$TEST_RE" || true)"
    [ -z "$DELETED_TESTS" ] || raise medium "rule: tests — deletes test files ($(join_first <<<"$DELETED_TESTS"))"
    DIFF="$(gh pr diff "$PR" 2>/dev/null)" || { echo "ERROR: couldn't read PR #$PR's diff" >&2; exit 1; }
    # added lines as "path<TAB>content"; the regex runs in grep, not awk, so
    # the user-supplied ERE means the same thing here as everywhere else
    SKIP_HITS="$(awk '/^\+\+\+ /{f=substr($0,7); next} /^\+/{print f "\t" substr($0,2)}' <<<"$DIFF" \
        | grep -E -- "$SKIP_RE" | cut -f1 | sort -u | grep -E -- "$TEST_RE" || true)"
    [ -z "$SKIP_HITS" ] || raise medium "rule: tests — adds a disabled/skipped test ($(join_first <<<"$SKIP_HITS"))"
fi
scope_mentions() { grep -qF -- "$1" <<<"$SCOPE_TEXT"; }
if rule_on scope; then
    SCOPE_TEXT=""
    if [ -n "${RISK_FLOOR_BRIEF:-}" ] && [ -r "$RISK_FLOOR_BRIEF" ]; then
        SCOPE_TEXT="$(cat "$RISK_FLOOR_BRIEF")"
    elif [ -n "${TASK_ID:-}" ]; then
        TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        for d in processing "done"; do
            if [ -n "$TOP" ] && [ -r "$TOP/.swarm/tasks/$d/$TASK_ID.md" ]; then
                SCOPE_TEXT="$(cat "$TOP/.swarm/tasks/$d/$TASK_ID.md")"; break
            fi
        done
    fi
    if [ -z "$SCOPE_TEXT" ]; then
        ISSUE="$(gh pr view "$PR" --json body --jq .body 2>/dev/null \
            | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | sed -n 1p | grep -oE '[0-9]+' || true)"
        [ -z "$ISSUE" ] || SCOPE_TEXT="$(gh issue view "$ISSUE" --json body --jq .body 2>/dev/null || true)"
    fi
    if [ -n "$SCOPE_TEXT" ]; then
        OUT=""
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            mentioned=0
            base="${path##*/}"
            if scope_mentions "$path" || scope_mentions "$base"; then
                mentioned=1
            else
                dir="$path"
                while [[ "$dir" == */* ]]; do
                    dir="${dir%/*}"
                    if scope_mentions "$dir/"; then mentioned=1; break; fi
                done
            fi
            [ "$mentioned" = 1 ] || OUT+="$path"$'\n'
        done < <(cut -f1 <<<"$FILES_TSV")
        OUT="${OUT%$'\n'}"
        [ -z "$OUT" ] || NOTES+=("note: scope — changed files under no path the brief/issue mentions ($(join_first <<<"$OUT")); advisory, no bump")
    fi
fi

echo "floor: $FLOOR"
if [ "${#RULES[@]}" -gt 0 ]; then printf '%s\n' "${RULES[@]}"; fi
if [ "${#NOTES[@]}" -gt 0 ]; then printf '%s\n' "${NOTES[@]}"; fi

[ "$APPLY" = 1 ] || exit 0

# --- --apply: enforce the floor on the PR -------------------------------------
BODY="$(gh pr view "$PR" --json body --jq .body 2>/dev/null)" \
    || { echo "ERROR: gh pr view $PR failed" >&2; exit 1; }
CUR="$(grep -oE '<!-- BLIND_MERGE_RISK: (low|medium|high) -->' <<<"$BODY" | sed -n 1p \
    | sed -E 's/.*: (low|medium|high) -->/\1/' || true)"
[ -n "$CUR" ] || CUR=medium   # a missing marker is already read as medium everywhere
if [ "$(rank "$CUR")" -ge "$(rank "$FLOOR")" ]; then
    exit 0
fi

NEW_BODY="$(sed -E "0,/<!-- BLIND_MERGE_RISK: $CUR -->/s//<!-- BLIND_MERGE_RISK: $FLOOR -->/" <<<"$BODY" \
    | sed -E "s/(Blind-merge risk:\*\*) $(emoji "$CUR") $CUR/\1 $(emoji "$FLOOR") $FLOOR/")"
gh pr edit "$PR" --body-file - <<<"$NEW_BODY" >/dev/null 2>&1 \
    || { echo "ERROR: couldn't bump PR #$PR's rating marker" >&2; exit 1; }

HEAD_SHA="$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
TAG="<!-- SWARM_RISK_FLOOR: $FLOOR head=${HEAD_SHA:-unknown} -->"
SEEN="$(gh pr view "$PR" --json comments --jq "[.comments[].body // \"\" | select(contains(\"SWARM_RISK_FLOOR: $FLOOR head=${HEAD_SHA:-unknown} \"))] | length" 2>/dev/null || echo 0)"
if [ "${SEEN:-0}" = "0" ]; then
    COMMENT="$(printf '%s\n**Rating raised from %s %s to %s %s** — the diff trips a risk-floor rule, so a lower rating is not allowed:\n\n%s\n\n<sub>scripts/risk-floor.sh (issue #731). Settings: RISK_FLOOR_* in .env.example.</sub>\n' \
        "$TAG" "$(emoji "$CUR")" "$CUR" "$(emoji "$FLOOR")" "$FLOOR" \
        "$(printf '%s\n' "${RULES[@]}" ${NOTES[@]+"${NOTES[@]}"} | sed 's/^/- /')")"
    gh pr comment "$PR" --body-file - <<<"$COMMENT" >/dev/null 2>&1 \
        || echo "WARN: marker bumped but the explanatory comment failed to post" >&2
fi
echo "bumped: $CUR -> $FLOOR"
exit 10
