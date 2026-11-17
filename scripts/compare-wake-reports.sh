#!/usr/bin/env bash
#
# compare-wake-reports.sh — weekly comparison of the Claude Code coordinator's
# wake reports with the corpusminder shadow coordinator's (issue #863, stage B2).
#
# Usage: compare-wake-reports.sh --shadow-dir DIR [--claude-dir DIR] [--project DIR]
#                                [--since DAYS] [--json]
#
# Each directory holds one report per triggering event: <trigger>.md, plus an
# optional <trigger>.meta.json whose cost_usd is the cost recorded for producing
# it. <trigger> is the first coord-inbox item name the wake covered, without
# ".md" (the same key the inbox event carries to the forum). Reports are paired
# by that name; each is scored by score-wake-report.sh.
#
#   --claude-dir   default <project>/.swarm/coordinator-reports, written by
#                  coord-report-record.sh when CMINDER_EVENTS=1 (the same reports
#                  go to the forum as coordinator_report events).
#   --shadow-dir   the shadow's reports exported as above. Required: the forum
#                  endpoint that serves them is corpusminder-spring #2221's.
#   --since DAYS   only reports modified in the last DAYS days (default 7).
#   --json         machine output instead of the text summary.
#
# Prints per-pair scores side by side (and the shadow's recorded cost), the average
# over pairs, and how many reports had no partner. Exit 0 (also when nothing
# pairs: that is an answer), 2 on usage error.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"; CDIR=""; SDIR=""; SINCE=7; JSON=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --project) [ $# -ge 2 ] || { echo "--project needs a value" >&2; exit 2; }; PROJECT="$2"; shift 2 ;;
        --claude-dir) [ $# -ge 2 ] || { echo "--claude-dir needs a value" >&2; exit 2; }; CDIR="$2"; shift 2 ;;
        --shadow-dir) [ $# -ge 2 ] || { echo "--shadow-dir needs a value" >&2; exit 2; }; SDIR="$2"; shift 2 ;;
        --since) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "--since needs a number of days" >&2; exit 2; }; SINCE="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$CDIR" ] || CDIR="$PROJECT/.swarm/coordinator-reports"
[ -n "$SDIR" ] || { echo "Usage: $0 --shadow-dir DIR [--claude-dir DIR] [--since DAYS] [--json]" >&2; exit 2; }
[ -d "$CDIR" ] || { echo "compare-wake-reports: no such directory $CDIR" >&2; exit 2; }
[ -d "$SDIR" ] || { echo "compare-wake-reports: no such directory $SDIR" >&2; exit 2; }
command -v jq >/dev/null || { echo "compare-wake-reports: jq required" >&2; exit 2; }

# side <dir> -> JSON object {trigger: {score, cost_usd}} for reports in the window.
side() {
    local dir="$1" f key score cost out="{}"
    while IFS= read -r f; do
        key="$(basename "$f" .md)"
        score="$("$HERE/score-wake-report.sh" "$f" | jq -c '{score,passed,total,failed:[.checks[]|select(.pass|not)|.id]}')" || continue
        cost="$(jq -r '.cost_usd // empty' "${f%.md}.meta.json" 2>/dev/null || true)"
        out="$(jq -c --arg k "$key" --argjson s "$score" --arg c "$cost" \
            '. + {($k): ($s + (if $c != "" then {cost_usd: ($c|tonumber)} else {} end))}' <<<"$out")"
    done < <(find "$dir" -maxdepth 1 -name '*.md' -type f -mtime "-$SINCE" | sort)
    printf '%s' "$out"
}
C="$(side "$CDIR")"; S="$(side "$SDIR")"

RESULT="$(jq -n --argjson c "$C" --argjson s "$S" --argjson since "$SINCE" '
    ([$c, $s] | map(keys) | add | unique) as $all
    | [$all[] | select(($c[.]) and ($s[.]))] as $paired
    | def avg(p): if length == 0 then null else ((((add / length) * p) | round) / p) end;
    { since_days: $since,
      pairs: [$paired[] | {trigger: ., claude: $c[.], shadow: $s[.], delta: ($s[.].score - $c[.].score)}],
      claude_only: [$all[] | select($c[.] and ($s[.] | not))],
      shadow_only: [$all[] | select($s[.] and ($c[.] | not))],
      average: { claude: ([$paired[] | $c[.].score] | avg(10)),
                 shadow: ([$paired[] | $s[.].score] | avg(10)),
                 shadow_cost_usd: ([$paired[] | $s[.].cost_usd | select(. != null)] | avg(10000)) } }')"

if [ -n "$JSON" ]; then printf '%s\n' "$RESULT"; exit 0; fi

jq -r '"Wake reports, last \(.since_days) days: \(.pairs | length) pair(s), \(.claude_only | length) Claude-only, \(.shadow_only | length) shadow-only"' <<<"$RESULT"
if [ "$(jq '.pairs | length' <<<"$RESULT")" = 0 ]; then echo "Nothing paired yet."; exit 0; fi
echo
jq -r '(["trigger", "claude", "shadow", "delta", "shadow_cost_usd", "shadow_missed"] | @tsv),
    (.pairs[] | [.trigger, .claude.score, .shadow.score, (if .delta > 0 then "+\(.delta)" else "\(.delta)" end),
                 (.shadow.cost_usd // "-"), (.shadow.failed | join(",") | if . == "" then "-" else . end)] | @tsv)' <<<"$RESULT" \
    | column -t -s "$(printf '\t')"
echo
jq -r '"average: claude \(.average.claude), shadow \(.average.shadow), shadow cost per report \(.average.shadow_cost_usd // "not recorded") USD"' <<<"$RESULT"
