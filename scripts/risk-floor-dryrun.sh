#!/usr/bin/env bash
#
# risk-floor-dryrun.sh — which recently merged 🟢 PRs would risk-floor.sh have
# bumped? (issue #731). Read-only: runs risk-floor.sh WITHOUT --apply against
# each PR, so nothing on GitHub changes.
#
# Usage: risk-floor-dryrun.sh <owner/repo> [count]     (default 30)
#
# Takes the most recent <count> merged PRs whose body's first
# BLIND_MERGE_RISK marker is low, and prints one TSV row per PR:
#   <PR#>  <floor>  <rules fired, "; "-separated>  <title>
# then a summary line. RISK_FLOOR_* settings apply as usual.
set -euo pipefail
REPO="${1:?usage: risk-floor-dryrun.sh <owner/repo> [count]}"
COUNT="${2:-30}"
case "$COUNT" in ''|*[!0-9]*) echo "ERROR: count must be a number" >&2; exit 1 ;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull a generous page of merged PRs, keep the 🟢 ones. gh's --limit applies
# before the jq filter, so over-fetch.
PRS="$(gh pr list --repo "$REPO" --state merged --limit $((COUNT * 6)) --json number,title,body \
    --jq '[.[] | select((.body // "" | split("\n") | map(select(contains("BLIND_MERGE_RISK"))) | .[0] // "") | test("BLIND_MERGE_RISK: low"))] | .[] | [.number, .title] | @tsv')"
PRS="$(head -n "$COUNT" <<<"$PRS")"

total=0; bumped=0
while IFS=$'\t' read -r num title; do
    [ -n "$num" ] || continue
    total=$((total + 1))
    rc=0
    out="$(GH_REPO="$REPO" "$SCRIPT_DIR/risk-floor.sh" "$num" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\t%s\t%s\t%s\n' "$num" "error" "$(tr '\n' ' ' <<<"$out")" "$title"
        continue
    fi
    floor="$(sed -n 's/^floor: //p' <<<"$out")"
    rules="$(sed -n 's/^rule: //p' <<<"$out" | paste -sd';' - | sed 's/;/; /g')"
    [ "$floor" = low ] || bumped=$((bumped + 1))
    printf '%s\t%s\t%s\t%s\n' "$num" "$floor" "$rules" "$title"
done <<<"$PRS"
echo "summary: $bumped of $total merged 🟢 PRs in $REPO would have been bumped"
