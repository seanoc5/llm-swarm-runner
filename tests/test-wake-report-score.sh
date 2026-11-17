#!/usr/bin/env bash
# test-wake-report-score.sh — issue #863: score-wake-report.sh scores one known-good and
# three known-bad wake-report fixtures; compare-wake-reports.sh pairs fixture reports by
# trigger and prints per-pair and average scores; coord-report-record.sh keeps the reply
# after a doorbell and cminder-events.sh posts it as a coordinator_report event.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCORE="$ROOT/scripts/score-wake-report.sh"; CMP="$ROOT/scripts/compare-wake-reports.sh"
FX="$ROOT/tests/fixtures/wake-report"
failed() { "$SCORE" "$FX/$1.txt" | jq -r '[.checks[] | select(.pass|not) | .id] | join(",")'; }
score()  { "$SCORE" "$FX/$1.txt" | jq -r .score; }

check "good report: score 100, nothing failed" "100|" "$(score good)|$(failed good)"
check "bad lede + two endings: fails exactly those and the URL check" "bottom-line-first,one-do-now,full-urls" "$(failed bad-lede-and-endings)"
check "bad lists + bare #N: fails lettered-lists and full-urls" "lettered-lists,full-urls" "$(failed bad-lists-and-urls)"
check "bad back-reference: fails no-back-references only, score 80" "no-back-references|80" "$(failed bad-backref)|$(score bad-backref)"
check "stdin works" "100" "$("$SCORE" - < "$FX/good.txt" | jq -r .score)"
check "output shape: file, score, passed, total, 5 checks" "true" "$("$SCORE" "$FX/good.txt" | jq '(.checks|length)==5 and .total==5 and .passed==5 and (.file|type=="string")')"
set +e; "$SCORE" /nonexistent >/dev/null 2>&1; a=$?; "$SCORE" >/dev/null 2>&1; b=$?; set -e
check "unreadable file and no argument exit 2" "2 2" "$a $b"

