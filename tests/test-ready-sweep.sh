#!/usr/bin/env bash
#
# test-ready-sweep.sh — Non-LLM regression test for scripts/ready-sweep.sh
# (issue #602): only drafts whose SWARM_DRAFT_REASON banner is ci-pending
# or ci-unknown get pr-ready.sh re-run. gh is a PATH shim that returns the
# fixture PR list (and, for #635 trigger lookups, applies the real --jq to a
# per-PR state fixture); pr-ready.sh is replaced via PR_READY_SCRIPT.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SCRIPT_DIR/../scripts/ready-sweep.sh"
[ -x "$SWEEP" ] || red "ready-sweep.sh not executable: $SWEEP"

TEST_DIR=$(mktemp -d -t ready-sweep-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/shims"
FIXTURE="$TEST_DIR/prs.json"
READY_LOG="$TEST_DIR/ready.log"
STATES="$TEST_DIR/states.json"
echo "{}" > "$STATES"

cat > "$TEST_DIR/shims/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr view" ]; then
    # issue #635: trigger lookup — state fixture per PR number, real --jq.
    jq -c ".[\"\$3\"] // {\"state\":\"OPEN\"}" "$STATES" | jq -r "\${*: -1}"
    exit
fi
if [ "\$1 \$2" = "pr checks" ]; then
    # issue #729: per-PR CI fixture (file "checks.<N>" = rc then output); logs the call.
    echo "\$3" >> "$TEST_DIR/checks.log"
    f="$TEST_DIR/checks.\$3"
    [ -f "\$f" ] || { echo "no checks fixture" >&2; exit 2; }
    tail -n +2 "\$f"; exit "\$(head -n1 "\$f")"
fi
[ "\${GH_LIST_FAILS:-0}" = "1" ] && exit 1
printf '%s\n' "\$*" | grep -q -- '--draft' || { echo "expected --draft" >&2; exit 1; }
cat "$FIXTURE"
EOF
chmod +x "$TEST_DIR/shims/gh"

cat > "$TEST_DIR/fake-pr-ready.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$READY_LOG"
[ "\$1" = "11" ] && exit 0
exit 4
EOF
chmod +x "$TEST_DIR/fake-pr-ready.sh"

run_sweep() {
    : > "$READY_LOG"
    PATH="$TEST_DIR/shims:$PATH" PR_READY_SCRIPT="$TEST_DIR/fake-pr-ready.sh" "$SWEEP" "$@" > "$TEST_DIR/out.log" 2>&1
}

cat > "$FIXTURE" <<'EOF'
[
  {"number": 11, "body": "<!-- SWARM_DRAFT_REASON: ci-pending sha=abc -->\n> ⏳ x\n<!-- /SWARM_DRAFT_REASON -->\nbody"},
  {"number": 12, "body": "<!-- SWARM_DRAFT_REASON: ci-unknown sha=abc -->\nbody"},
  {"number": 13, "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=abc -->\nbody"},
  {"number": 14, "body": "<!-- SWARM_DRAFT_REASON: review-block sha=abc -->\nbody"},
  {"number": 15, "body": "plain draft, no banner"},
  {"number": 16, "body": null},
  {"number": 17, "body": "prose quoting `<!-- SWARM_DRAFT_REASON: ci-pending sha=abc -->` mid-line"}
]
EOF

heading "Test 1: retries only ci-pending / ci-unknown drafts and reports each result"
run_sweep || red "expected exit 0: $(cat "$TEST_DIR/out.log")"
[ "$(sort "$READY_LOG" | tr '\n' ' ')" = "11 12 " ] || red "expected pr-ready on 11 and 12 only, got: $(tr '\n' ' ' < "$READY_LOG")"
grep -qx '#11 ci-pending: readied' "$TEST_DIR/out.log" || red "expected readied line: $(cat "$TEST_DIR/out.log")"
grep -qx '#12 ci-unknown: still draft (exit 4)' "$TEST_DIR/out.log" || red "expected still-draft line: $(cat "$TEST_DIR/out.log")"
grep -qx '#13 ci-failing: needs a fix push (sha=abc)' "$TEST_DIR/out.log" || red "expected ci-failing report for #13: $(cat "$TEST_DIR/out.log")"
green "ci-failing, review-block, unbannered, null-body and mid-line-quoted drafts are left alone"

heading "Test 2: --dry-run lists candidates without running pr-ready"
run_sweep --dry-run || red "expected exit 0"
[ ! -s "$READY_LOG" ] || red "expected no pr-ready calls in dry run"
grep -qx '#11 ci-pending: would retry (dry run)' "$TEST_DIR/out.log" || red "expected dry-run line: $(cat "$TEST_DIR/out.log")"
green "dry run is read-only"

