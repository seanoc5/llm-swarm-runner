#!/usr/bin/env bash
# test-reply-lint.sh — issue #798: coordinator action items must carry their
# commands. Covers lint-coordinator-reply.sh against the incident fixtures,
# needs-you.sh (refuses a stub, renders every `do:` in full, one closing line),
# and the Stop hook's reply lint (blocks once, counts hits in events.log),
# in resident and split mode. Also #716 issue-merged (gh stubbed). No tmux, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/lint-coordinator-reply.sh"
NY="$ROOT/scripts/needs-you.sh"
BG="Loads the county boundary shapefile into the development database so the map pages have data; it is open because last night's load job skipped it."
HOOK="$ROOT/scripts/coord-hook.sh"
FX="$ROOT/tests/fixtures/reply-lint"
T="$(mktemp -d -t reply-lint-XXXXXX)"
trap 'rm -rf "$T"' EXIT

# lede-identifier has its own section below; the incident fixtures here are one-liners that may trip it
rules() { "$LINT" < "$1" | grep -v '^lede-identifier:' | cut -d: -f1 | sort -u | paste -sd, -; }

# ── lint: the incidents from the issue, replayed ─────────────────────────────
check "A13 'Start the load (command above)': backref + no-command" "backref,no-command" "$(rules "$FX/incident-start-load.txt")"
check "forward pointer 'run the command below' + fence: clean" "" "$(rules "$FX/clean-command-below.txt")"
check "quiet reply 'details in .swarm/needs-you.md': backref" "backref" "$(rules "$FX/incident-quiet-pointer.txt")"
check "'same as in my last message': flagged" "backref,no-command" "$(rules "$FX/incident-last-message.txt")"
check "#801 fixture (Nothing needed + Do now): two-endings" "two-endings" "$(rules "$FX/incident-contradictory-ending.txt")"
check "a rendered list with a fenced command is clean" "" "$(rules "$FX/clean-render.txt")"
check "'Nothing to do.' alone is clean" "" "$(rules "$FX/clean-nothing.txt")"
set +e; "$LINT" < "$FX/incident-start-load.txt" >/dev/null; ec=$?; "$LINT" < "$FX/clean-nothing.txt" >/dev/null; ec2=$?; set -e
check "exit 3 on hits, 0 clean" "3 0" "$ec $ec2"
printf 'Pending your approval: merge PR 4 (yes/no)\nDo now: say yes\n' > "$T/two"
check "Pending your approval + Do now: two-endings" "ask-not-listed,two-endings" "$(rules "$T/two")"
printf -- '- **A1** Click the Approve button\n  https://github.com/o/r/pull/4 (Files changed > Review)\n' > "$T/url"
check "a click item with an https URL is clean" "" "$(rules "$T/url")"
# issue #680: an approval item must state its change, not point at it
check "#680 incident (\"make those three edits yourself\"): pointer" "ask-not-listed,pointer" "$(rules "$FX/incident-pointer-edits.txt")"
check "#680 version naming ci.yml, the line and the change: clean" "" "$(rules "$FX/clean-pointer-edits-named.txt")"
printf -- "- **A1** Pick option A: rescope the export to CSV only (default if silent)\n" > "$T/optok"
check "#680 \"option A: <text>\" carries its text: clean" "" "$(rules "$T/optok")"
printf "Pending your approval: apply the fix above (yes/no)\n" > "$T/pend"
check "#680 a Pending-approval line is linted as an item (apply, no change shown): no-command" "ask-not-listed,no-command" "$(rules "$T/pend")"
printf -- "- **A1** Edit the workflow so checkout fetches submodules (yes/no)\n" > "$T/edit"
check "#680 an edit verb with no file, line or command: no-command" "no-command" "$(rules "$T/edit")"
printf -- "- **A1** Edit scripts/needs-you.sh:44 to drop the retry (yes/no)\n" > "$T/editok"
check "#680 file:line payload clears an edit item" "" "$(rules "$T/editok")"
printf -- '- **A1** Make those three edits yourself (checked 17:34), then say go.\n' > "$T/clock"
check "#680 a clock time (17:34) is not a file:line payload: pointer" "pointer" "$(rules "$T/clock")"
printf -- '- **A1** Make those three edits yourself https://github.com/o/r/pull/1810\n' > "$T/url"
check "#680 a bare PR URL is not a pointer payload: pointer" "pointer" "$(rules "$T/url")"
printf -- '- **A1** Make those three edits yourself: `sed -i s/a/b/ x` https://github.com/o/r/pull/1810\n' > "$T/url-span"
check "#680 same phrase with the edits in a code span: clean" "" "$(rules "$T/url-span")"
printf -- '- **A3** #2148: when searches start defaulting to forum-visible, should saved searches stay private? (yes/no)\n' > "$T/yn"
check "#680 a yes/no decision using the word 'start' needs no command: clean" "" "$(rules "$T/yn")"
printf 'Pending your approval: the one-line nightly config edit (yes/no)\n' > "$T/pe"
check "#680 a Pending edit with no file or change: no-command" "ask-not-listed,no-command" "$(rules "$T/pe")"
printf 'Pending your approval: merge this PR, #2311 (yes/no)\n' > "$T/pm"
check "#680 'your' in a Pending line is not 'you ... merge this': no other hit" "ask-not-listed" "$(rules "$T/pm")"
printf 'Pending your approval: make this the default (yes/no)\n' > "$T/pd"
check "#680 Pending 'make this the default' (your != you): no other hit" "ask-not-listed" "$(rules "$T/pd")"
printf -- '- **A1** Click Approve on the PR (yes/no)\n' > "$T/ck"
check "#680 click + yes/no with no URL is not exempt: no-command" "no-command" "$(rules "$T/ck")"
printf -- '- **A1** If you say yes, I will merge it (https://github.com/o/r/pull/1810)\n' > "$T/y1"
check "#680 'if you say yes, I will merge it' (you is not the actor): clean" "" "$(rules "$T/y1")"
printf -- '- **A1** Do you want me to run it now? https://github.com/o/r/pull/1810\n' > "$T/y2"
check "#680 'do you want me to run it now?' (you is not the actor): clean" "" "$(rules "$T/y2")"
# issue #1008: a descriptive list item has no verb aimed at the operator
printf -- '- **A1** The run finished with 3 open PRs and a clean queue\n' > "$T/d1"
check "#1008 descriptive item ('the run ... open PRs'): clean" "" "$(rules "$T/d1")"
printf -- '- **A2** Queue holds 3 open PRs (two green, one red)\n' > "$T/d2"
check "#1008 'open PRs' as a noun mid-sentence: clean" "" "$(rules "$T/d2")"
printf -- '- **A1** Then run the load and tell me what it prints\n' > "$T/d3"
check "#1008 'then run ...' imperative with no command: no-command" "no-command" "$(rules "$T/d3")"
printf -- '- **A1** Run the load\n' > "$T/d4"
check "#1008 bare imperative 'Run the load': no-command" "no-command" "$(rules "$T/d4")"
printf -- '- **A1** — Run the load\n' > "$T/s1"
check "#1009 em dash after the label, 'Run the load': no-command" "no-command" "$(rules "$T/s1")"
printf -- '- **A1** 🟡 Run the load\n' > "$T/s2"
check "#1009 emoji after the label, 'Run the load': no-command" "no-command" "$(rules "$T/s2")"
printf -- '- **A1** **Run** the load\n' > "$T/s3"
check "#1009 bold verb, '**Run** the load': no-command" "no-command" "$(rules "$T/s3")"
printf -- '- **A1** The load is queued\n  Run the load and tell me what it prints\n' > "$T/s4"
check "#1009 operator verb on a continuation line: no-command" "no-command" "$(rules "$T/s4")"
printf -- '- **A1** — The run finished with 3 open PRs\n' > "$T/c1"
check "#1009 descriptive item after an em dash: clean" "" "$(rules "$T/c1")"
printf -- '- **A1** 🟡 **Queue** holds 3 open PRs\n' > "$T/c2"
check "#1009 descriptive item with emoji and bold: clean" "" "$(rules "$T/c2")"
printf -- '- **A1** The queue is healthy\n  3 open PRs, the run finished green\n' > "$T/c3"
check "#1009 descriptive continuation line: clean" "" "$(rules "$T/c3")"
printf -- '- **A1** Merge and deploy it on your end https://github.com/o/r/pull/1810\n' > "$T/oe"
check "#680 'on your end' with no code span or path: pointer" "pointer" "$(rules "$T/oe")"
printf -- '- **A1** Run `./gradlew test` on your end (yes/no)\n' > "$T/oe2"
check "#680 'on your end' with a code span: clean" "" "$(rules "$T/oe2")"
printf -- '- **A1** Do it by yourself in docs/setup.md line 4\n' > "$T/oe3"
check "#680 'by yourself' with a file path: clean" "" "$(rules "$T/oe3")"
printf -- '- **A1** Then you merge it https://github.com/o/r/pull/1810\n' > "$T/nomatch"
check "#680 open-ended 'you merge it' is no longer matched (Known limits): clean" "" "$(rules "$T/nomatch")"

