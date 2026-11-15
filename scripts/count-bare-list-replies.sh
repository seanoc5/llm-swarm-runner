#!/usr/bin/env bash
#
# count-bare-list-replies.sh — issue #800 measurement: how many assistant replies
# in saved Claude Code transcripts contain a bare "1." list (the bare-list rule of
# lint-coordinator-reply.sh, the same check the Stop hook uses).
#
# Usage: count-bare-list-replies.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] DIR...
#   DIR  directory searched recursively for *.jsonl transcripts
#        (e.g. /opt/work/backups/claude-archive, ~/.claude/projects)
# Output: one line "replies=<N> bare=<M> pct=<P>" (a reply = one assistant text record).
# Compare a run before the hook was installed with one two weeks after.
set -uo pipefail
since="0000-00-00"; until="9999-99-99"; dirs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --since) since="${2:?--since needs a date}"; shift 2 ;;
        --until) until="${2:?--until needs a date}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) dirs+=("$1"); shift ;;
    esac
done
[ "${#dirs[@]}" -gt 0 ] || { echo "usage: $0 [--since D] [--until D] DIR..." >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
lint="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lint-coordinator-reply.sh"
total=0; bare=0
while IFS= read -r -d '' f; do
    # One NUL-free base64 line per assistant record inside the date window.
    while IFS= read -r b64; do
        text="$(printf '%s' "$b64" | base64 -d)"
        total=$((total + 1))
        # Cheap pre-filter; the lint decides (it skips fenced code).
        grep -qE '^[[:space:]]*[0-9]+[.)][[:space:]]' <<<"$text" || continue
        [ -n "$("$lint" --only bare-list <<<"$text" 2>/dev/null)" ] && bare=$((bare + 1))
    done < <(jq -r --arg s "$since" --arg u "$until" '
        select(.type=="assistant") | select((.timestamp // "")[0:10] as $d | $d >= $s and $d <= $u)
        | [.message.content[]? | select(.type=="text") | .text] | join("\n") | select(length>0) | @base64' "$f" 2>/dev/null)
done < <(find "${dirs[@]}" -name '*.jsonl' -type f -print0 2>/dev/null)
pct=0; [ "$total" -gt 0 ] && pct=$(awk -v b="$bare" -v t="$total" 'BEGIN{printf "%.1f", 100*b/t}')
echo "replies=$total bare=$bare pct=$pct"
