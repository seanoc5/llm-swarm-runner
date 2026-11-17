#!/usr/bin/env bash
#
# score-wake-report.sh — deterministic score for one coordinator wake report
# (issue #863, stage B2 of the coordinator-in-corpusminder experiment: the Claude
# Code coordinator's reply after a doorbell is scored beside the corpusminder
# shadow coordinator's reply to the same event).
#
# Usage: score-wake-report.sh [--project DIR] <file|->
#
# Five pass/fail checks, equal weight. Reuses the #811 checks component
# (scripts/checks/run.sh reply, i.e. lint-coordinator-reply.sh rules) plus a few
# text checks of its own. issue-merged and stale-window are skipped: they need
# GitHub or a live swarm, and a score must be repeatable offline.
#
#   bottom-line-first  the first sentence (a leading "Woke for:" line is skipped)
#                      is plain prose: not a heading, bullet, label ending in ":",
#                      or filler ("Let me", "I'll", "Looking at"); and the reply
#                      lint raised no lede-identifier hit (it opens with words,
#                      not #N / paths / code spans).
#   one-do-now         exactly one closing line outside code fences: "Do now:",
#                      "Nothing to do/needed", or "Pending your approval:" (the
#                      sanctioned endings of the operator's reply schema), and no
#                      two-endings hit.
#   lettered-lists     no bare "1." / "1)" list (bare-list hit): lists carry
#                      letters (A1, B2) so "your B2" is unambiguous.
#   full-urls          every "#N" mentioned outside code fences also appears in
#                      the report as a full https://github.com/.../(pull|issues)/N URL.
#   no-back-references no backref hit ("the command above", "as before") and no
#                      carryover hit (a label or section pointer with no gloss).
#
# Output: one JSON object on stdout:
#   {"file":"…","score":80,"passed":4,"total":5,
#    "checks":[{"id":"…","pass":true,"detail":"…"}, …]}
# score = round(100 * passed / total). Exit 0 when scored, 2 on usage/IO error.
# Naive on purpose (see docs/checks.md): a regex that runs every week beats a
# judgment nobody makes. Fixtures: tests/fixtures/wake-report/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT=""; FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --project) [ $# -ge 2 ] || { echo "--project needs a value" >&2; exit 2; }; PROJECT="$2"; shift 2 ;;
        -) FILE="-"; shift ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) [ -z "$FILE" ] || { echo "one file only" >&2; exit 2; }; FILE="$1"; shift ;;
    esac
done
[ -n "$FILE" ] || { echo "Usage: $0 [--project DIR] <file|->" >&2; exit 2; }
command -v jq >/dev/null || { echo "score-wake-report: jq required" >&2; exit 2; }

T="$(mktemp -d -t score-wake-XXXXXX)"; trap 'rm -rf "$T"' EXIT
if [ "$FILE" = "-" ]; then cat > "$T/report"; name="-"; else
    [ -r "$FILE" ] || { echo "score-wake-report: cannot read '$FILE'" >&2; exit 2; }
    cp "$FILE" "$T/report"; name="$FILE"
fi
R="$T/report"

# Prose view: fenced lines blanked, so line numbers stay put and nothing inside a
# code block counts as an ending, a #N mention or a first sentence.
awk '/^[[:space:]]*(```|~~~)/ { f = !f; print ""; next } { print (f ? "" : $0) }' "$R" > "$T/prose"

# The #811 reply checks, offline-safe. Exit 1 just means findings.
CHECKS_SKIP_RULES="issue-merged,stale-window" CHECKS_PROJECT="$PROJECT" \
    "$HERE/checks/run.sh" reply "$R" > "$T/findings" 2>/dev/null
ec=$?
[ "$ec" -le 1 ] || { echo "score-wake-report: reply checks failed (exit $ec)" >&2; exit 2; }
hit() { jq -r --arg c "$1" 'select(.check==$c) | .match' "$T/findings" | head -n1; }

checks="[]"
add() {  # <id> <pass true|false> <detail>
    checks="$(jq -c --arg id "$1" --argjson p "$2" --arg d "$3" '. + [{id:$id,pass:$p,detail:$d}]' <<<"$checks")"
}

# 1. bottom-line-first ------------------------------------------------------
first="$(grep -vE '^[[:space:]]*$|^[[:space:]]*Woke for:' "$T/prose" | head -n1)"
why=""
if [ -z "$first" ]; then why="the report is empty"
elif [[ "$first" =~ ^[[:space:]]*([#*\>\|-]|[0-9]+[.\)]|[A-Z][0-9]*[.\)][[:space:]]) ]]; then why="opens with a heading, bullet or list marker: $first"
elif [[ "$first" =~ :[[:space:]]*$ ]]; then why="opens with a label, not a sentence: $first"
elif [[ "$first" =~ ^[[:space:]]*(Let\ me|I\'ll|I\ will|I\ am\ going|Looking\ at|Okay|Sure|Now,|First,|I\ ran|I\ checked|I\ read) ]]; then why="opens with filler, not the outcome: $first"
elif lede="$(hit lede-identifier)" && [ -n "$lede" ]; then why="first sentence leads with an identifier: $lede"
fi
[ -z "$why" ] && add bottom-line-first true "" || add bottom-line-first false "$why"

# 2. one-do-now --------------------------------------------------------------
do_now="$(grep -ciE '^[[:space:]]*(\*\*)?do now(\*\*)?:' "$T/prose" || true)"
nothing="$(grep -ciE '^[[:space:]]*(\*\*)?nothing (to do|needed)|(^|[.!][[:space:]])nothing (to do|needed)[^.]*\.?[[:space:]]*$' "$T/prose" || true)"
pending="$(grep -ciE '^[[:space:]]*(\*\*)?pending your approval(\*\*)?:' "$T/prose" || true)"
total=$((do_now + nothing + pending))
if [ "$total" -eq 1 ] && [ -z "$(hit two-endings)" ]; then add one-do-now true ""
else add one-do-now false "$total closing line(s): $do_now Do now, $nothing Nothing to do, $pending Pending your approval; want exactly 1"; fi

# 3. lettered-lists ----------------------------------------------------------
bare="$(hit bare-list)"
[ -z "$bare" ] && add lettered-lists true "" || add lettered-lists false "bare numbered list: $bare"

# 4. full-urls ---------------------------------------------------------------
sed -E 's#https?://[^[:space:])>]*##g' "$T/prose" \
    | grep -oE '(^|[^[:alnum:]&/#])#[0-9]+([^[:alnum:]_]|$)' | grep -oE '[0-9]+' | sort -un > "$T/mentioned"
grep -oE 'https://github\.com/[^[:space:])>]+/(pull|issues)/[0-9]+' "$R" | grep -oE '[0-9]+$' | sort -un > "$T/linked"
missing="$(comm -23 "$T/mentioned" "$T/linked" | sed 's/^/#/' | paste -sd' ' -)"
[ -z "$missing" ] && add full-urls true "" || add full-urls false "no full https URL for $missing"

# 5. no-back-references ------------------------------------------------------
back="$(hit backref)"; carry="$(hit carryover)"
if [ -z "$back$carry" ]; then add no-back-references true ""
else add no-back-references false "${back:-$carry}"; fi

jq -n --arg file "$name" --argjson checks "$checks" '
    ($checks | map(select(.pass)) | length) as $p | ($checks | length) as $t
    | {file:$file, score:((100 * $p / $t) | round), passed:$p, total:$t, checks:$checks}'