# ── issue-merged (issue #716): gh stubbed; #1910 is an issue, #1913 and #1909 are PRs ──
mkdir -p "$T/ghbin"
cat > "$T/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG:-/dev/null}"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
case "$2" in
    */issues/1913|*/issues/1909) echo true ;;
    */issues/1910) echo false ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/ghbin/gh"
export GH_LOG="$T/gh.log"
gl() { PATH="$T/ghbin:$PATH" "$LINT" "$@" | grep -v "^lede-identifier:" || true; }
check "'until #1910 merges' (an issue): issue-merged" "issue-merged" "$(gl < "$FX/incident-issue-merged.txt" | cut -d: -f1 | sort -u | paste -sd, -)"
check "'PR #1913 merged' (a PR), #1910 closes, merge conflict: clean" "" "$(gl < "$FX/clean-pr-merged.txt" | cut -d: -f1 | paste -sd, -)"
check "the lookup asks the issues endpoint for that number" "yes" "$(grep -q 'repos/{owner}/{repo}/issues/1910' "$GH_LOG" && echo yes || echo no)"
printf 'Waiting on #1910 to be merged.\n' > "$T/m1"
check "'#1910 to be merged' (two words between): issue-merged" "issue-merged" "$(gl < "$T/m1" | cut -d: -f1 | paste -sd, -)"
printf 'Waiting on #1910 which is expected to be merged; #1913 merging.\n' > "$T/m1b"
check "a four-word gap is out of range (naive on purpose); '#1913 merging' is a PR: clean" "" "$(gl < "$T/m1b" | paste -sd, -)"
printf 'Merging #1910 now.\n' > "$T/m2"
check "reverse order 'merging #1910': issue-merged" "issue-merged" "$(gl < "$T/m2" | cut -d: -f1 | paste -sd, -)"
printf '```\nuntil #1910 merges\n```\n' > "$T/m3"
printf '%s\n' "the fix PR for #1910 merges" "PR #1913 merges and #1910 closes" "Merge conflict on #1910 is resolved." "#1910 merge conflict" "Merged the PR for #1910." > "$T/m4"
check "suggested wordings (fix PR for #N merges, #N closes, merge conflict) pass for an issue #N" "" "$(gl < "$T/m4" | paste -sd, -)"
check "a fenced line is skipped" "" "$(gl < "$T/m3" | paste -sd, -)"
printf '~~~\nuntil #1910 merges\n~~~\n' > "$T/m5"
check "a ~~~ fenced line is skipped too" "" "$(gl < "$T/m5" | paste -sd, -)"
check "gh failing: never flags" "" "$(GH_FAIL=1 gl < "$FX/incident-issue-merged.txt" | paste -sd, -)"
set +e; PATH="$T/ghbin:$PATH" "$LINT" --only issue-merged < "$FX/incident-issue-merged.txt" >/dev/null; ec=$?; set -e
check "issue-merged exits 3" "3" "$ec"

