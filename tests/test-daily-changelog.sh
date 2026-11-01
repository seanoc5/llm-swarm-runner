#!/usr/bin/env bash
#
# test-daily-changelog.sh — Non-LLM regression test for
# scripts/daily-changelog.sh. gh is a PATH shim serving a fixture PR list
# (with the real --jq applied to follow-up issue lookups); curl is a PATH
# shim that fakes corpusminder's /api/threads endpoints against a local
# comments file and logs every call.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="$SCRIPT_DIR/../scripts/daily-changelog.sh"
[ -x "$CHANGELOG" ] || red "daily-changelog.sh not executable: $CHANGELOG"

T=$(mktemp -d -t daily-changelog-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shims" "$T/keys" "$T/app1" "$T/app2"
CURL_LOG="$T/curl.log"
COMMENTS="$T/comments.json"

# Local day 2026-10-31 in America/New_York (EDT, UTC-4) is
# 2026-10-31T04:00Z .. 2026-11-01T04:00Z.
cat > "$T/prs.json" <<'EOF'
[
  {"number": 10, "title": "[agent] fix(country): stop the wealth chart at the horizon (#9)",
   "url": "https://github.com/o/app1/pull/10", "mergedAt": "2026-10-31T15:00:00Z",
   "body": "x\n<!-- BLIND_MERGE_RISK: low -->\n<!-- BLIND_MERGE_RISK: high -->", "comments": []},
  {"number": 11, "title": "feat(what): add sum-of-children check",
   "url": "https://github.com/o/app1/pull/11", "mergedAt": "2026-11-01T03:30:00Z",
   "body": "<!-- BLIND_MERGE_RISK: medium -->",
   "comments": [{"body": "SWARM_SELF_REVIEW: APPROVE actor=coordinator head=abc"},
                {"body": "SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=coordinator head=def"},
                {"body": "SWARM_SELF_REVIEW: APPROVE actor=worker"}]},
  {"number": 12, "title": "Plain title with no prefix",
   "url": "https://github.com/o/app1/pull/12", "mergedAt": "2026-10-31T10:00:00Z",
   "body": null,
   "comments": [{"body": "SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=coordinator"},
                {"body": "SWARM_SELF_REVIEW: APPROVE actor=coordinator"}]},
  {"number": 13, "title": "fix: merged the evening before, UTC says the 31st",
   "url": "https://github.com/o/app1/pull/13", "mergedAt": "2026-10-31T03:00:00Z",
   "body": "<!-- BLIND_MERGE_RISK: low -->", "comments": []},
  {"number": 14, "title": "fix: merged after local midnight",
   "url": "https://github.com/o/app1/pull/14", "mergedAt": "2026-11-01T04:00:00Z",
   "body": "", "comments": []}
]
EOF
echo '[{"url": "https://github.com/o/app1/issues/20"}]' > "$T/issues-11.json"

cat > "$T/shims/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr list")
    [ "\${GH_FAILS:-0}" = 1 ] && exit 1
    case "\$*" in *"-R o/app1 "*) cat "$T/prs.json" ;; *"-R o/app3 "*) cat "$T/prs3.json" ;; *) echo '[]' ;; esac ;;
  "issue list")
    label="\$(printf '%s\n' "\$@" | grep -A0 '^from-pr-' | sed 's/from-pr-//')"
    f="$T/issues-\$label.json"; [ -f "\$f" ] || f=/dev/null
    jq -r "\${*: -1}" < <(cat "\$f" 2>/dev/null || echo '[]') 2>/dev/null || echo '[]' ;;
  *) echo "unexpected gh \$*" >&2; exit 9 ;;
esac
EOF

cat > "$T/shims/curl" <<EOF
#!/usr/bin/env bash
method=GET data="" hdr="" url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method="\$2"; shift 2 ;;
    --data-binary) data="\$2"; shift 2 ;;
    -H) case "\$2" in @*) hdr="\${2#@}" ;; esac; shift 2 ;;
    -m|-w) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
