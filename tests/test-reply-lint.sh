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
HOOK="$ROOT/scripts/coord-hook.sh"
FX="$ROOT/tests/fixtures/reply-lint"
T="$(mktemp -d -t reply-lint-XXXXXX)"
trap 'rm -rf "$T"' EXIT

rules() { "$LINT" < "$1" | cut -d: -f1 | sort -u | paste -sd, -; }

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
check "Pending your approval + Do now: two-endings" "two-endings" "$(rules "$T/two")"
printf -- '- **A1** Click the Approve button\n  https://github.com/o/r/pull/4 (Files changed > Review)\n' > "$T/url"
check "a click item with an https URL is clean" "" "$(rules "$T/url")"

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
gl() { PATH="$T/ghbin:$PATH" "$LINT" "$@"; }
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
set +e; gl < "$FX/incident-issue-merged.txt" >/dev/null; ec=$?; set -e
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
set +e; "$NY" add --project "$P" --title "Start load" --do "Start it in 1:util" >/dev/null 2>&1; ec=$?; set -e
check "add refuses a --do with no command or URL" "2" "$ec"
set +e; "$NY" add --project "$P" --title "Start load" --do 'run the command above `x`' >/dev/null 2>&1; ec=$?
"$NY" add --project "$P" --title "Start load" >/dev/null 2>&1; ec2=$?; set -e
check "add refuses a back-reference and a missing --do" "2 2" "$ec $ec2"
set +e; "$NY" add --project "$T/bproj" --title "Start load" --do "$(printf 'run the command below
```
./load.sh
```')" >/dev/null 2>&1; ec=$?; set -e
check "add accepts 'the command below' followed by a fence" "0" "$ec"
rm -rf "$T/bproj"
check "refused items leave no store" "none" "$([ -e "$P/.swarm/needs-you.jsonl" ] && echo some || echo none)"
check "add prints the label" "A1" "$("$NY" add --project "$P" --title "Load kdeyoga data" --risk "writes dev DB" --rec "yes, high confidence" --do 'In 1:util run `./load-tiger.sh kdeyoga`')"
"$NY" add --project "$P" --title "PR 689" --kind decision --do 'Say `merge PR 689`' --url https://github.com/o/r/pull/689 >/dev/null
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
check "labels are never reused" "A3" "$("$NY" add --project "$P" --title t --do 'run `x`')"
"$NY" done A2 --project "$P"; "$NY" done A3 --project "$P"
# a fenced --do: the fence must open on its own line and Do now: must show the command
F="$T/fproj"; mkdir -p "$F/.swarm"
"$NY" add --project "$F" --title "Load data" --do "$(printf '```\n./load.sh kdeyoga\n```')" >/dev/null
out="$("$NY" render --project "$F")"
check "fenced --do: opening fence starts its own line" "1" "$(grep -c '^```$' <<<"$out" | awk '{print ($1 == 2) ? 1 : 0}')"
check "fenced --do: Do now shows the command, not a bare fence" "Do now: A1 — ./load.sh kdeyoga" "$(grep '^Do now:' <<<"$out")"
check "fenced --do: render passes the reply lint" "" "$("$LINT" <<<"$out" | cut -d: -f1 | paste -sd, -)"
check "empty list renders 'Nothing to do.'" "Nothing to do." "$("$NY" render --project "$P" | tail -1)"

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

echo "all reply-lint checks passed"
