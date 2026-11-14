#!/usr/bin/env bash
#
# eval-carryover-lint.sh — recall and false-positive rate of the `carryover`
# rule in lint-coordinator-reply.sh (issue #646), the evaluation shape of
# docs/grokkability-evaluation.md: a known-bad fixture plus a clean-by-default sample.
#
# Usage: eval-carryover-lint.sh [--transcripts DIR] [--skip-dates D1,D2] [--min-words N]
#   Recall: scores tests/fixtures/reply-lint/carryover-incidents.tsv (13 rows from
#     docs/research/issue-645-reporting-rules.md section 2) with the carryover and backref rules.
#   False positives (only with --transcripts): every assistant text reply in DIR/*.jsonl
#     (a Claude Code project dir) is linted; dates in --skip-dates (the days the operator
#     complained) are left out. Prints the flag rate overall and for replies of at least
#     --min-words (default 60) words, and the flagged lines to stdout so a human can label them.
# Reads local transcripts only; nothing is written or sent anywhere. Needs jq.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/lint-coordinator-reply.sh"; FX="$HERE/../tests/fixtures/reply-lint/carryover-incidents.tsv"
DIR=""; SKIP=""; MINW=60
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --transcripts) DIR="${2:-}"; shift 2 ;;
        --skip-dates) SKIP=",${2:-},"; shift 2 ;;
        --min-words) MINW="${2:-60}"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
tp=0; fn=0; fp_fix=0; rows=0
while IFS=$'\t' read -r row date proj expect text; do
    case "$row" in ''|'#'*) continue ;; esac
    rows=$((rows + 1))
    out="$(printf '%s\n' "$text" | "$LINT" --only carryover,backref)"; hit="${out%%$'\n'*}"
    if [ "$expect" = flag ]; then [ -n "$hit" ] && tp=$((tp + 1)) || echo "MISSED (expected flag) row $row: $text"
    else [ -n "$hit" ] && fp_fix=$((fp_fix + 1)) || fn=$((fn + 1)); fi
done < "$FX"
echo "fixture: $rows rows; expect=flag rows caught: $tp; expect=miss rows (undetectable by design) correctly silent: $fn; unexpected hits: $fp_fix"
echo "recall on all $rows known-bad rows: $(( (tp * 100) / rows ))% ($tp/$rows)"
[ -n "$DIR" ] || exit 0
total=0; flagged=0; big=0; bigflagged=0
while IFS= read -r row; do
    d="$(jq -r '.t[:10]' <<<"$row")"; [[ "$SKIP" == *",$d,"* ]] && continue
    x="$(jq -r .x <<<"$row")"; w="$(wc -w <<<"$x")"
    total=$((total + 1)); [ "$w" -ge "$MINW" ] && big=$((big + 1))
    out="$(printf '%s\n' "$x" | "$LINT" --only carryover)"; h="${out%%$'\n'*}"
    if [ -n "$h" ]; then
        flagged=$((flagged + 1)); [ "$w" -ge "$MINW" ] && bigflagged=$((bigflagged + 1))
        printf 'FLAG %s %s\n' "$d" "${h:0:200}"
    fi
done < <(jq -c 'select(.type=="assistant") | {t:.timestamp, x:([.message.content[]? | select(.type=="text") | .text] | join("\n"))} | select(.x|length>0)' "$DIR"/*.jsonl)
echo "sample: $total replies, $flagged flagged; of $big replies with >=$MINW words, $bigflagged flagged"