key="\$(sed -n 's/^X-Api-Key: //p' "\$hdr" 2>/dev/null)"
echo "\$method \$url key=\$key" >> "$CURL_LOG"
[ "\$key" = "cmapi_1_secret" ] || { printf '{"error":"unauthorized"}\n401'; exit 0; }
[ -f "$COMMENTS" ] || echo '[]' > "$COMMENTS"
case "\$method \$url" in
  "POST "*/api/threads)
    [ "\${CM_NULL_QID:-0}" = 1 ] && { printf '{"created": true}\n201'; exit 0; }
    printf '%s\n201' '{"questionId": 42, "url": "http://lan/questions/42", "created": true}' ;;
  "GET "*/api/threads/*)
    printf '%s\n200' "\$(jq -c '{thread: {questionId: 42}, comments: [.[] | {text: ., replies: []}]}' "$COMMENTS")" ;;
  "POST "*/comments*)
    [ "\${CM_POST_FAILS:-0}" = 1 ] && { printf '{"error":"boom"}\n500'; exit 0; }
    jq --arg t "\$(jq -r .text <<<"\$data")" '. + [\$t]' "$COMMENTS" > "$COMMENTS.tmp" && mv "$COMMENTS.tmp" "$COMMENTS"
    printf '{"id": %s}\n201' "\$(jq length "$COMMENTS")" ;;
  *) printf 'nope\n404' ;;
esac
EOF
chmod +x "$T/shims/gh" "$T/shims/curl"

cat > "$T/apps.conf" <<EOF
# comment line
app1 $T/app1 o/app1 app-one

app2 $T/app2 o/app2 app-two
EOF

run() {
    PATH="$T/shims:$PATH" CHANGELOG_CONF="$T/apps.conf" CHANGELOG_KEY_DIR="$T/keys" \
        CHANGELOG_TZ=America/New_York CM_BASE_URL=http://cm.test CM_PUBLIC_URL=https://cm.public \
        "$CHANGELOG" --date 2026-10-31 "$@" > "$T/out.log" 2>&1
}
out() { cat "$T/out.log"; }

heading "Test 1: dry run renders the local day's PRs in merge order and touches nothing"
run --dry-run || red "expected exit 0: $(out)"
grep -qx '## app1: 3 changes merged on Saturday, 31 October 2026' "$T/out.log" || red "heading: $(out)"
grep -q '/pull/13\|/pull/14' "$T/out.log" && red "PRs outside the local day leaked in: $(out)"
order="$(grep -o 'pull/1[0-9]' "$T/out.log" | tr '\n' ' ')"
[ "$order" = "pull/12 pull/10 pull/11 " ] || red "expected merge order 12 10 11, got: $order"
grep -qx -- '- 🟢 Fix: Stop the wealth chart at the horizon — https://github.com/o/app1/pull/10' "$T/out.log" \
    || red "first risk marker wins, prefix and (#N) stripped: $(out)"
grep -qx -- '- 🟡 New: Add sum-of-children check — https://github.com/o/app1/pull/11' "$T/out.log" || red "feat line: $(out)"
grep -qx -- '- ⚪ Change: Plain title with no prefix — https://github.com/o/app1/pull/12' "$T/out.log" || red "unrated line: $(out)"
grep -qx -- '  - ⚠️ Merged with reviewer caveats. Follow-up: https://github.com/o/app1/issues/20' "$T/out.log" \
    || red "latest coordinator verdict caveats + follow-up: $(out)"
[ "$(grep -c 'reviewer caveats' "$T/out.log")" = 1 ] || red "only #11 should carry caveats (#12's latest coordinator verdict is APPROVE): $(out)"
grep -qx '_Daily changelog · app1 · 2026-10-31_' "$T/out.log" || red "footer: $(out)"
grep -qx 'app2: nothing merged on 2026-10-31' "$T/out.log" || red "empty app line: $(out)"
[ ! -e "$CURL_LOG" ] || red "dry run called curl"
[ ! -e "$T/app1/.swarm" ] || red "dry run wrote files"
green "local-day window, ordering, title cleanup, risk, caveats, no side effects"