# ── carryover (issue #646): a bare backward reference with no gloss ─────────
cr() { printf '%s\n' "$1" | "$LINT" --only carryover | cut -d: -f1 | paste -sd, -; }
check "carryover: 'h1 and h2 from earlier' (SAMlytics 2026-10-15)" "carryover" "$(cr 'Needs you: n1 below, plus h1 and h2 from earlier')"
check "carryover: 'follow-ups A-D from earlier' (civicstrata 2026-10-15)" "carryover" "$(cr 'Pending your approval: follow-ups A–D from earlier')"
check "carryover: a section pointer with no gloss (the Tailwind '§4' incident)" "carryover" "$(cr 'Tailwind plan, carve order in §4: review it')"
check "carryover: 'from my M1-M3 report'" "carryover" "$(cr 'Run the sudo fix from my M1-M3 report.')"
check "carryover: 'your d)' undefined" "carryover" "$(cr 'Pending: your d) and the 12 drafts.')"
check "carryover: a long line that explains the reference passes" "" "$(cr 'The key rotation from earlier still needs doing: the vendor key expires Friday, so rotate it before the deploy window opens.')"
check "carryover: a label defined by a bullet on the same screen passes" "" "$(cr "$(printf -- '- **h1** Widen the index so search stops timing out.\nNeeds you: h1 below.')")"
check "carryover: an inline 'X:' definition passes" "" "$(cr 'h1: widen the index. Needs you: h1.')"
check "carryover: a heading that introduces restated items passes" "" "$(cr "$(printf 'Needs you (carried over):\n- Widen the search index so the nightly job stops timing out; yes or no, I recommend yes.\n- Rotate the vendor key before Friday; yes or no, I recommend yes.')")"
check "carryover: the same heading with nothing under it is flagged" "carryover" "$(cr 'Needs you (carried over):')"
check "carryover: a fenced line, a code span and a URL are not labels" "" "$(cr "$(printf '```\nh1 from earlier\n```\nSee `h1` and https://example.com/a1/b2 now.')")"
check "carryover: PR/issue numbers, versions, quarters and table ids are not labels" "" "$(cr 'Bump to v2 for Q3 (#1215) using table B19301 on s3.')"
check "carryover: English 'A recommended fix' is not a label" "" "$(cr 'A recommended fix is on the PR.')"
check "carryover: tech names p95, H2, G1, M1, L2 mid-line are not labels" "" "$(cr "$(printf 'p95 latency rose to 40ms.\nWe moved to an H2 database for tests.\nThe G1 GC pauses are short on the M1 box and the L2 cache.')")"
check "carryover: \"your A2\", \"see B1\", \"per A3\" and a bare B3 line are flagged" "carryover,carryover,carryover,carryover" "$(cr "$(printf 'Pending your A2.\nSee B1.\nDone per A3.\nB3 below')")"
check "carryover: '(carry-over, A recommended)' is flagged" "carryover" "$(cr 'Forest dual-write ruling (carry-over, A recommended)')"
check "carryover: rule is off under --only backref" "" "$(printf 'h1 from earlier\n' | "$LINT" --only backref | paste -sd, -)"
check "carryover: --gloss 2 lets a short gloss pass" "" "$(printf 'Review §4 now please\n' | "$LINT" --only carryover --gloss 2 | paste -sd, -)"
check "carryover: the needs-you render, clean fixtures and the #801 fixture add no carryover hit" "" "$(cat "$FX"/clean-*.txt "$FX"/incident-contradictory-ending.txt | "$LINT" --only carryover | paste -sd, -)"
# the 13-row fixture from docs/research/issue-645-reporting-rules.md section 2: every expect=flag row is flagged, every expect=miss row is not
got=""; want=""
while IFS=$'\t' read -r row _ _ expect text; do
    case "$row" in ''|'#'*) continue ;; esac
    hit="$(printf "%s\n" "$text" | "$LINT" --only carryover,backref | paste -sd, - || true)"
    [ -n "$hit" ] && got="$got$row," || true
    [ "$expect" = flag ] && want="$want$row," || true
done < "$FX/carryover-incidents.tsv"
check "13-row incident fixture: flagged rows are exactly the expect=flag rows" "$want" "$got"

