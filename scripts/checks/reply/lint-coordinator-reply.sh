#!/usr/bin/env bash
# Adapter: scripts/lint-coordinator-reply.sh text hits -> JSON lines.
# Checks: backref, no-command, two-endings, stale-window (needs CHECKS_PROJECT=DIR).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../_lib.sh"
FILE="$1"
args=(); [ -n "${CHECKS_PROJECT:-}" ] && args=(--project "$CHECKS_PROJECT")
out="$("$HERE/../../lint-coordinator-reply.sh" "${args[@]}" "$FILE")"; ec=$?
[ "$ec" -eq 0 ] || [ "$ec" -eq 3 ] || exit "$ec"
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    id="${hit%%: *}"; text="${hit#*: }"
    case "$id" in
        backref) msg="action points at text that is not on the screen; repeat it inline" ;;
        no-command) msg="action item says run/click/type but carries no command, code span or URL" ;;
        two-endings) msg="reply has more than one closing line; end with exactly one" ;;
        stale-window) msg="sends the operator to a worker window that does not exist (on hold); use the coordinator" ;;
        *) msg="see scripts/lint-coordinator-reply.sh" ;;
    esac
    emit "$id" error "$(find_line "$FILE" "$text")" "$text" "$msg"
done <<<"$out"
exit 0