heading "Test 2: missing key writes the digest, posts nothing, warns and exits 0 naming the key"
rc=0; run || rc=$?
[ "$rc" = 0 ] || red "expected exit 0, got $rc: $(out)"
grep -q "WARNING.*no key at $T/keys/app-one.key" "$T/out.log" || red "should name the key path: $(out)"
[ -s "$T/app1/.swarm/changelog/2026-10-31.md" ] || red "md not written"
jq -e '.count == 3 and .prs[0].number == 12 and .prs[2].followups == ["https://github.com/o/app1/issues/20"]' \
    "$T/app1/.swarm/changelog/2026-10-31.json" >/dev/null || red "json shape"
[ ! -e "$T/app1/.swarm/changelog/2026-10-31.posted" ] || red "should not be marked posted"
[ ! -e "$T/app2/.swarm" ] || red "nothing-merged app should write nothing"
green "digest kept for the in-app page even without a credential"

heading "Test 3: with a key, finds/creates the thread and posts once"
printf 'CORPUSMINDER_API_KEY=cmapi_1_secret\n' > "$T/keys/app-one.key"
run || red "expected exit 0: $(out)"
grep -qx 'app1: posted 2026-10-31 — https://cm.public/questions/42' "$T/out.log" || red "posted line: $(out)"
grep -q '^POST http://cm.test/api/threads key=cmapi_1_secret$' "$CURL_LOG" || red "thread find-or-create: $(cat "$CURL_LOG")"
grep -q '^POST http://cm.test/api/threads/app-one/changelog/comments?externalId=app1 ' "$CURL_LOG" || red "comment post url: $(cat "$CURL_LOG")"
[ "$(jq length "$COMMENTS")" = 1 ] || red "expected one post"
jq -r '.[0]' "$COMMENTS" | head -1 | grep -qx '## app1: 3 changes merged on Saturday, 31 October 2026' || red "posted body"
[ "$(cat "$T/app1/.swarm/changelog/2026-10-31.posted")" = 1 ] || red "posted marker holds comment id"
jq -e '.questionId == 42 and .url == "https://cm.public/questions/42"' "$T/app1/.swarm/changelog/thread.json" >/dev/null || red "thread.json"
green "one post, thread id stored"

heading "Test 4: re-run is a no-op (local marker), and a lost marker is caught by the thread read"
: > "$CURL_LOG"
run || red "rerun exit: $(out)"
grep -qx 'app1: already posted for 2026-10-31' "$T/out.log" || red "marker skip: $(out)"
[ ! -s "$CURL_LOG" ] || red "marker skip should not call curl"
rm "$T/app1/.swarm/changelog/2026-10-31.posted"
run || red "rerun exit: $(out)"
grep -q 'app1: already posted for 2026-10-31 (found in thread)' "$T/out.log" || red "remote dedupe: $(out)"
[ "$(jq length "$COMMENTS")" = 1 ] || red "double post!"
green "never double-posts"

heading "Test 5: post failure exits 1 and keeps the digest; gh failure exits 1"
rm -f "$T/app1/.swarm/changelog/2026-10-31.posted"; echo '[]' > "$COMMENTS"
rc=0; CM_POST_FAILS=1 run || rc=$?
[ "$rc" = 1 ] || red "expected exit 1, got $rc: $(out)"
grep -q 'HTTP 500' "$T/out.log" || red "should show HTTP status: $(out)"
[ ! -e "$T/app1/.swarm/changelog/2026-10-31.posted" ] || red "failed post must not be marked"
grep -q cmapi_1_secret "$T/out.log" && red "key leaked into output"
rc=0; GH_FAILS=1 run --dry-run || rc=$?
[ "$rc" = 1 ] || red "gh failure should exit 1, got $rc"
green "failures are loud and retryable"