# ── needs-you.sh ─────────────────────────────────────────────────────────────
P="$T/proj"; mkdir -p "$P/.swarm"
set +e; "$NY" add --check-source operator --background "$BG" --project "$P" --title "Start load" --do "Start it in 1:util" >/dev/null 2>&1; ec=$?; set -e
check "add refuses a --do with no command or URL" "2" "$ec"
set +e; "$NY" add --check-source operator --background "$BG" --project "$P" --title "Start load" --do 'run the command above `x`' >/dev/null 2>&1; ec=$?
"$NY" add --check-source operator --background "$BG" --project "$P" --title "Start load" >/dev/null 2>&1; ec2=$?; set -e
check "add refuses a back-reference and a missing --do" "2 2" "$ec $ec2"
set +e; "$NY" add --check-source operator --background "$BG" --project "$P" --title "Review plan" --do 'run `./review.sh` for the plan in §4' >/dev/null 2>&1; ec=$?
mkdir -p "$T/cproj/.swarm"; "$NY" add --check-source operator --background "$BG" --project "$T/cproj" --title "Review the Tailwind carve plan" --rec "yes: the carve order keeps the layout stable and touches only templates, so rollback is one revert" --do 'run `./review.sh tailwind`' >/dev/null 2>&1; ec2=$?; set -e
check "add refuses a bare section pointer (carryover) and accepts a self-contained item" "2 0" "$ec $ec2"
set +e; "$NY" add --check-source operator --background "$BG" --project "$T/bproj" --title "Start load" --do "$(printf 'run the command below
```
./load.sh
```')" >/dev/null 2>&1; ec=$?; set -e
check "add accepts 'the command below' followed by a fence" "0" "$ec"
rm -rf "$T/bproj"
check "refused items leave no store" "none" "$([ -e "$P/.swarm/needs-you.jsonl" ] && echo some || echo none)"
check "add prints the label" "A1" "$("$NY" add --check-source operator --background "$BG" --project "$P" --title "Load kdeyoga data" --risk "writes dev DB" --rec "yes, high confidence" --do 'In 1:util run `./load-tiger.sh kdeyoga`')"
"$NY" add --check-source operator --background "$BG" --project "$P" --title "PR 689" --kind decision --do 'Say `merge PR 689`' --url https://github.com/o/r/pull/689 >/dev/null
out="$("$NY" render --project "$P")"
case "$out" in *'./load-tiger.sh kdeyoga'*'merge PR 689'*) got=yes ;; *) got=no ;; esac
check "render prints every do in full" "yes" "$got"
check "render ends with exactly one closing line" "1" "$(grep -cE '^(Do now:|Nothing to do)' <<<"$out")"
check "a rendered list passes the reply lint" "" "$("$LINT" <<<"$out" | cut -d: -f1 | paste -sd, -)"
grep -q -- '- \*\*A2\*\*' "$P/.swarm/needs-you.md" && got=yes || got=no
check "needs-you.md (the file the hook diffs) holds the items" "yes" "$got"
check "render --json lists open items" "A1,A2" "$("$NY" render --json --project "$P" | jq -r 'map(.label) | join(",")')"
"$NY" done A1 --project "$P"
check "done closes one" "A2" "$("$NY" render --json --project "$P" | jq -r 'map(.label) | join(",")')"
check "labels are never reused" "A3" "$("$NY" add --check-source operator --background "$BG" --project "$P" --title t --do 'run `x`')"
"$NY" done A2 --project "$P"; "$NY" done A3 --project "$P"
# a fenced --do: the fence must open on its own line and Do now: must show the command
F="$T/fproj"; mkdir -p "$F/.swarm"
"$NY" add --check-source operator --background "$BG" --project "$F" --title "Load data" --do "$(printf '```\n./load.sh kdeyoga\n```')" >/dev/null
out="$("$NY" render --project "$F")"
check "fenced --do: opening fence starts its own line" "1" "$(grep -c '^```$' <<<"$out" | awk '{print ($1 == 2) ? 1 : 0}')"
check "fenced --do: Do now names the label only, the item above carries the command" "Do now: A1" "$(grep '^Do now:' <<<"$out")"
check "fenced --do: item above still shows the command" "1" "$(grep -c '^./load.sh kdeyoga$' <<<"$out")"
U="$T/uproj"; mkdir -p "$U/.swarm"
"$NY" add --check-source operator --background "$BG" --project "$U" --title "Merge it" --do "sm 2743 (https://github.com/o/r/pull/2743)" --url "https://github.com/o/r/pull/2743" >/dev/null
check "url item: render passes the reply lint (no repeat-item)" "" "$("$LINT" <<<"$("$NY" render --project "$U")" | cut -d: -f1 | paste -sd, -)"
check "fenced --do: render passes the reply lint" "" "$("$LINT" <<<"$out" | cut -d: -f1 | paste -sd, -)"
check "empty list renders 'Nothing to do.'" "Nothing to do." "$("$NY" render --project "$P" | tail -1)"

# ── needs-you.sh: cold-reader background and hand-written guard (issue #964) ──
G="$T/gproj"; mkdir -p "$G/.swarm"
gadd() { "$NY" add --check-source operator --project "$G" --do 'Say `merge PR 9`' "$@" >/dev/null 2>&1; echo $?; }
check "add refuses an item with no --background" "2" "$(gadd --title "Rebase the check")"
check "add refuses a --background under 12 words" "2" "$(gadd --title "Rebase the check" --background "Check needs a rebase")"
check "add refuses slash-joined acronyms (the 2026-11-14 stub)" "2" "$(gadd --title "SI/SR check re-base" --background "$BG")"
check "add refuses 'HOLD (yours, date)'" "2" "$(gadd --title "HOLD (yours, 2026-11-13) on the rebase" --background "$BG")"
check "add refuses option codes in the background" "2" "$(gadd --title "Pick a rebase approach" --background "Two ways to rebase the check were offered earlier today; B3 rewrites the history while A4-a keeps every commit, and nothing merges until one is chosen.")"
check "add accepts CI/CD (a well-known pair)" "0" "$(gadd --title "Fix the CI/CD cache" --background "$BG")"
check "add refuses a capitalised 'Option B'" "2" "$(gadd --title "Pick Option B for the rebase" --background "$BG")"
check "add accepts PR numbers and plain words" "0" "$(gadd --title "Rebase the check on PR #2387" --background "$BG")"
check "add skips repeat-item (warn-only rule, not a refusal)" "0" "$(gadd --title "Merge PR 972 once" --background "$(printf -- '- **A1** Merge #972 (yes/no)\n- **A2** Merge #972 again (yes/no)\nThese two lines repeat one ask, which the reply lint only warns about, so adding the item still works.')")"
out="$("$NY" render --project "$G")"
check "render leads each of the 2 items with 'What this is:'" "2" "$(grep -c '^  What this is: Loads the county' <<<"$out")"
check "check: a list written by add is clean" "0" "$("$NY" check --project "$G" >/dev/null 2>&1; echo $?)"
printf '# Needs you\n- **A1** HOLD: nothing to do\n' > "$G/.swarm/needs-you.md"
check "check: a hand-edited list is flagged" "3" "$("$NY" check --project "$G" >/dev/null 2>&1; echo $?)"
HW="$T/hwproj"; mkdir -p "$HW/.swarm"; printf '# Needs you\n- **A1** stub\n' > "$HW/.swarm/needs-you.md"
check "check: a md with no store is flagged" "3" "$("$NY" check --project "$HW" >/dev/null 2>&1; echo $?)"
check "render --write clears a stale hand-written list (no store)" "0" "$("$NY" render --write --project "$HW" >/dev/null 2>&1; "$NY" check --project "$HW" >/dev/null 2>&1; echo $?)"
check "...and leaves an empty list" "Nothing to do." "$(tail -1 "$HW/.swarm/needs-you.md")"
OLD="$T/oldproj"; mkdir -p "$OLD"; "$NY" add --check-source operator --background "$BG" --project "$OLD" --title "Old layout item" --do 'Say `go`' >/dev/null
sed -i '/What this is:/d' "$OLD/.swarm/needs-you.md"
check "check: an older-layout list (same labels) is not flagged" "0" "$("$NY" check --project "$OLD" >/dev/null 2>&1; echo $?)"
check "check: no md at all is fine" "0" "$("$NY" check --project "$T/none" >/dev/null 2>&1; echo $?)"

