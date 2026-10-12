#!/usr/bin/env bash
#
# test-ready-sweep.sh — Non-LLM regression test for scripts/ready-sweep.sh
# (issue #602): only drafts whose SWARM_DRAFT_REASON banner is ci-pending
# or ci-unknown get pr-ready.sh re-run. gh is a PATH shim that applies the
# script's own --jq filter (via jq) to a fixture PR list; pr-ready.sh is
# replaced via PR_READY_SCRIPT.
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

cat > "$TEST_DIR/shims/gh" <<EOF
#!/usr/bin/env bash
[ "\${GH_LIST_FAILS:-0}" = "1" ] && exit 1
printf '%s\n' "\$*" | grep -q -- '--draft' || { echo "expected --draft" >&2; exit 1; }
while [ \$# -gt 0 ]; do [ "\$1" = "--jq" ] && { jq -r "\$2" "$FIXTURE"; exit; }; shift; done
exit 1
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

green "ALL TESTS PASSED"
