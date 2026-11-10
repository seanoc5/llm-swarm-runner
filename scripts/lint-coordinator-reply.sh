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
# Exit 0 clean, 3 hits (printed to stdout), 2 usage error. Naive on purpose:
# a regex that catches the real incident beats a perfect check nobody runs.
# Fixtures: tests/fixtures/reply-lint/.
set -uo pipefail

if [ $# -gt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
    [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && exit 0
    exit 2
fi
if [ $# -eq 1 ]; then
    [ -r "$1" ] || { echo "cannot read $1" >&2; exit 2; }
    text="$(cat "$1")"
else
    text="$(cat)"
fi

printf '%s\n' "$text" | awk '
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
    exit (n > 0 ? 3 : 0)
}'