heading "Test 3: gh pr list failure exits 1"
rc=0; GH_LIST_FAILS=1 run_sweep || rc=$?
[ "$rc" -eq 1 ] || red "expected exit 1, got $rc"
green "list failure is reported, not swallowed"


# ============================================================================
# issue #635: stale waits — a draft whose Next line waits on an already-merged
# same-repo PR gets one stale-wait line; open triggers, non-Next prose and
# cross-repo refs stay silent; WATCH_STALE_WAIT_CHECK=0 turns it off.
# ============================================================================
cat > "$FIXTURE" <<'JSON'
[
  {"number": 21, "body": "> ⛔ **COORDINATOR HOLD** — renumber; fix brief queued to iss-1472.\n> **Next:** coordinator — send the renumber brief — waiting on #1461 merges\nrest"},
  {"number": 22, "body": "**Next:** worker iss-9 — rebase — waiting on #1500 to merge"},
  {"number": 23, "body": "prose: we were waiting on #1461 merges last week"},
  {"number": 24, "body": "**Next:** worker iss-9 — rebase — waiting on other/repo#1461 merges"}
]
JSON
cat > "$STATES" <<'JSON'
{"1461": {"state": "MERGED", "mergedAt": "2026-10-15T06:52:00Z"}, "1500": {"state": "OPEN", "mergedAt": null}}
JSON

heading "Test 4: Next line waiting on a merged PR is reported; open, prose and cross-repo are not"
run_sweep || red "expected exit 0: $(cat "$TEST_DIR/out.log")"
[ "$(cat "$TEST_DIR/out.log")" = "#21 stale-wait: waiting on #1461, which merged at 2026-10-15T06:52:00Z" ] \
    || red "expected exactly one stale-wait line for #21: $(cat "$TEST_DIR/out.log")"
green "only the merged same-repo trigger on a Next line fires"

heading "Test 5: WATCH_STALE_WAIT_CHECK=0 turns the stale-wait check off"
WATCH_STALE_WAIT_CHECK=0 run_sweep || red "expected exit 0"
[ ! -s "$TEST_DIR/out.log" ] || red "expected no output with the check off: $(cat "$TEST_DIR/out.log")"
green "off-switch honoured"

heading "Test 6: --dry-run still reports ci-failing drafts (read-only)"
cat > "$FIXTURE" <<'JSON'
[{"number": 31, "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=deadbeef -->\nbody"}]
JSON
run_sweep --dry-run || red "expected exit 0"
grep -qx '#31 ci-failing: needs a fix push (sha=deadbeef)' "$TEST_DIR/out.log" || red "dry run lost ci-failing line: $(cat "$TEST_DIR/out.log")"
green "ci-failing reported in dry run"

heading "Test 7 (issue #729): head == banner sha is reported ci-failing and NOT retried"
cat > "$FIXTURE" <<'JSON'
[{"number": 41, "headRefOid": "0ddba110ddba11", "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=0ddba110ddba11 -->\nbody"}]
JSON
run_sweep || red "expected exit 0"
grep -qx '#41 ci-failing: needs a fix push (sha=0ddba110ddba11)' "$TEST_DIR/out.log" || red "expected ci-failing line: $(cat "$TEST_DIR/out.log")"
[ ! -s "$READY_LOG" ] || red "unchanged red head must not be retried: $(cat "$READY_LOG")"
green "unchanged head reports red"

heading "Test 8 (issue #729): head moved is checked read-only; only verified red is reported, pr-ready never called"
: > "$TEST_DIR/checks.log"
printf '1\nlint\tfail\t1m\nunit\tpass\t2m\n' > "$TEST_DIR/checks.51"   # red
printf '8\nlint\tpending\t0\n' > "$TEST_DIR/checks.52"                    # pending
printf '0\nlint\tpass\t1m\n' > "$TEST_DIR/checks.53"                      # green
printf '1\nHTTP 403: Resource not accessible by personal access token\n' > "$TEST_DIR/checks.54"  # unreadable
printf '2\nboom\n' > "$TEST_DIR/checks.55"                                 # unexpected rc
cat > "$FIXTURE" <<'JSON'
[{"number": 51, "headRefOid": "feed5678", "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=0ddba11 -->\nbody"},
 {"number": 52, "headRefOid": "feed5678", "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=0ddba11 -->\nbody"},
 {"number": 53, "headRefOid": "feed5678", "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=0ddba11 -->\nbody"},
 {"number": 54, "headRefOid": "feed5678", "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=0ddba11 -->\nbody"},
 {"number": 55, "headRefOid": "feed5678", "body": "<!-- SWARM_DRAFT_REASON: ci-failing sha=0ddba11 -->\nbody"}]
