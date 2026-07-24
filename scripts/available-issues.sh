#!/usr/bin/env bash
#
# available-issues.sh — gh-level filter for "issues a worker could pick up".
#
# Implements the mechanical half of the AVAILABLE computation defined in
# prompts/coordinator.md ("Computing AVAILABLE"): stop-labels, owner-labels,
# and assignee scoping. The judgment half (tracking/meta issues, policy-blocked,
# PR-already-linked, pre-baked epic decompositions) stays with the coordinator.
#
# Env:
#   OWNER_LABELS                comma-separated labels treated as "owned by a
#                               human"; each is excluded unless it equals the
#                               authenticated gh login
#   INCLUDE_ASSIGNED_TO_OTHERS  1 = any assignee (still minus stop/owner
#                               labels); default scopes to @me or unassigned
#
# Output: JSON array of {number,title,assignees,labels}, deduped by number.
#
# Exit:
#   0  ok (empty array is a valid answer)
#   *  gh/jq failure passed through

set -euo pipefail

ME=$(gh api user --jq .login)

SEARCH="-label:blocked -label:deferred -label:awaiting-review"

if [ -n "${OWNER_LABELS:-}" ]; then
    IFS=',' read -ra _labels <<< "$OWNER_LABELS"
    for L in "${_labels[@]}"; do
        L="${L// /}"
        [ -z "$L" ] && continue
        # A label matching our own login is not a stop signal for us.
        [ "$L" = "$ME" ] || SEARCH="$SEARCH -label:$L"
    done
fi

FIELDS="number,title,assignees,labels"

if [ "${INCLUDE_ASSIGNED_TO_OTHERS:-0}" = "1" ]; then
    gh issue list --state open --search "$SEARCH" --limit 100 --json "$FIELDS"
else
    # Union of assigned-to-me and unassigned, deduped by issue number.
    {
        gh issue list --state open --assignee "$ME" --search "$SEARCH" \
            --limit 100 --json "$FIELDS"
        gh issue list --state open --search "no:assignee $SEARCH" \
            --limit 100 --json "$FIELDS"
    } | jq -s 'add | unique_by(.number)'
fi
