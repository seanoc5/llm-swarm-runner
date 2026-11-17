#!/usr/bin/env bash
#
# coord-report-record.sh — keep the coordinator's wake report for the forum mirror
# (issue #863, stage B2 of the coordinator-in-corpusminder experiment).
#
#   coord-report-record.sh [--project DIR] < reply text
#
# Called by coord-hook.sh at Stop with the coordinator's accepted reply. A reply is
# a wake report when a doorbell rang after the previous recorded report
# (coord-hook-rang / coord-typed-ring newer than .swarm/coord-report-last); any
# other reply (the operator typed it, a lint-blocked draft) is ignored. The report
# is written to <project>/.swarm/coordinator-reports/<trigger>.md with a
# <trigger>.meta.json beside it; cminder-events.sh sweep posts each one as a
# coordinator_report swarm event. <trigger> is the first coord-inbox item (inbox
# or processed/) that arrived since the previous report, without ".md" (the same
# key the inbox event carries), else "ring-<epoch>".
#
# Opt-in like the rest of the mirror: does nothing unless NEEDS_YOU_BACKEND=corpusminder
# and CMINDER_EVENTS=1. Local file writes only, no network, so the hook never waits
# on corpusminder. Always exits 0.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

project="${CLAUDE_PROJECT_DIR:-$PWD}"
while [ $# -gt 0 ]; do
    case "$1" in --project) project="${2-}"; shift 2 ;; *) shift ;; esac
done
project="$(cd "$project" 2>/dev/null && pwd)" || exit 0
# shellcheck source=scripts/_load-env.sh
. "$SELF_DIR/_load-env.sh" "$project" 2>/dev/null || true
[ "${CMINDER_EVENTS:-0}" = 1 ] && [ "${NEEDS_YOU_BACKEND:-file}" = corpusminder ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=scripts/_coord-inbox-batch.sh
. "$SELF_DIR/_coord-inbox-batch.sh" 2>/dev/null || exit 0

swarm="$project/.swarm"
[ -d "$swarm" ] || exit 0
reply="$(cat)"
[[ "$reply" =~ [^[:space:]] ]] || exit 0

now="$(date +%s)"
ring="$(coord_last_ring_at "$swarm")"
prev="$(cat "$swarm/coord-report-last" 2>/dev/null || echo 0)"
[[ "$prev" =~ ^[0-9]+$ ]] || prev=0
[ "$ring" -gt "$prev" ] || exit 0          # no doorbell since the last report: not a wake report

# Items that arrived since the previous report (never older than a day before the ring).
since=$(( prev > ring - 86400 ? prev : ring - 86400 ))
inbox="${COORD_INBOX_DIR:-$swarm/coord-inbox}"
triggers=()
# Oldest first by name (names start with a UTC timestamp).
for d in "$inbox" "$inbox/processed"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -name '*.md' -type f -newermt "@$since" -printf '%f\n' 2>/dev/null
done | sed 's/\.md$//' | sort -u | head -n 20 > "$swarm/.coord-report-triggers.tmp"
mapfile -t triggers < "$swarm/.coord-report-triggers.tmp"; rm -f "$swarm/.coord-report-triggers.tmp"
if [ "${#triggers[@]}" -gt 0 ]; then
    key="${triggers[0]}"
else
    key="ring-$ring"
fi
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"

out="$swarm/coordinator-reports"
mkdir -p "$out" || exit 0
f="$out/$safe.md"; n=1
while [ -e "$f" ]; do n=$((n + 1)); f="$out/$safe-$n.md"; done   # a second report for the same trigger keeps its own file
tmp="$(mktemp "$out/.tmp.XXXXXX")" || exit 0
printf '%s\n' "$reply" > "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; exit 0; }
tj="$(printf '%s\n' "${triggers[@]:-}" | jq -R . | jq -sc 'map(select(. != ""))')"
jq -nc --arg t "$key" --argjson tr "$tj" --argjson ring "$ring" --argjson at "$now" \
    '{trigger:$t, triggers:$tr, ring_epoch:$ring, recorded_epoch:$at}' > "${f%.md}.meta.json" 2>/dev/null || true
printf '%s\n' "$now" > "$swarm/coord-report-last"
find "$out" -type f -mtime +14 -delete 2>/dev/null || true
exit 0