heading "Test 6: usage errors"
rc=0; run --app nosuch || rc=$?; [ "$rc" = 2 ] || red "unknown --app should exit 2"
rc=0; run --date 31/10/2026 || rc=$?; [ "$rc" = 2 ] || red "bad --date should exit 2"
run --dry-run --app app2 || red "--app filter exit"
grep -q app1 "$T/out.log" && red "--app app2 should skip app1"
green "bad input refused"

heading "Test 7: a 3-day gap since the last .posted marker posts all three days, oldest first"
cat > "$T/prs3.json" <<'JSON'
[
  {"number": 30, "title": "fix: day before the gap (already posted)",
   "url": "https://github.com/o/app3/pull/30", "mergedAt": "2026-10-28T15:00:00Z", "body": "", "comments": []},
  {"number": 31, "title": "fix: first missed day",
   "url": "https://github.com/o/app3/pull/31", "mergedAt": "2026-10-29T15:00:00Z", "body": "", "comments": []},
  {"number": 32, "title": "fix: second missed day",
   "url": "https://github.com/o/app3/pull/32", "mergedAt": "2026-10-30T15:00:00Z", "body": "", "comments": []},
  {"number": 33, "title": "fix: yesterday",
   "url": "https://github.com/o/app3/pull/33", "mergedAt": "2026-10-31T15:00:00Z", "body": "", "comments": []}
]
JSON
printf 'app3 %s o/app3 app-three\n' "$T/app3" > "$T/apps3.conf"
printf 'CORPUSMINDER_API_KEY=cmapi_1_secret\n' > "$T/keys/app-three.key"
mkdir -p "$T/app3/.swarm/changelog"
echo 1 > "$T/app3/.swarm/changelog/2026-10-28.posted"
echo '[]' > "$COMMENTS"; : > "$CURL_LOG"
run_gap() {
    PATH="$T/shims:$PATH" CHANGELOG_CONF="$T/apps3.conf" CHANGELOG_KEY_DIR="$T/keys" \
        CHANGELOG_TZ=America/New_York CHANGELOG_YESTERDAY=2026-10-31 \
        CM_BASE_URL=http://cm.test CM_PUBLIC_URL=https://cm.public \
        "$CHANGELOG" "$@" > "$T/out.log" 2>&1
}
run_gap || red "gap run should exit 0: $(out)"
[ "$(jq length "$COMMENTS")" = 3 ] || red "expected 3 posts for the 3 missed days, got $(jq length "$COMMENTS"): $(out)"
for d in 2026-10-29 2026-10-30 2026-10-31; do
    [ -e "$T/app3/.swarm/changelog/$d.posted" ] || red "$d not marked posted: $(out)"
done
[ ! -e "$T/app3/.swarm/changelog/2026-10-28.md" ] || red "already-posted day must not be re-reported"
jq -r '.[0]' "$COMMENTS" | grep -q 'pull/31' || red "oldest missed day should post first"
jq -r '.[2]' "$COMMENTS" | grep -q 'pull/33' || red "yesterday should post last"
: > "$CURL_LOG"
run_gap || red "rerun exit: $(out)"
grep -qx 'app3: already posted through 2026-10-31' "$T/out.log" || red "rerun should be a no-op: $(out)"
[ ! -s "$CURL_LOG" ] || red "no-op rerun should not call curl"
green "gap since last marker is caught up; rerun posts nothing"

heading "Test 8: a gap longer than the cap posts only the newest days and says what it skipped"
rm -f "$T/app3/.swarm/changelog/2026-10-29".* "$T/app3/.swarm/changelog/2026-10-30".* "$T/app3/.swarm/changelog/2026-10-31".*
echo '[]' > "$COMMENTS"
CHANGELOG_MAX_BACKFILL=2 run_gap || red "capped run exit: $(out)"
[ "$(jq length "$COMMENTS")" = 2 ] || red "cap of 2 should post 2 days: $(out)"
grep -q 'skipping the 1 oldest' "$T/out.log" || red "should log the skipped day: $(out)"
[ ! -e "$T/app3/.swarm/changelog/2026-10-29.posted" ] || red "oldest day should be skipped"
green "cap honoured and logged"