# ── verification stamp (issue #680): claim, verified, verify, unverified-since ──
export TZ=UTC   # render shows local time; pin it so the "01-01" checks hold anywhere
V="$T/vproj"; mkdir -p "$V/.swarm"
"$NY" add --check-source operator --project "$V" --background "$BG" --title "Unblock fand-app 1810" --claim "only ci.yml builds with Gradle" --do 'Edit `.github/workflows/ci.yml` line 31: add `submodules: true`' >/dev/null
out="$("$NY" render --project "$V")"
case "$out" in *"Claim: only ci.yml builds with Gradle — verified "*) got=yes ;; *) got=no ;; esac
check "a fresh item renders its claim with a verified time" "yes" "$got"
check "a fresh item is not marked unverified" "0" "$(grep -c unverified <<<"$out" || true)"
check "the rendered item passes the reply lint" "" "$("$LINT" <<<"$out" | cut -d: -f1 | paste -sd, -)"
# age the stamp: render flags it
jq -c '.verified = "2026-01-01T00:00:00Z"' "$V/.swarm/needs-you.jsonl" > "$T/v.jsonl" && mv "$T/v.jsonl" "$V/.swarm/needs-you.jsonl"
case "$("$NY" render --project "$V")" in *"Claim: only ci.yml builds with Gradle — (unverified since 01-01 "*) got=yes ;; *) got=no ;; esac
check "an old stamp renders (unverified since <time>)" "yes" "$got"
"$NY" verify A1 --claim "only ci.yml builds with Gradle; the other 2 workflows only ls the migrations dir" --project "$V"
case "$("$NY" render --project "$V")" in *"the other 2 workflows"*"— verified "*) got=yes ;; *) got=no ;; esac
check "verify restamps the item and can correct the claim" "yes" "$got"
set +e; "$NY" verify A9 --project "$V" >/dev/null 2>&1; ec=$?; set -e
check "verify on an unknown label fails" "2" "$ec"
printf '{"label":"A1","kind":"todo","title":"old item","do":"run `x`","risk":"","rec":"","default":"","url":"","added":"2026-01-01T00:00:00Z","done":false}\n' > "$V/.swarm/needs-you.jsonl"
case "$("$NY" render --project "$V")" in *"(unverified since 01-01 "*) got=yes ;; *) got=no ;; esac
check "a pre-#680 item with no stamp falls back to its added time" "yes" "$got"

# ── real --check (issue #1017) ───────────────────────────────────────────────
K="$T/kproj"; mkdir -p "$K/.swarm"; KDONE="$T/kdone"
kadd() { "$NY" add --project "$K" --background "$BG" --title "Deploy it" --do 'Run `./deploy.sh`' "$@" 2>&1; }
set +e; kadd --check 'test -e /nonexistent-1017' >/dev/null; ec=$?; set -e
check "add refuses an item whose --check exits non-zero" "2" "$ec"
set +e; kadd >/dev/null; ec=$?; set -e
check "add refuses an item with no check at all" "2" "$ec"
check "refused adds leave no store" "none" "$([ -s "$K/.swarm/needs-you.jsonl" ] && echo some || echo none)"
check "add with a passing --check files the item" "A1" "$(kadd --check "test ! -e $KDONE && echo still-needed" | tail -1)"
check "the check result is stored" "0|still-needed" "$(jq -r '[.checkResult, .checkOutput] | join("|")' "$K/.swarm/needs-you.jsonl")"
case "$("$NY" render --project "$K")" in *"Check: test ! -e"*"→ exit 0 at "*) got=yes ;; *) got=no ;; esac
check "render shows the check and its exit code" "yes" "$got"
check "--check-source operator is accepted without a command" "A2" "$(kadd --check-source operator | tail -1)"
case "$("$NY" render --project "$K")" in *"Source: operator-stated, not machine-checked"*) got=yes ;; *) got=no ;; esac
check "render marks an operator-sourced item" "yes" "$got"
"$NY" verify A1 --project "$K"; check "verify re-runs a still-passing check" "0" "$?"
touch "$KDONE"
set +e; "$NY" verify A1 --project "$K" >/dev/null 2>&1; ec=$?; set -e
check "verify exits 1 when the check now fails" "1" "$ec"
check "the failed result is stored" "1" "$(jq -r 'select(.label == "A1") | .checkResult' "$K/.swarm/needs-you.jsonl")"
case "$("$NY" render --project "$K")" in *"CHECK FAILED (exit 1)"*) got=yes ;; *) got=no ;; esac
check "render flags the failed check" "yes" "$got"
check "the failed item stays open" "A1,A2" "$("$NY" render --json --project "$K" | jq -r 'map(.label) | join(",")')"

# ── ask-not-listed (issue #1017) ─────────────────────────────────────────────
ask() { "$LINT" --only ask-not-listed | cut -d: -f1 | sort -u | paste -sd, -; }
check "ask: a Pending-approval line with no label is a hit" "ask-not-listed" "$(printf 'Done.\nPending your approval: deploy fand-app to kdeyoga (yes/no)\n' | ask)"
check "ask: a Pending-approval line naming a Needs-you label passes" "" "$(printf 'Pending your approval: A1 (yes/no)\n' | ask)"
check "ask: 'Nothing needed from you' passes" "" "$(printf 'Nothing needed from you right now\n' | ask)"
check "ask: a Pending-approval line inside a fence is ignored" "" "$(printf '```\nPending your approval: deploy\n```\n' | ask)"

