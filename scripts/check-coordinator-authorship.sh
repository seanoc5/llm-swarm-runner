#!/usr/bin/env bash
#
# check-coordinator-authorship.sh — Gate 0 of the coordinator auto-merge
# path (#452, carved from #450 finding 4): the coordinator must never
# auto-merge a PR it authored itself. corpusminder-spring PR #713 was
# coordinator-authored and coordinator-merged 10 seconds after its CI run
# *started* — the documented "CI green" gate was assumed via `gh pr merge
# --auto` plus branch protection that doesn't exist on these private repos,
# and nothing checked authorship at all.
#
# A coordinator-authored commit (e.g. a mechanical Flyway/Alembic renumber,
# see prompts/coordinator.md "Post-merge migration-collision watchdog")
# carries a `Swarm-Role: coordinator` git trailer. This script refuses any
# PR whose head carries at least one such commit relative to its base —
# regardless of who currently shows up as the GitHub PR author, so it keeps
# working unmodified once the coordinator gets its own bot identity (#450).
#
# Usage:
#   check-coordinator-authorship.sh <PR#>
#
# Exit codes:
#   0  clean — no head-only commit carries a Swarm-Role: coordinator trailer
#   1  refused — at least one head-only commit carries the trailer
#   2  error (gh/git failure, bad args) — fail closed: treat as not eligible
#
# There is no override flag. Unlike the migration-collision and self-review
# gates, this one is not meant to be bypassed by an operator in a hurry —
# "coordinator-authored PRs always go to the operator" is the whole point.
# A human who has actually looked at the diff can still merge it by hand
# with `gh pr merge` or a plain `swarm-merge.sh <N>` (no --auto-low); this
# gate only guards the *unattended* auto-merge path.
set -euo pipefail

TRAILER_KEY="Swarm-Role"
TRAILER_VALUE="coordinator"

PR="${1:-}"
[ -n "$PR" ] || { echo "Usage: $0 <PR#>" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

PR_JSON="$(gh pr view "$PR" --json baseRefName,headRefName 2>&1)" \
    || { echo "ERROR: gh pr view $PR failed: $PR_JSON" >&2; exit 2; }

BASE_REF="$(jq -r '.baseRefName' <<<"$PR_JSON")"
HEAD_REF="$(jq -r '.headRefName' <<<"$PR_JSON")"
[ -n "$BASE_REF" ] && [ "$BASE_REF" != "null" ] || { echo "ERROR: could not resolve base ref for PR #$PR" >&2; exit 2; }
[ -n "$HEAD_REF" ] && [ "$HEAD_REF" != "null" ] || { echo "ERROR: could not resolve head ref for PR #$PR" >&2; exit 2; }

BASE_LOCAL="refs/check-coordinator-authorship/base-$$"
HEAD_LOCAL="refs/check-coordinator-authorship/head-$$"
cleanup() {
    git update-ref -d "$BASE_LOCAL" >/dev/null 2>&1 || true
    git update-ref -d "$HEAD_LOCAL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git fetch -q origin "$BASE_REF:$BASE_LOCAL" "$HEAD_REF:$HEAD_LOCAL" \
    || { echo "ERROR: git fetch of $BASE_REF/$HEAD_REF failed" >&2; exit 2; }

# Check each head-only commit's trailer individually rather than one bulk
# --format scan — keeps the per-commit sha/subject available for the
# refusal message without a second, differently-shaped git invocation.
HIT_SHAS=""
while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # A commit can carry the same trailer key more than once, in which case
    # `valueonly` emits one line per occurrence — match any line, not the
    # whole (possibly multi-line) string.
    val="$(git log -1 --format="%(trailers:key=${TRAILER_KEY},valueonly)" "$sha")"
    if grep -qx "$TRAILER_VALUE" <<<"$val"; then
        HIT_SHAS+="$(git log -1 --format='  %h %s' "$sha")"$'\n'
    fi
done < <(git rev-list "${BASE_LOCAL}..${HEAD_LOCAL}")

if [ -n "$HIT_SHAS" ]; then
    echo "REFUSED (Gate 0 — authorship): PR #$PR carries at least one commit with a" >&2
    echo "  '${TRAILER_KEY}: ${TRAILER_VALUE}' trailer — the coordinator never auto-merges" >&2
    echo "  a PR it authored. This PR must go to the operator." >&2
    echo "  Coordinator-authored commit(s):" >&2
    printf '%s' "$HIT_SHAS" >&2
    exit 1
fi

echo "Gate 0 (authorship): clean — no ${TRAILER_KEY}: ${TRAILER_VALUE} trailer on PR #$PR's head commits ($BASE_REF..$HEAD_REF)."
exit 0
