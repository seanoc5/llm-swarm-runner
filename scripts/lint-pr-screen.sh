#!/usr/bin/env bash
#
# lint-pr-screen.sh — Altitude gate for the PR body's *screen* (everything
# above the folded <details> appendix). Mechanical enforcement of
# prompts/worker.md § "PR body skeleton" rules (f)–(h): the screen is
# written for a manager returning cold, so it carries consequences, not
# coordinates. Prose guidance on this relapsed a dozen-plus times
# (corpusminder-spring #632, 2026-09-18: a 230-word "What surprised me"
# stuffed with class names against a template that said "one line") —
# same lesson as the background-shell hook: only a check that fails sticks.
#
# Usage:
#   lint-pr-screen.sh <PR#>              # body via `gh pr view`
#   lint-pr-screen.sh --file <body.md>   # body from a file
#   cat body.md | lint-pr-screen.sh -    # body from stdin
#
# Checks (each failure is one line: "lint-pr-screen: FAIL <rule>: <why>"):
#   identifiers-above-fold   backticks (code spans) anywhere on the screen.
#                            Class names, paths, endpoints, migration
#                            numbers, gradle commands all live in the
#                            appendix. Exception: none — Closes #N is plain
#                            text by the existing rule anyway.
#   bottom-line-budget       **Bottom line:** over $PR_SCREEN_BOTTOM_MAX
#                            words (default 60).
#   surprise-budget          **What surprised me:** over
#                            $PR_SCREEN_SURPRISE_MAX words (default 50).
#   your-move-budget         inline **Your move:** over
#                            $PR_SCREEN_MOVE_MAX words (default 40).
#   recommendation-in-table  a ✅ inside a markdown table row. The
#                            recommendation goes on its own line UNDER the
#                            Decide table ("✅ Recommend A — why. Default if
#                            silent: …") so it can never land on the wrong
#                            option's row (corpusminder-spring #641: ✅ text
#                            said "A" but sat in row B).
#   screen-too-long          screen (minus blank lines and the risk comment)
#                            over $PR_SCREEN_MAX_LINES lines (default 25) —
#                            the "≤4 new items per screen" budget, proxied.
#
# Exit codes (gate-friendly — run before `gh pr ready`):
#   0  clean
#   3  one or more FAIL lines (body needs rewriting before ready)
#   2  usage / could not read body
set -euo pipefail

BOTTOM_MAX="${PR_SCREEN_BOTTOM_MAX:-60}"
SURPRISE_MAX="${PR_SCREEN_SURPRISE_MAX:-50}"
MOVE_MAX="${PR_SCREEN_MOVE_MAX:-40}"
LINES_MAX="${PR_SCREEN_MAX_LINES:-25}"

SRC=""
MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --file) shift; MODE=file; SRC="${1:-}" ;;
        -)      MODE=stdin ;;
        -*)     echo "lint-pr-screen: unknown flag '$1'" >&2; exit 2 ;;
        *)      MODE=pr; SRC="$1" ;;
    esac
    shift
done

case "$MODE" in
    file)  [ -r "$SRC" ] || { echo "lint-pr-screen: cannot read '$SRC'" >&2; exit 2; }
           BODY=$(cat "$SRC") ;;
    stdin) BODY=$(cat) ;;
    pr)    BODY=$(gh pr view "$SRC" --json body --jq .body) \
               || { echo "lint-pr-screen: gh pr view $SRC failed" >&2; exit 2; } ;;
    *)     echo "Usage: $0 <PR#> | --file <body.md> | -" >&2; exit 2 ;;
esac

# Screen = everything before the first <details> (or before the trailing
# metadata footer if there is no appendix), minus the risk HTML comment.
SCREEN=$(printf '%s\n' "$BODY" \
    | awk '/<details/{exit} /^<sub>/{exit} {print}' \
    | grep -v '<!-- BLIND_MERGE_RISK:' || true)

FINDINGS=0
fail() { echo "lint-pr-screen: FAIL $1: $2"; FINDINGS=$((FINDINGS + 1)); }

# Word count of the text following a bold label, up to the next bold label
# or blank line. Labels are matched case-insensitively at line start.
label_words() {
    printf '%s\n' "$SCREEN" \
        | awk -v lbl="$1" '
            BEGIN { IGNORECASE=1; on=0 }
            {
                if ($0 ~ "^\\*\\*" lbl ":\\*\\*") { on=1; sub("^\\*\\*" lbl ":\\*\\*", ""); print; next }
                if (on && ($0 ~ /^\*\*[A-Za-z ]+:\*\*/ || $0 ~ /^[[:space:]]*$/ || $0 ~ /^#/)) { on=0 }
                if (on) print
            }' \
        | wc -w | tr -d ' '
}

# --- identifiers-above-fold --------------------------------------------------
if printf '%s\n' "$SCREEN" | grep -q '`'; then
    N=$(printf '%s\n' "$SCREEN" | grep -o '`[^`]*`' | wc -l | tr -d ' ')
    fail identifiers-above-fold \
        "$N code span(s) on the screen — class names, paths, endpoints, commands belong in the appendix; say what it means, not where it lives"
fi

# --- per-label word budgets --------------------------------------------------
W=$(label_words "Bottom line")
[ "$W" -le "$BOTTOM_MAX" ] || fail bottom-line-budget "$W words (max $BOTTOM_MAX) — outcome, blast radius, Closes #N; everything else is appendix"
W=$(label_words "What surprised me")
[ "$W" -le "$SURPRISE_MAX" ] || fail surprise-budget "$W words (max $SURPRISE_MAX) — one line: the implication for the operator, not the debugging story (that is ## Findings)"
W=$(label_words "Your move")
[ "$W" -le "$MOVE_MAX" ] || fail your-move-budget "$W words (max $MOVE_MAX) — use the '#### Your move' bullet list when there is more than one item"

# --- recommendation-in-table -------------------------------------------------
if printf '%s\n' "$SCREEN" | grep -E '^\|' | grep -q '✅'; then
    fail recommendation-in-table \
        "✅ inside a table row — put the recommendation on its own line under the table ('✅ Recommend A — why. Default if silent: …') so it cannot sit on the wrong option's row"
fi

# --- screen-too-long ---------------------------------------------------------
L=$(printf '%s\n' "$SCREEN" | grep -cve '^[[:space:]]*$' || true)
[ "$L" -le "$LINES_MAX" ] || fail screen-too-long "$L non-blank lines (max $LINES_MAX) — fold it; the appendix exists for this"

if [ "$FINDINGS" -eq 0 ]; then
    echo "lint-pr-screen: clean"
    exit 0
fi
echo "lint-pr-screen: $FINDINGS finding(s) — rewrite the screen before gh pr ready" >&2
exit 3
