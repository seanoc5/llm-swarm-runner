#!/usr/bin/env bash
# test-needs-you-labels.sh — issue #1052 (decision in #1023): needs-you.sh labels an
# ask by its GitHub number + letter (1042a), takes short input on `done`, and keeps
# the old counter label (A1) when there is no GitHub URL. Hermetic: the repo comes
# from a throwaway git origin remote (gh is not needed; a stub gh fails on purpose).
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NY="$ROOT/scripts/needs-you.sh"
LINT="$ROOT/scripts/lint-coordinator-reply.sh"
BG="Loads the county boundary shapefile into the development database so the map pages have data; it is open because last night's load job skipped it."
T="$(mktemp -d -t needs-you-labels-XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sandbox" "$T/bin" "$T/home"
: > "$T/sandbox/.env.example"
export LLM_SWARM_DIR="$T/sandbox" HOME="$T/home"
unset NEEDS_YOU_BACKEND CMINDER_URL CMINDER_API_KEY
printf '#!/bin/sh\nexit 1\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

P="$T/p"; mkdir -p "$P/.swarm"
git -C "$P" init -q
git -C "$P" remote add origin https://github.com/seanoc5/llm-swarm-runner.git
add() { "$NY" add --check-source operator --background "$BG" --project "$P" --title "Ask $RANDOM" --do 'Say `merge PR 9`' "$@"; }
labels() { "$NY" render --json --project "$P" | jq -r 'map(.label) | join(",")'; }
SELF=https://github.com/seanoc5/llm-swarm-runner

check "own-repo PR url mints <number>a" "1042a" "$(add --url $SELF/pull/1042)"
check "second add on the same url mints <number>b" "1042b" "$(add --url $SELF/pull/1042)"
check "an issue url works too" "77a" "$(add --url $SELF/issues/77)"
"$NY" done 1042b --project "$P"
check "letters are never reused after done" "1042c" "$(add --url $SELF/pull/1042)"
"$NY" done 1042c --project "$P"; "$NY" done 1042a --project "$P"
check "...even when every letter of the item is done" "1042d" "$(add --url $SELF/pull/1042)"
check "render prints the full label" "1" "$("$NY" render --project "$P" | grep -c -- '^- \*\*1042d\*\*')"
check "a rendered new-label list passes the reply lint" "" "$("$LINT" <<<"$("$NY" render --project "$P")" | cut -d: -f1 | paste -sd, -)"

# cross-repo prefixes
check "oconeco-ui prefix" "ui5a" "$(add --url https://github.com/seanoc5/oconeco-ui/pull/5)"
check "corpusminder-spring prefix" "cm5a" "$(add --url https://github.com/seanoc5/corpusminder-spring/pull/5)"
check "fand-app prefix" "fa5a" "$(add --url https://github.com/seanoc5/fand-app/pull/5)"
check "fand-etl prefix" "fe5a" "$(add --url https://github.com/seanoc5/fand-etl/pull/5)"
check "SAMlytics prefix (case-insensitive)" "sam5a" "$(add --url https://github.com/seanoc5/SAMlytics/pull/5)"
check "unknown repo: first 3 letters" "wid5a" "$(add --url https://github.com/o/widget-service/pull/5)"
check "prefixed items keep their own letter sequence" "ui5b" "$(add --url https://github.com/seanoc5/oconeco-ui/issues/5)"

# fallback: no url / non-GitHub url keep the counter, and the counter ignores new labels
check "no url: counter label" "A1" "$(add)"
check "non-GitHub url: counter label" "A2" "$(add --url https://example.com/thing/9)"
check "a github non-PR/issue url: counter label" "A3" "$(add --url https://github.com/seanoc5/llm-swarm-runner/actions/runs/9)"

# the same number in another project's own repo gets no prefix (SAMlytics pilot)
S="$T/s"; mkdir -p "$S/.swarm"; git -C "$S" init -q
git -C "$S" remote add origin git@github.com:seanoc5/SAMlytics.git
check "a project's own repo has no prefix (SAMlytics)" "9a" "$("$NY" add --check-source operator --background "$BG" --project "$S" --title "Own ask" --do 'Say `merge PR 9`' --url https://github.com/seanoc5/SAMlytics/pull/9)"

# titles/backgrounds that mention a new-shape label are not refused as stubs
check "a title naming a new-shape label is accepted" "0" "$("$NY" add --check-source operator --background "$BG" --project "$P" --title "Follow-up to 1042d after the merge" --do 'Say `merge PR 9`' >/dev/null 2>&1; echo $?)"
"$NY" done A4 --project "$P"

# short input on done
R="$T/r"; mkdir -p "$R/.swarm"; git -C "$R" init -q
git -C "$R" remote add origin https://github.com/seanoc5/llm-swarm-runner.git
radd() { "$NY" add --check-source operator --background "$BG" --project "$R" --title "Ask $RANDOM" --do 'Say `merge PR 9`' "$@"; }
rlabels() { "$NY" render --json --project "$R" | jq -r 'map(.label) | join(",")'; }
radd --url $SELF/pull/1042 >/dev/null; radd --url $SELF/pull/1142 >/dev/null; radd --url https://github.com/seanoc5/oconeco-ui/pull/1042 >/dev/null; radd >/dev/null
"$NY" done 1142a --project "$R"
check "done with the full label" "1042a,ui1042a,A1" "$(rlabels)"
set +e; "$NY" done 42a --project "$R" >"$T/out" 2>"$T/err"; ec=$?; set -e
check "ambiguous short input exits 1" "1" "$ec"
check "...and lists both candidates" "1042a ui1042a" "$(grep -oE '^  [a-z0-9]+' "$T/err" | tr -d ' ' | paste -sd' ' -)"
check "...and closes nothing" "1042a,ui1042a,A1" "$(rlabels)"
"$NY" done ui042a --project "$R"
check "short input with a prefix picks that prefix" "1042a,A1" "$(rlabels)"
"$NY" done 2a --project "$R"
check "unique short input (last digit + letter) closes it" "A1" "$(rlabels)"
set +e; "$NY" done 99z --project "$R" >/dev/null 2>"$T/err"; ec=$?; set -e
check "no match exits non-zero" "2" "$ec"
check "short input never matches a done item" "A1" "$(rlabels)"
set +e; "$NY" done 042a --project "$R" >/dev/null 2>&1; ec=$?; set -e
check "a done item's short input matches nothing" "2" "$ec"
"$NY" done A1 --project "$R"
check "old labels still close by exact name" "" "$(rlabels)"
echo "all needs-you label checks passed"