# ── Stop hook ────────────────────────────────────────────────────────────────
H="$T/hproj"; mkdir -p "$H/.swarm/coord-inbox"
stop() {   # <fixture> <stop_hook_active>  (mode from HM: resident|split)
    [ "${HM:-resident}" = split ] && echo "COORD_MODE=split" > "$H/.swarm/.env" || rm -f "$H/.swarm/.env"
    jq -n --rawfile m "$1" --argjson a "$2" '{last_assistant_message: $m, stop_hook_active: $a}' \
        | CLAUDE_PROJECT_DIR="$H" COORD_HOOK_STATE="${HS:-1}" "$HOOK" Stop
}
out="$(stop "$FX/clean-render.txt" false)"
check "resident: clean reply -> no block" "" "$out"
out="$(stop "$FX/incident-start-load.txt" false)"
check "resident: back-reference -> block" "block" "$(jq -r .decision <<<"$out")"
case "$(jq -r .reason <<<"$out")" in *"needs-you.sh render"*) got=yes ;; *) got=no ;; esac
check "block reason says how to fix it" "yes" "$got"
case "$(jq -r .reason <<<"$out")" in *"do NOT reprint"*"Correction:"*) got=yes ;; *) got=no ;; esac
check "#1008 block reason asks for a short correction, not a reprint" "yes" "$got"
grep -q 'coord.reply_lint.hit rules=backref,no-command' "$H/.swarm/events.log" && got=yes || got=no
check "hit counted in events.log" "yes" "$got"
out="$(stop "$FX/incident-start-load.txt" true)"
check "second stop (stop_hook_active) never blocks again" "" "$out"
grep -q 'coord.reply_lint.unfixed' "$H/.swarm/events.log" && got=yes || got=no
check "still-failing reply counted as unfixed" "yes" "$got"
out="$(HM=split stop "$FX/incident-contradictory-ending.txt" false)"
check "split mode: lint blocks too" "block" "$(jq -r .decision <<<"$out")"
out="$(HM=split HS=0 stop "$FX/clean-nothing.txt" false)"
check "split mode: clean reply -> silent" "" "$out"
out="$(COORD_REPLY_LINT=0 stop "$FX/incident-start-load.txt" false)"
check "COORD_REPLY_LINT=0 disables it" "" "$out"
out="$(PATH="$T/ghbin:$PATH" stop "$FX/incident-issue-merged.txt" false)"
check "Stop hook blocks an issue-merged reply and names the fix" "block yes" "$(jq -r .decision <<<"$out") $(case "$(jq -r .reason <<<"$out")" in *"issue-merged"*"fix PR for #N merges"*) echo yes;; *) echo no;; esac)"
# #880: the hook's cwd is outside the project; the lookup must still run in
# CLAUDE_PROJECT_DIR. This gh stub only answers when its cwd is the project.
mkdir -p "$T/ghcwd" "$T/elsewhere"
cat > "$T/ghcwd/gh" <<'GHEOF'
#!/usr/bin/env bash
[ "$PWD" = "$GH_WANT_CWD" ] || exit 1
case "$2" in */issues/1910) echo false ;; *) exit 1 ;; esac
GHEOF
chmod +x "$T/ghcwd/gh"
out="$(cd "$T/elsewhere" && GH_WANT_CWD="$(cd "$H" && pwd)" PATH="$T/ghcwd:$PATH" stop "$FX/incident-issue-merged.txt" false)"
check "Stop hook with cwd outside the project still flags '#N merges' for an issue" "block yes" "$(jq -r .decision <<<"$out") $(case "$(jq -r .reason <<<"$out")" in *"issue-merged"*) echo yes;; *) echo no;; esac)"
# resident coordinator, default COORD_HOOK_STATE=0: lint blocks, nothing else happens
rm -f "$H/.swarm/coordinator-state" "$H/.swarm/coord-hook-rang"; echo 1 > "$H/.swarm/coord-hook-rang"
echo "worker finished" > "$H/.swarm/coord-inbox/b.md"
out="$(HS=0 stop "$FX/incident-start-load.txt" false)"
check "resident + COORD_HOOK_STATE=0: lint blocks (default install)" "block" "$(jq -r .decision <<<"$out")"
case "$(jq -r .reason <<<"$out")" in "Reply lint failed"*) got=lint-only ;; *) got="$(jq -r .reason <<<"$out")" ;; esac
check "...with no doorbell text" "lint-only" "$got"
check "...and no state file written" "none" "$([ -e "$H/.swarm/coordinator-state" ] && echo some || echo none)"
out="$(HS=0 stop "$FX/clean-nothing.txt" false)"
check "resident + COORD_HOOK_STATE=0: clean reply -> silent, no ring" "" "$out"
rm -f "$H/.swarm/coord-inbox/b.md"
# transcript fallback
jq -cn --rawfile m "$FX/incident-quiet-pointer.txt" '{type:"assistant",message:{content:[{type:"text",text:$m}]}}' > "$T/tr.jsonl"
out="$(jq -n --arg p "$T/tr.jsonl" '{transcript_path: $p, stop_hook_active: false}' | CLAUDE_PROJECT_DIR="$H" COORD_HOOK_STATE=1 "$HOOK" Stop)"
check "reads the last reply from the transcript when no last_assistant_message" "block" "$(jq -r .decision <<<"$out")"
# a pending doorbell and a lint hit share one block
echo 1 > "$H/.swarm/coord-hook-rang"; echo "worker finished" > "$H/.swarm/coord-inbox/a.md"
out="$(stop "$FX/incident-start-load.txt" false)"
case "$(jq -r .reason <<<"$out")" in "Inbox: 1 item(s)"*"Reply lint failed"*) got=both ;; *) got="$(jq -r .reason <<<"$out")" ;; esac
check "doorbell and lint ride one block" "both" "$got"


