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

green "ALL TESTS PASSED"
