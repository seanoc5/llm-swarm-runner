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

# a ring the hook itself made: the reply to it (a continuation, stop_hook_active=true) is recorded
P3="$T/proj3"; mkdir -p "$P3/.swarm/coord-inbox"
printf 'Worker done.\n' > "$P3/.swarm/coord-inbox/20261117T030000Z-outcome-5-6.md"
hook3() { jq -nc --rawfile m "$2" --argjson a "$1" '{stop_hook_active:$a, last_assistant_message:$m}' | CLAUDE_PROJECT_DIR="$P3" COORD_HOOK_STATE=1 COORD_INBOX_BATCH_SECS=0 "$ROOT/scripts/coord-hook.sh" Stop; }
printf 'Nothing happened yet. Nothing to do.\n' > "$T/pre.txt"
out="$(hook3 false "$T/pre.txt")"
check "hook ring: the first Stop rings the doorbell and records nothing" "block|no" "$(jq -r .decision <<<"$out")|$([ -d "$P3/.swarm/coordinator-reports" ] && echo yes || echo no)"
hook3 true "$FX/good.txt" >/dev/null
check "hook ring: the reply to the hook's own doorbell is recorded" "20261117T030000Z-outcome-5-6.md" "$(ls "$P3/.swarm/coordinator-reports" 2>/dev/null | grep '\.md$')"
# a doorbell older than a day is not what a reply answers
P4="$T/proj4"; mkdir -p "$P4/.swarm"; echo "$(( $(date +%s) - 200000 ))" > "$P4/.swarm/coord-typed-ring"
"$REC" --project "$P4" < "$FX/good.txt"
check "recorder: a stale doorbell (over a day) records nothing" "no" "$([ -d "$P4/.swarm/coordinator-reports" ] && echo yes || echo no)"

# an item written in the same second as the previous report is not named by the next one
P5="$T/proj5"; mkdir -p "$P5/.swarm/coord-inbox"
printf 'a\n' > "$P5/.swarm/coord-inbox/20261117T040000Z-a-1-1.md"
echo "$(( $(date +%s) - 3 ))" > "$P5/.swarm/coord-typed-ring"
"$REC" --project "$P5" < "$FX/good.txt"
sleep 2; printf 'b\n' > "$P5/.swarm/coord-inbox/20261117T040005Z-b-2-2.md"
sleep 1; date +%s > "$P5/.swarm/coord-typed-ring"; sleep 1
"$REC" --project "$P5" < "$FX/good.txt"
check "recorder: the second report is keyed by the new item only" "20261117T040000Z-a-1-1.md 20261117T040005Z-b-2-2.md" "$(ls "$P5/.swarm/coordinator-reports" | grep '\.md$' | paste -sd' ' -)"

# an item that lands in the same whole second as the previous record (but after it) is named next time (#994)
P6="$T/proj6"; mkdir -p "$P6/.swarm/coord-inbox"
printf 'a\n' > "$P6/.swarm/coord-inbox/20261117T050000Z-a-1-1.md"
echo "$(( $(date +%s) - 3 ))" > "$P6/.swarm/coord-typed-ring"
"$REC" --project "$P6" < "$FX/good.txt"
at6="$(cat "$P6/.swarm/coord-report-at")"
printf 'b\n' > "$P6/.swarm/coord-inbox/20261117T050001Z-b-2-2.md"
touch -d "@$(awk -v a="$at6" 'BEGIN{printf "%.9f", a + 0.2}')" "$P6/.swarm/coord-inbox/20261117T050001Z-b-2-2.md"
sleep 1; date +%s > "$P6/.swarm/coord-typed-ring"; sleep 1
"$REC" --project "$P6" < "$FX/good.txt"
check "recorder: a same-second item after the previous record is the next trigger" '["20261117T050001Z-b-2-2"]' "$(jq -c .triggers "$P6/.swarm/coordinator-reports/20261117T050001Z-b-2-2.meta.json" 2>/dev/null)"