# ── lede-identifier (issue #979) ─────────────────────────────────────────────
lede() { "$LINT" --only lede-identifier < "$1" | cut -d: -f1 | paste -sd, -; }
for f in lede-hit-migration lede-hit-pr lede-hit-codespan lede-hit-env lede-hit-sha; do
    check "lede: $f is a hit" "lede-identifier" "$(lede "$FX/$f.txt")"
done
for f in lede-pass-woke lede-pass-both lede-pass-plain lede-pass-fence lede-pass-short; do
    check "lede: $f passes" "" "$(lede "$FX/$f.txt")"
done
# --skip drops a rule, keeps the rest
check "lede: --skip lede-identifier drops it" "" "$($LINT --skip lede-identifier < "$FX/lede-hit-pr.txt" | cut -d: -f1 | grep -x lede-identifier || true)"
check "lede: --skip keeps other rules" "two-endings" "$($LINT --skip lede-identifier < "$FX/../../../test-fixtures/checks/two-endings/fail.txt" | cut -d: -f1 | grep -x two-endings | sort -u)"
# "e.g." is not a sentence end: the identifier after it is still inside the first sentence
printf 'e.g. `x.sh` broke.\n' > "$T/lede-eg.txt"
check "lede: e.g. is not a sentence end" "lede-identifier" "$(lede "$T/lede-eg.txt")"
printf 'Both fixes landed, i.e. the build is green. `x.sh` is next.\n' > "$T/lede-ie.txt"
check "lede: i.e. mid-sentence still passes when plain words lead" "" "$(lede "$T/lede-ie.txt")"
H2="$T/hlede"; mkdir -p "$H2/.swarm/coord-inbox"
lstop2() { jq -n --rawfile m "$FX/lede-hit-pr.txt" '{last_assistant_message: $m, stop_hook_active: false}' | CLAUDE_PROJECT_DIR="$H2" COORD_HOOK_STATE=0 "$@" "$HOOK" Stop; }
check "lede: default (warn) never blocks" "" "$(lstop2 env)"
grep -q 'coord.reply_lint.hit rules=lede-identifier' "$H2/.swarm/events.log" && got=yes || got=no
check "lede: warn logs the hit" "yes" "$got"
check "lede: off never blocks" "" "$(lstop2 env COORD_REPLY_LINT_LEDE=off)"
rm -f "$H2/.swarm/coord-lint-blocked"
check "lede: block mode blocks" "block" "$(lstop2 env COORD_REPLY_LINT_LEDE=block | jq -r .decision)"

# ── repeat-item (issue #980) ─────────────────────────────────────────────────
rep() { "$LINT" --only repeat-item < "$1" | cut -d: -f1 | paste -sd, -; }
for f in repeat-hit-four-times repeat-hit-list-and-pending; do
    check "repeat: $f is a hit" "repeat-item" "$(rep "$FX/$f.txt")"
done
check "repeat: A87/A89 + one Do now fence (sm 972 && sm 974) passes" "" "$(rep "$FX/repeat-pass-list-plus-do-now.txt")"
printf -- '- **A1** Merge #972 (yes/no)\n- **A2** Merge #974 (yes/no)\n' > "$T/rep-two"
check "repeat: two items, two subjects passes" "" "$(rep "$T/rep-two")"
printf -- '- **A1** Merge #972 (yes/no)\n\nDo now: say yes to #972\n' > "$T/rep-dn"
check "repeat: Do now prose repeating a listed item is a hit" "repeat-item" "$(rep "$T/rep-dn")"
printf -- '- **A1** Merge #972 (yes/no)\n\n**In flight:** iss-973 waiting on #972\n' > "$T/rep-mention"
check "repeat: a plain mention outside an ask passes" "" "$(rep "$T/rep-mention")"
printf -- '- **A1** Merge https://github.com/o/r/pull/972\n\nPending your approval: merge #972 (yes/no)\n' > "$T/rep-urlnum"
check "repeat: URL in one ask, #N in the other still matches" "repeat-item" "$(rep "$T/rep-urlnum")"
printf -- '- **A1** Merge https://github.com/o/r/pull/972\n- **A2** Merge https://github.com/o/other/pull/972\n' > "$T/rep-repos"
check "repeat: #972 in two different repos is two items" "" "$(rep "$T/rep-repos")"
printf -- '- **A1** Merge https://github.com/o/r/pull/972\n- **A2** Merge https://github.com/o/r/pull/972\n' > "$T/rep-samerepo"
check "repeat: the same URL twice is a hit" "repeat-item" "$(rep "$T/rep-samerepo")"
H3="$T/hrep"; mkdir -p "$H3/.swarm/coord-inbox"
rstop() { jq -n --rawfile m "$FX/repeat-hit-list-and-pending.txt" '{last_assistant_message: $m, stop_hook_active: false}' | CLAUDE_PROJECT_DIR="$H3" COORD_HOOK_STATE=0 "$@" "$HOOK" Stop; }
check "repeat: default (warn) never blocks" "" "$(rstop env)"
grep -q 'coord.reply_lint.hit rules=repeat-item' "$H3/.swarm/events.log" && got=yes || got=no
check "repeat: warn logs the hit" "yes" "$got"
check "repeat: off never blocks" "" "$(rstop env COORD_REPLY_LINT_REPEAT=off)"
rm -f "$H3/.swarm/coord-lint-blocked"
check "repeat: block mode blocks" "block" "$(rstop env COORD_REPLY_LINT_REPEAT=block | jq -r .decision)"

# ── offer-to-act (issue #981) ────────────────────────────────────────────────
off() { "$LINT" --only offer-to-act < "$1" | cut -d: -f1 | sort -u | paste -sd, -; }
for f in offer-hit-issue-edit offer-hit-needs-you; do
    check "offer: $f is a hit" "offer-to-act" "$(off "$FX/$f.txt")"
done
for f in offer-pass-sm offer-pass-cd-ci-wait offer-pass-sudo offer-pass-no-ask; do
    check "offer: $f passes" "" "$(off "$FX/$f.txt")"
