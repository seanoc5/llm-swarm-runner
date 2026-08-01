#!/usr/bin/env bash
#
# test-shape-review-scoreboard.sh — Non-LLM shape tests for
# review-scoreboard.sh (#214): adoption cutoff, latest-marker-wins,
# risk parsing, coverage math, ⚠ flags, --since, --json, and the
# stubbed-gh fetch path. No GitHub auth, no network.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOREBOARD="$SCRIPT_DIR/../scripts/review-scoreboard.sh"
[ -x "$SCOREBOARD" ] || red "not executable: $SCOREBOARD"

TEST_DIR=$(mktemp -d -t shape-review-scoreboard-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ───────────────────────────── Fixture PRs ──────────────────────────────────
# 1  pre-adoption 🔴, no marker           → excluded from eligible entirely
# 2  🟡 MERGED, APPROVE                   → adoption date (first marker)
# 3  🟡 MERGED, BLOCK then CAVEATS        → latest marker wins (NOT flagged)
# 4  🟡 MERGED, BLOCK                     → flag: merged_block
# 5  🔴 MERGED, no marker                 → flag: merged_high_unreviewed
# 6  🟡 OPEN,   BLOCK                     → flag: open_block
# 7  🟢 MERGED, no marker                 → fine (by design)
# 8  unrated MERGED, no marker            → fine (human PR)
# 9  🟡 MERGED, no marker                 → flag: merged_medium_unreviewed
FIXTURE="$TEST_DIR/prs.jsonl"
cat > "$FIXTURE" <<'EOF'
{"number":1,"state":"MERGED","createdAt":"2026-01-01T00:00:00Z","body":"pre-adoption 🔴 high","comments":{"nodes":[]}}
{"number":2,"state":"MERGED","createdAt":"2026-02-01T00:00:00Z","body":"risk: 🟡 medium","comments":{"nodes":[{"body":"<!-- SWARM_SELF_REVIEW: APPROVE -->\nclean"}]}}
{"number":3,"state":"MERGED","createdAt":"2026-02-02T00:00:00Z","body":"risk: 🟡 medium","comments":{"nodes":[{"body":"<!-- SWARM_SELF_REVIEW: BLOCK -->\nbug"},{"body":"<!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS -->\nfixed, one caveat"}]}}
{"number":4,"state":"MERGED","createdAt":"2026-02-03T00:00:00Z","body":"risk: 🟡 medium","comments":{"nodes":[{"body":"<!-- SWARM_SELF_REVIEW: BLOCK -->\nreal bug"}]}}
{"number":5,"state":"MERGED","createdAt":"2026-02-04T00:00:00Z","body":"risk: 🔴 high — auth","comments":{"nodes":[{"body":"just a human comment"}]}}
{"number":6,"state":"OPEN","createdAt":"2026-02-05T00:00:00Z","body":"risk: 🟡 medium","comments":{"nodes":[{"body":"<!-- SWARM_SELF_REVIEW: BLOCK -->\nnot mergeable"}]}}
{"number":7,"state":"MERGED","createdAt":"2026-02-06T00:00:00Z","body":"risk: 🟢 low — docs","comments":{"nodes":[]}}
{"number":8,"state":"MERGED","createdAt":"2026-02-07T00:00:00Z","body":"a human PR, no rating","comments":{"nodes":[]}}
{"number":9,"state":"MERGED","createdAt":"2026-02-08T00:00:00Z","body":"risk: 🟡 medium","comments":{"nodes":[]}}
EOF

# ============================================================================
heading "Test 1: --json aggregate — adoption, coverage, latest-marker-wins"
# ============================================================================
AGG="$("$SCOREBOARD" --json "$FIXTURE")" || red "scoreboard --json failed"

jq -e '.total == 9' <<<"$AGG" >/dev/null || red "total: expected 9"
jq -e '.adoption == "2026-02-01T00:00:00Z"' <<<"$AGG" >/dev/null \
    || red "adoption: expected first-marker date 2026-02-01"
jq -e '.eligible == 8 and .reviewed == 4' <<<"$AGG" >/dev/null \
    || red "eligible/reviewed: expected 8/4"
green "adoption cutoff excludes pre-marker PRs; totals correct"

jq -e '.coverage_by_risk == [
    {"risk":"🔴","total":1,"reviewed":0,"coverage_pct":0},
    {"risk":"🟡","total":5,"reviewed":4,"coverage_pct":80},
    {"risk":"🟢","total":1,"reviewed":0,"coverage_pct":0},
    {"risk":"unrated","total":1,"reviewed":0,"coverage_pct":0}
]' <<<"$AGG" >/dev/null || red "coverage_by_risk mismatch: $(jq -c .coverage_by_risk <<<"$AGG")"
green "coverage-by-risk table correct, 🔴→🟡→🟢→unrated order"

