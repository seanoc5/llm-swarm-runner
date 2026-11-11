#!/usr/bin/env bash
# Adapter: scripts/lint-brief.sh "lint-brief: WARN <id>: <msg>" -> JSON lines (warn).
# Checks: no-done-definition, check-cannot-fail, no-named-files, underspecified.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../_lib.sh"
out="$("$HERE/../../lint-brief.sh" "$1")" || exit $?
while IFS= read -r l; do
    case "$l" in "lint-brief: WARN "*) ;; *) continue ;; esac
    rest="${l#lint-brief: WARN }"
    emit "${rest%%: *}" warn 0 "" "${rest#*: }"
done <<<"$out"
exit 0
