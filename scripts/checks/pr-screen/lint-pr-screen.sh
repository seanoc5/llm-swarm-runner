#!/usr/bin/env bash
# Adapter: scripts/lint-pr-screen.sh "lint-pr-screen: FAIL <id>: <msg>" -> JSON lines (error).
# Checks: identifiers-above-fold, bottom-line-budget, surprise-budget,
# your-move-budget, recommendation-in-table, screen-too-long.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../_lib.sh"
out="$("$HERE/../../lint-pr-screen.sh" --file "$1" 2>/dev/null)"; ec=$?
[ "$ec" -eq 0 ] || [ "$ec" -eq 3 ] || exit "$ec"
while IFS= read -r l; do
    case "$l" in "lint-pr-screen: FAIL "*) ;; *) continue ;; esac
    rest="${l#lint-pr-screen: FAIL }"
    emit "${rest%%: *}" error 0 "" "${rest#*: }"
done <<<"$out"
exit 0