JSON
run_sweep || red "expected exit 0: $(cat "$TEST_DIR/out.log")"
[ "$(cat "$TEST_DIR/out.log")" = "#51 ci-failing: needs a fix push (sha=feed5678)" ] || red "expected only #51 red with the LIVE sha: $(cat "$TEST_DIR/out.log")"
[ ! -s "$READY_LOG" ] || red "pr-ready must never run on a moved head: $(cat "$READY_LOG")"
[ "$(sort "$TEST_DIR/checks.log" | tr '\n' ' ')" = "51 52 53 54 55 " ] || red "expected a checks read per moved PR: $(tr '\n' ' ' < "$TEST_DIR/checks.log")"
run_sweep --dry-run || red "expected exit 0"
grep -qx '#51 ci-failing: needs a fix push (sha=feed5678)' "$TEST_DIR/out.log" || red "dry run lost the moved-head red note"
[ ! -s "$READY_LOG" ] || red "dry run must not call pr-ready"
green "moved head: red notes with live sha; pending, green, unreadable, unexpected stay silent; no pr-ready"

heading "Test 9 (issue #757): banner-less green drafts are reported; held, banner, red, pending and empty-CI drafts are not"
G='[{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"lint","status":"COMPLETED","conclusion":"SKIPPED"}]'
cat > "$FIXTURE" <<JSON
[{"number": 61, "headRefOid": "aaa111", "headRefName": "fix/issue-61", "body": "<!-- BLIND_MERGE_RISK: low -->\nbody", "statusCheckRollup": $G},
 {"number": 62, "headRefOid": "bbb222", "headRefName": "feat/issue-62", "body": "<!-- BLIND_MERGE_RISK: high -->\nbody", "statusCheckRollup": $G},
 {"number": 63, "headRefOid": "ccc333", "headRefName": "x", "body": "no marker", "statusCheckRollup": $G},
 {"number": 64, "headRefOid": "ddd444", "headRefName": "fix/issue-64", "body": "> ⛔ **COORDINATOR HOLD** — wait\nbody", "statusCheckRollup": $G},
 {"number": 65, "headRefOid": "eee555", "headRefName": "fix/issue-65", "body": "<!-- SWARM_DRAFT_REASON: review-block sha=eee555 -->\nbody", "statusCheckRollup": $G},
 {"number": 66, "headRefOid": "fff666", "headRefName": "fix/issue-66", "body": "body", "statusCheckRollup": [{"name":"unit","status":"COMPLETED","conclusion":"FAILURE"}]},
 {"number": 67, "headRefOid": "111777", "headRefName": "fix/issue-67", "body": "body", "statusCheckRollup": [{"name":"unit","status":"IN_PROGRESS"}]},
 {"number": 68, "headRefOid": "222888", "headRefName": "fix/issue-68", "body": "body", "statusCheckRollup": []},
 {"number": 69, "headRefOid": "333999", "headRefName": "fix/issue-69", "body": "body", "statusCheckRollup": [{"name":"unit","status":"COMPLETED","conclusion":"FAILURE","completedAt":"2026-01-01T00:00:00Z"},{"name":"unit","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-01-02T00:00:00Z"}]}]
JSON
: > "$TEST_DIR/states.json"; echo "{}" > "$STATES"
run_sweep || red "expected exit 0: $(cat "$TEST_DIR/out.log")"
want='#61 parked-green: banner-less draft, green CI (risk=low, issue=61, sha=aaa111)
#62 parked-green: banner-less draft, green CI (risk=high, issue=62, sha=bbb222)
#63 parked-green: banner-less draft, green CI (risk=unknown, issue=none, sha=ccc333)
#69 parked-green: banner-less draft, green CI (risk=unknown, issue=69, sha=333999)'
[ "$(cat "$TEST_DIR/out.log")" = "$want" ] || red "unexpected parked-green output: $(cat "$TEST_DIR/out.log")"
[ ! -s "$READY_LOG" ] || red "sweep itself must not run pr-ready for parked-green drafts: $(cat "$READY_LOG")"
run_sweep --dry-run || red "dry run failed"
[ "$(cat "$TEST_DIR/out.log")" = "$want" ] || red "dry run lost parked-green lines"
green "banner-less green drafts reported (read-only); held, bannered, red, pending, no-CI left alone; newest run per check wins"

green "ALL TESTS PASSED"