heading "Test 9: a thread response without questionId refuses, exits 1, writes no thread.json"
rm -rf "$T/app3/.swarm/changelog/thread.json" "$T/app3/.swarm/changelog/2026-10-3"*.posted
echo '[]' > "$COMMENTS"
rc=0; CM_NULL_QID=1 run_gap --date 2026-10-31 || rc=$?
[ "$rc" = 1 ] || red "expected exit 1, got $rc: $(out)"
grep -q 'no usable questionId' "$T/out.log" || red "should explain the refusal: $(out)"
[ ! -e "$T/app3/.swarm/changelog/thread.json" ] || red "thread.json must not be written"
[ "$(jq length "$COMMENTS")" = 0 ] || red "nothing may be posted"
[ ! -e "$T/app3/.swarm/changelog/2026-10-31.posted" ] || red "must not be marked posted"
grep -q 'questions/null' "$T/out.log" && red "null id leaked into a URL"
green "null questionId refused cleanly"

heading "Test 10: merge.done lines written by swarm-merge.sh's own code tag only unattended merges"
# Pull the real log_event and the real MERGE_MODE/merge.done lines out of
# swarm-merge.sh and run them, so a changed field order or mode value there
# breaks this test instead of silently dropping the "(auto-merged)" tags.
MERGE_SH="$SCRIPT_DIR/../scripts/swarm-merge.sh"
log_event_def="$(sed -n '/^log_event() {$/,/^}$/p' "$MERGE_SH")"
mode_line="$(grep -F 'MERGE_MODE=operator' "$MERGE_SH" | head -1)"
done_line="$(grep -F 'log_event merge.done' "$MERGE_SH" | head -1)"
[ -n "$log_event_def" ] && [ -n "$mode_line" ] && [ -n "$done_line" ] \
    || red "could not extract log_event / merge.done lines from swarm-merge.sh"
mkdir -p "$T/app1/.swarm"
EVENTS_LOG="$T/app1/.swarm/events.log"; : > "$EVENTS_LOG"
emit_merge_done() {  # emit_merge_done PR AUTO_LOW AUTO_RATING
    ( PR_NUM="$1" ISSUE=99 AUTO_LOW="$2" AUTO_RATING="$3" EVENTS_LOG="$EVENTS_LOG"
      eval "$log_event_def"; eval "$mode_line"; eval "$done_line" )
}
emit_merge_done 10 1 low
emit_merge_done 11 1 medium
emit_merge_done 12 0 ""
printf '2026-10-31T09:00:00Z  merge.gate      pr=13 issue=none mode=unattended-low\n' >> "$EVENTS_LOG"
grep -c 'merge\.done' "$EVENTS_LOG" | grep -qx 3 || red "expected 3 merge.done lines: $(cat "$EVENTS_LOG")"
grep -q 'merge\.done .*pr=10 .*mode=unattended-low' "$EVENTS_LOG" || red "fixture shape drifted: $(cat "$EVENTS_LOG")"
run --dry-run --app app1 || red "dry run exit: $(out)"
grep -qx -- '- 🟢 Fix: Stop the wealth chart at the horizon (auto-merged) — https://github.com/o/app1/pull/10' "$T/out.log" \
    || red "unattended-low should be tagged: $(out)"
grep -qx -- '- 🟡 New: Add sum-of-children check (auto-merged) — https://github.com/o/app1/pull/11' "$T/out.log" \
    || red "unattended-medium should be tagged: $(out)"
grep -qx -- '- ⚪ Change: Plain title with no prefix — https://github.com/o/app1/pull/12' "$T/out.log" \
    || red "operator merge must not be tagged: $(out)"
[ "$(grep -c '(auto-merged)' "$T/out.log")" = 2 ] || red "expected exactly 2 auto-merged tags: $(out)"
green "merge.done contract: unattended-low/medium tagged, operator and non-merge.done lines not"

echo
green "All daily-changelog tests passed"
