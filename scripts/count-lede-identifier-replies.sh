#!/usr/bin/env bash
#
# count-lede-identifier-replies.sh — issue #979 measurement: how many assistant replies
# in saved Claude Code transcripts lead with an identifier (the lede-identifier rule of
# lint-coordinator-reply.sh, the same check the Stop hook uses).
#
# Usage: count-lede-identifier-replies.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] DIR...
#   DIR  directory searched recursively for *.jsonl transcripts
#        (e.g. /opt/work/backups/claude-archive, ~/.claude/projects; pass the dir itself, find uses -type f)
# Output: one line "replies=<N> lede=<M> pct=<P>" (a reply = one assistant text record).
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
total=0; hit=0
while IFS= read -r -d '' f; do
    # One NUL-free base64 line per assistant record inside the date window.
    while IFS= read -r b64; do
        text="$(printf '%s' "$b64" | base64 -d)"
        total=$((total + 1))
        [ -n "$("$lint" --only lede-identifier <<<"$text" 2>/dev/null)" ] && hit=$((hit + 1))
    done < <(jq -r --arg s "$since" --arg u "$until" '
        select(.type=="assistant") | select((.timestamp // "")[0:10] as $d | $d >= $s and $d <= $u)
        | [.message.content[]? | select(.type=="text") | .text] | join("\n") | select(length>0) | @base64' "$f" 2>/dev/null)
done < <(find "${dirs[@]}" -name '*.jsonl' -type f -print0 2>/dev/null)
pct=0; [ "$total" -gt 0 ] && pct=$(awk -v b="$hit" -v t="$total" 'BEGIN{printf "%.1f", 100*b/t}')
echo "replies=$total lede=$hit pct=$pct"