jq -e '.verdicts == {"APPROVE":1,"APPROVE_WITH_CAVEATS":1,"BLOCK":2}' <<<"$AGG" >/dev/null \
    || red "verdicts mismatch: $(jq -c .verdicts <<<"$AGG")"
green "verdict distribution correct (PR 3 counts as CAVEATS — latest marker wins)"

# ============================================================================
heading "Test 2: ⚠ flags"
# ============================================================================
jq -e '.flags == {
    "merged_block":[4],
    "open_block":[6],
    "merged_high_unreviewed":[5],
    "merged_medium_unreviewed":[9]
}' <<<"$AGG" >/dev/null || red "flags mismatch: $(jq -c .flags <<<"$AGG")"
green "merged-BLOCK, open-BLOCK, unreviewed 🔴/🟡 flags correct; fixed-then-re-reviewed PR 3 not flagged"

# ============================================================================
heading "Test 3: table output renders flags and summary"
# ============================================================================
OUT="$("$SCOREBOARD" "$FIXTURE")" || red "table mode failed"
echo "$OUT" | grep -q "reviewed: 4 (50%)"            || red "summary line missing/wrong"
echo "$OUT" | grep -q "merged with latest verdict BLOCK.*#4" || red "merged-BLOCK flag line missing"
echo "$OUT" | grep -q "open sitting on a BLOCK: #6"  || red "open-BLOCK flag line missing"
echo "$OUT" | grep -q "merged 🔴 with no review: #5" || red "unreviewed-🔴 flag line missing"
echo "$OUT" | grep -q "merged 🟡 with no review: #9" || red "unreviewed-🟡 flag line missing"
green "table mode renders summary + all four flag lines"

# ============================================================================
heading "Test 4: --since overrides adoption cutoff"
# ============================================================================
AGG2="$("$SCOREBOARD" --json --since 2026-02-04 "$FIXTURE")" || red "--since run failed"
jq -e '.eligible == 5 and .reviewed == 1' <<<"$AGG2" >/dev/null \
    || red "--since: expected eligible 5 / reviewed 1, got $(jq -c '{eligible,reviewed}' <<<"$AGG2")"
green "--since narrows the window (PRs 5-9 only)"

# ============================================================================
heading "Test 5: no markers anywhere → clean 'nothing to score' exit 0"
# ============================================================================
jq -c '.comments = {"nodes":[]}' "$FIXTURE" > "$TEST_DIR/no-markers.jsonl"
OUT="$("$SCOREBOARD" "$TEST_DIR/no-markers.jsonl")" || red "no-marker input should exit 0"
echo "$OUT" | grep -q "no SWARM_SELF_REVIEW markers found" || red "expected 'no markers' message"
green "marker-free repo reports cleanly, exit 0"

# ============================================================================
heading "Test 6: gh fetch path (stubbed gh)"
# ============================================================================
export GH_FIXTURE="$FIXTURE"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "repo view")   echo "stub/current-repo"; exit 0 ;;
    "api graphql") cat "$GH_FIXTURE"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TEST_DIR/bin/gh"
OUT="$(PATH="$TEST_DIR/bin:$PATH" "$SCOREBOARD" --repo fake/repo)" || red "stubbed gh fetch failed"
echo "$OUT" | grep -q "Repo: fake/repo" || red "repo label missing in gh-fetch mode"
echo "$OUT" | grep -q "reviewed: 4 (50%)" || red "gh-fetch aggregate differs from file mode"
OUT="$(cd "$TEST_DIR" && PATH="$TEST_DIR/bin:$PATH" "$SCOREBOARD")" || red "default-repo resolution failed"
echo "$OUT" | grep -q "Repo: stub/current-repo" || red "default repo (gh repo view) not used"
green "gh fetch path works; --repo and cwd-repo resolution both covered"

# ============================================================================
heading "All review-scoreboard shape tests passed"
green "adoption cutoff, latest-marker-wins, coverage math, flags, --since, --json, gh stub"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
