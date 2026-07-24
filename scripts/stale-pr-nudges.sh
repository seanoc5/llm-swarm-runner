#!/usr/bin/env bash
#
# stale-pr-nudges.sh — read-only detector for swarm PRs that need a
# "re-entry" refresh comment.
#
# A PR qualifies when ALL hold:
#   - open, not a draft
#   - body carries the swarm BLIND_MERGE_RISK marker (i.e. it's a swarm PR)
#   - no activity (updatedAt) for STALE_PR_NUDGE_HOURS hours
#   - the last nudge comment (marker SWARM_STALE_NUDGE) is NOT the most
#     recent word on the PR — i.e. a commit landed after the last nudge, or
#     no nudge was ever posted. This suppresses repeat nudges: one nudge per
#     activity cycle, not one per interval.
#
# The coordinator posts the actual comment (a plain-language recap + whose
# move it is), including the literal marker `<!-- SWARM_STALE_NUDGE -->` so
# this script can see it next time. This script never writes anything.
#
# Env:
#   STALE_PR_NUDGE_HOURS   staleness threshold in hours (default 6; 0 = off)
#
# Output: one compact JSON object per line: {number, title, updatedAt}.
# Empty output = nothing to nudge.
#
# Exit: 0 ok; gh/jq failures pass through.

set -euo pipefail

THRESH_HOURS="${STALE_PR_NUDGE_HOURS:-6}"
if [ "$THRESH_HOURS" = "0" ]; then
    exit 0
fi

NOW="$(date -u +%s)"
CUTOFF=$((NOW - THRESH_HOURS * 3600))

CANDIDATES="$(gh pr list --state open --limit 50 \
    --json number,title,isDraft,updatedAt,body |
    jq -c --argjson cutoff "$CUTOFF" '
        .[]
        | select(.isDraft | not)
        | select(.body | test("BLIND_MERGE_RISK"))
        | select((.updatedAt | fromdateiso8601) < $cutoff)
        | {number, title, updatedAt}')"

[ -n "$CANDIDATES" ] || exit 0

while IFS= read -r pr; do
    num="$(jq -r .number <<<"$pr")"

    last_nudge="$(gh pr view "$num" --json comments --jq \
        '[.comments[] | select(.body | test("SWARM_STALE_NUDGE"))] | last | .createdAt // empty')"

    if [ -n "$last_nudge" ]; then
        last_commit="$(gh pr view "$num" --json commits --jq \
            '.commits | last | .committedDate // empty')"
        nudge_epoch="$(date -u -d "$last_nudge" +%s)"
        commit_epoch="$(date -u -d "${last_commit:-1970-01-01T00:00:00Z}" +%s)"
        # Nudge is still the latest word — nothing changed since; skip.
        [ "$nudge_epoch" -ge "$commit_epoch" ] && continue
    fi

    echo "$pr"
done <<<"$CANDIDATES"