done
printf 'Done.\n\nDo now: auto-merge.\n```\nsm 9 --auto-low\n```\n' > "$T/off-auto"
check "offer: sm with --auto-low is coordinator-runnable: hit" "offer-to-act" "$(off "$T/off-auto")"
printf 'Done.\n\nDo now: comment.\n```\ngh issue comment 5 --body "fixed; thanks && bye"\n```\n' > "$T/off-quote"
check "offer: ; and && inside quotes do not split: hit" "offer-to-act" "$(off "$T/off-quote")"
printf 'Done.\n\nDo now: move it.\n```\n$ mv .swarm/tasks/a.md .swarm/tasks/b.md \\\n  && git push\n```\n' > "$T/off-push"
check "offer: git push after a continuation line clears the block" "" "$(off "$T/off-push")"
printf 'Done.\n\nPending your approval: label it (yes/no)\n```\ngh issue edit 12 --add-label x\n```\n' > "$T/off-pend"
check "offer: a Pending-approval block is not a Do now handover" "" "$(off "$T/off-pend")"
printf 'Done.\n\nDo now: one command.\n```\ngh issue edit 12 --add-label x\n```\n\nNote:\n```\nsudo true\n```\n' > "$T/off-two"
check "offer: only the block under Do now counts; one hit" "offer-to-act" "$(off "$T/off-two")"
printf 'Done.\n\nDo now: one command.\n\nBackground I already ran:\n```\ngh issue edit 12 --add-label x\n```\n' > "$T/off-para"
check "offer: a block after a later prose paragraph is not under Do now" "" "$(off "$T/off-para")"
printf 'Done.\n\nDo now: one command.\n```\n# don'"'"'t forget\nsudo true\n```\n' > "$T/off-apos"
check "offer: an apostrophe in a comment line cannot hide a sudo line" "" "$(off "$T/off-apos")"
printf 'Done.\n\nDo now: comment.\n```\ngh issue comment 5 --body x | sudo tee /etc/f\n```\n' > "$T/off-pipe"
check "offer: a pipe into sudo clears the block" "" "$(off "$T/off-pipe")"
H4="$T/hoffer"; mkdir -p "$H4/.swarm/coord-inbox"
ostop() { jq -n --rawfile m "$FX/offer-hit-issue-edit.txt" '{last_assistant_message: $m, stop_hook_active: false}' | CLAUDE_PROJECT_DIR="$H4" COORD_HOOK_STATE=0 "$@" "$HOOK" Stop; }
check "offer: default (warn) never blocks" "" "$(ostop env)"
grep -q 'coord.reply_lint.hit rules=offer-to-act' "$H4/.swarm/events.log" && got=yes || got=no
check "offer: warn logs the hit" "yes" "$got"
check "offer: off never blocks" "" "$(ostop env COORD_REPLY_LINT_OFFER=off)"
rm -f "$H4/.swarm/coord-lint-blocked"
check "offer: block mode blocks" "block" "$(ostop env COORD_REPLY_LINT_OFFER=block | jq -r .decision)"

# ── Stop hook: hand-written list and stale prompt (issue #964) ───────────────
W="$T/wproj"; mkdir -p "$W/.swarm"; printf '# Needs you\n- **A1** stub\n' > "$W/.swarm/needs-you.md"
wstop() {   # <stop_hook_active>
    jq -n --rawfile m "$FX/clean-render.txt" --argjson a "$1" '{last_assistant_message: $m, stop_hook_active: $a}' \
        | CLAUDE_PROJECT_DIR="$W" COORD_HOOK_STATE=0 "$HOOK" Stop
}
out="$(wstop false)"
check "hand-written needs-you.md blocks the stop" "block" "$(jq -r .decision <<<"$out")"
case "$(jq -r .reason <<<"$out")" in *"needs-you.sh add"*"--background"*) got=yes ;; *) got=no ;; esac
check "...and the reason says how to rebuild it" "yes" "$got"
check "...and is counted in events.log" "1" "$(grep -c 'coord.needs_you.handwritten' "$W/.swarm/events.log")"
check "...but never blocks the continuation (no loop)" "" "$(wstop true)"
rm -f "$W/.swarm/needs-you.md"
check "no needs-you.md: no block" "" "$(wstop false)"
printf '# Needs you\n- **A1** stub\n' > "$W/.swarm/needs-you.md"
"$ROOT/scripts/needs-you.sh" render --write --project "$W" >/dev/null
check "guard clears after render --write" "" "$(wstop false)"
case "$(jq -r .reason <<<"$out")" in *"render --write"*) got=yes ;; *) got=no ;; esac
check "rebuild message names render --write" "yes" "$got"
rm -f "$W/.swarm/needs-you.md"
LS="$T/llmswarm"; mkdir -p "$LS/prompts" "$LS/scripts"; echo one > "$LS/prompts/coordinator.md"
cp "$ROOT/scripts/"{coord-hook.sh,needs-you.sh,_coord-split.sh,_coord-inbox-batch.sh,_watch-pause.sh,_window-flags.sh,lint-coordinator-reply.sh,watcher-check.sh,_load-env.sh} "$LS/scripts/" 2>/dev/null || true
. "$ROOT/scripts/_coord-split.sh"; coord_prompt_hash "$LS" > "$W/.swarm/coord-prompt.sha"
lstop() { jq -n '{last_assistant_message: "ok", stop_hook_active: false}' | CLAUDE_PROJECT_DIR="$W" COORD_HOOK_STATE=0 "$LS/scripts/coord-hook.sh" Stop; }
check "unchanged prompt: no nudge" "" "$(lstop)"
echo two > "$LS/prompts/coordinator.md"
case "$(lstop | jq -r .reason)" in *"Coordinator prompt changed"*"Standing list"*) got=yes ;; *) got=no ;; esac
check "changed prompt: one nudge naming the Standing list" "yes" "$got"
check "...and it does not repeat for the same change" "" "$(lstop)"
echo "all reply-lint checks passed"
