#!/usr/bin/env bash
#
# lint-coordinator-reply.sh — deterministic check on a coordinator's reply
# (issue #798, ADR 0007). Reads the reply on stdin (or a file argument).
#
# Rules (a rule name per hit; a hit prints "<rule>: <offending line>"):
#   backref      an action item points the operator at text that is not on the
#                screen: "command above", "from my last message", "as before",
#                "see earlier", "in my previous", "details in .swarm/needs-you.md".
#   no-command   a Needs-you item (a "- **A1**" bullet and its continuation
#                lines) says run/start/copy/click/type/paste/execute/open but
#                carries no fenced block, `code span` or https URL.
#   two-endings  the reply has two closing lines: "Nothing to do" /
#                "Nothing needed ..." together with "Do now:", or two of "Do now:" /
#                "Pending your approval:" / nothing-lines (#801 fixture).
#
#   stale-window an item sends the operator to type something "in its worker
#                window" / "in its iss-N pane" for a PR or issue whose worker is
#                on hold (sidelined: no window exists; issue #841). Needs
#                --project DIR; without one this rule
#                is skipped. A worker counts as on hold when its worktree has
#                .swarm/sidelined; a PR maps to its worker through the "pr" in
#                the worktree's .swarm/tasks/status/*.json. Right wording: type
#                the phrase in the coordinator.
#
# Usage: lint-coordinator-reply.sh [--project DIR] [file]
# Exit 0 clean, 3 hits (printed to stdout), 2 usage error. Naive on purpose:
# a regex that catches the real incident beats a perfect check nobody runs.
# Fixtures: tests/fixtures/reply-lint/.
set -uo pipefail

PROJECT=""; FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --project) [ $# -ge 2 ] || { echo "--project needs a value" >&2; exit 2; }; PROJECT="$2"; shift 2 ;;
        --project=*) PROJECT="${1#*=}"; shift ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) [ -z "$FILE" ] || exit 2; FILE="$1"; shift ;;
    esac
done
if [ -n "$FILE" ]; then
    [ -r "$FILE" ] || { echo "cannot read $FILE" >&2; exit 2; }
    text="$(cat "$FILE")"
else
    text="$(cat)"
fi

hits="$(printf '%s\n' "$text" | awk '
function flush_item(   hit) {
    if (item != "" && tolower(item) ~ verbs && item !~ cmd) {
        hits[++n] = "no-command: " first
    }
    item = ""; first = ""
}
BEGIN {
    back = "(command|commands|step|steps|link|url|snippet|block)s? above|from my (last|previous|earlier) (message|reply)|as (before|above)|see (earlier|above|my (last|previous))|in my (previous|last|earlier)|details in [`]?\\.swarm/needs-you\\.md"
    verbs = "(^|[^a-z])(run|start|copy|click|type|paste|execute|open)([^a-z]|$)"
    cmd = "```|`[^`]+`|https://"
    nothing = "^[[:space:]]*(nothing to do|nothing needed|nothing is needed|nothing needed from you)"
    dono = "^[[:space:]]*(\\*\\*)?do now(\\*\\*)?:"
    pend = "^[[:space:]]*(\\*\\*)?pending your approval(\\*\\*)?:"
    infence = 0; item = ""; first = ""; n = 0; nn = 0; nd = 0; np = 0
}
{
    line = $0; l = tolower(line)
    if (line ~ /^[[:space:]]*```/) {
        infence = !infence
        if (item != "") item = item "\n" line
        next
    }
    if (infence) { if (item != "") item = item "\n" line; next }
    if (l ~ back) hits[++n] = "backref: " line
    if (line ~ /^[[:space:]]*-[[:space:]]+\*\*[A-Za-z][0-9]+\*\*/) {
        flush_item(); item = line; first = line
    } else if (item != "") {
        if (line ~ /^[[:space:]]*$/ || line ~ /^(#|\*\*)/ ) flush_item()
        else item = item "\n" line
    }
    if (l ~ nothing) nn++
    if (l ~ dono) nd++
    if (l ~ pend) np++
}
END {
    flush_item()
    if (nn + nd + np >= 2) hits[++n] = "two-endings: " nn " nothing-line(s), " nd " Do now, " np " Pending your approval"
    for (i = 1; i <= n; i++) print hits[i]
}')"

# stale-window (issue #841): needs the project's worktrees, so it is a bash pass.
stale_window_hits() {
    [ -n "$PROJECT" ] && [ -d "$PROJECT" ] || return 0
    local self_dir lister wt issue f p
    local -A hold_issue=() hold_pr=()
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    lister="$self_dir/list-own-worktrees.sh"
    while IFS= read -r wt; do
        [ -n "$wt" ] && [ -e "$wt/.swarm/sidelined" ] || continue
        issue="$(basename "$wt")"; issue="${issue#wt-issue-}"
        hold_issue[$issue]=1
        for f in "$wt"/.swarm/tasks/status/*.json "$wt"/.swarm/tasks/done/*.json; do
            [ -e "$f" ] || continue
            p="$(jq -r '.pr // empty' "$f" 2>/dev/null)"
            [[ "$p" =~ ^[0-9]+$ ]] && hold_pr[$p]=1
        done
    done < <("$lister" "$PROJECT" 2>/dev/null)
    [ "${#hold_issue[@]}" -gt 0 ] || return 0
    local block n
    while IFS= read -r block; do
        printf '%s' "$block" | tr 'A-Z' 'a-z' \
            | grep -E "(in|into) (its|the|that|their) ((iss-[0-9]+|worker|worker.s) )*(window|pane)" >/dev/null || continue
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            if [ -n "${hold_pr[$n]:-}" ] || [ -n "${hold_issue[$n]:-}" ]; then
                echo "stale-window: ${block:0:200}"; break
            fi
        done < <(printf '%s' "$block" | grep -oiE '(PR[ #/]*|pull/|iss-|#)[0-9]+' | grep -oE '[0-9]+')
    done < <(printf '%s\n' "$text" | awk '
        function out() { if (b != "") print b; b = "" }
        /^[[:space:]]*-[[:space:]]+\*\*[A-Za-z][0-9]+\*\*/ { out(); b = $0; next }
        /^[[:space:]]*$/ || /^(#|\*\*)/ { out(); next }
        { if (b != "" && $0 ~ /^[[:space:]]/) b = b " " $0; else { out(); b = $0 } }
        END { out() }')
}
stale="$(stale_window_hits)"
all="$(printf '%s\n%s\n' "$hits" "$stale" | sed '/^$/d')"
[ -z "$all" ] && exit 0
printf '%s\n' "$all"
exit 3