# compare: copy the fixtures so mtimes are fresh
T="$(mktemp -d -t wake-report-XXXXXX)"; trap 'rm -rf "$T"' EXIT
cp -r "$FX/claude" "$FX/shadow" "$T/"; touch "$T"/claude/* "$T"/shadow/*
out="$("$CMP" --claude-dir "$T/claude" --shadow-dir "$T/shadow" --json)"
check "compare: pairs by trigger, 1 Claude-only, 1 shadow-only" "ev-a,ev-b|ev-c|ev-d" \
    "$(jq -r '"\([.pairs[].trigger]|join(","))|\(.claude_only|join(","))|\(.shadow_only|join(","))"' <<<"$out")"
check "compare: per-pair scores" "100/60 80/100" "$(jq -r '.pairs | map("\(.claude.score)/\(.shadow.score)") | join(" ")' <<<"$out")"
check "compare: averages and the shadow's recorded cost" "90 80 0.03" "$(jq -r '"\(.average.claude) \(.average.shadow) \(.average.shadow_cost_usd)"' <<<"$out")"
txt="$("$CMP" --claude-dir "$T/claude" --shadow-dir "$T/shadow")"
check "compare: text summary names pairs and the average" "yes" "$(grep -q '^ev-a ' <<<"$txt" && grep -q 'average: claude 90, shadow 80' <<<"$txt" && echo yes || echo no)"
touch -d '30 days ago' "$T"/claude/ev-a.md
check "compare: --since drops old reports" "1" "$("$CMP" --claude-dir "$T/claude" --shadow-dir "$T/shadow" --json | jq '.pairs|length')"
check "compare: nothing paired is an answer, not an error" "Nothing paired yet." "$("$CMP" --claude-dir "$T/claude" --shadow-dir "$T/shadow" --since 0 | tail -n1)"
set +e; "$CMP" >/dev/null 2>&1; a=$?; set -e
check "compare: missing --shadow-dir exits 2" "2" "$a"

# recorder + sweep
mkdir -p "$T/sandbox" "$T/bin" "$T/home"; : > "$T/sandbox/.env.example"
export LLM_SWARM_DIR="$T/sandbox" HOME="$T/home"
unset NEEDS_YOU_BACKEND CMINDER_URL CMINDER_API_KEY CMINDER_FORUM_ID CMINDER_EVENTS COORD_INBOX_DIR
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
body=""; prev=""
for a in "$@"; do [ "$prev" = "--data-binary" ] && body="${a#@}"; prev="$a"; done
printf 'call\n' >> "$CALLS"; [ -n "$body" ] && { cat "$body"; echo; } >> "$BODIES"
printf 200
STUB
chmod +x "$T/bin/curl"; export PATH="$T/bin:$PATH" CALLS="$T/calls" BODIES="$T/bodies"
P="$T/proj"; mkdir -p "$P/.swarm/coord-inbox"
git -C "$P" init -q -b main && git -C "$P" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
REC="$ROOT/scripts/coord-report-record.sh"; EV="$ROOT/scripts/cminder-events.sh"
printf 'Worker 7 finished.\n' > "$P/.swarm/coord-inbox/20261117T010000Z-outcome-1-2.md"
echo "$(( $(date +%s) - 5 ))" > "$P/.swarm/coord-typed-ring"
"$REC" --project "$P" < "$FX/good.txt"
check "recorder: CMINDER_EVENTS=0 writes nothing" "no" "$([ -d "$P/.swarm/coordinator-reports" ] && echo yes || echo no)"
export NEEDS_YOU_BACKEND=corpusminder CMINDER_EVENTS=1 CMINDER_URL=http://x CMINDER_API_KEY=k1k1k1k1k1 CMINDER_FORUM_ID=9
"$REC" --project "$P" < "$FX/good.txt"
check "recorder: a reply after a doorbell is kept under its trigger" "20261117T010000Z-outcome-1-2.md" "$(ls "$P/.swarm/coordinator-reports" | grep '\.md$')"
check "recorder: meta names the trigger items" '["20261117T010000Z-outcome-1-2"]' "$(jq -c .triggers "$P/.swarm/coordinator-reports/20261117T010000Z-outcome-1-2.meta.json")"
"$REC" --project "$P" < "$FX/bad-backref.txt"
check "recorder: a second reply with no new doorbell is ignored" "1" "$(ls "$P/.swarm/coordinator-reports" | grep -c '\.md$')"
"$EV" sweep --project "$P"
check "sweep: the report posts once as coordinator_report with its trigger" "coordinator_report|20261117T010000Z-outcome-1-2" \
    "$(jq -rs '[.[] | select(.kind=="coordinator_report")][0] | "\(.kind)|\(.payload.trigger)"' "$BODIES")"
check "sweep: the whole report text is in the payload" "yes" "$(jq -rs '[.[] | select(.kind=="coordinator_report")][0].payload.text | contains("Do now: run")' "$BODIES" | sed 's/true/yes/')"
n1="$(grep -c . "$CALLS")"; "$EV" sweep --project "$P"
check "sweep: a second sweep posts nothing new" "$n1" "$(grep -c . "$CALLS")"

# the Stop hook feeds an accepted reply to the recorder (a lint-clean one; a blocked one is not kept)
P2="$T/proj2"; mkdir -p "$P2/.swarm/coord-inbox"
printf 'Idle.\n' > "$P2/.swarm/coord-inbox/20261117T020000Z-idle-3-4.md"
echo "$(( $(date +%s) - 5 ))" > "$P2/.swarm/coord-typed-ring"
hook() { jq -nc --rawfile m "$1" '{stop_hook_active:false, last_assistant_message:$m}' | CLAUDE_PROJECT_DIR="$P2" COORD_HOOK_STATE=0 "$ROOT/scripts/coord-hook.sh" Stop; }
printf 'Run the command above to finish.\nDo now: A1.\n' > "$T/blocked.txt"
hook "$T/blocked.txt" >/dev/null
check "hook: a lint-blocked reply is not recorded" "no" "$([ -d "$P2/.swarm/coordinator-reports" ] && echo yes || echo no)"
hook "$FX/good.txt" >/dev/null
check "hook: an accepted reply after a doorbell is recorded" "20261117T020000Z-idle-3-4.md" "$(ls "$P2/.swarm/coordinator-reports" 2>/dev/null | grep '\.md$')"
