#!/usr/bin/env bash
#
# test-pr-ready.sh — Non-LLM regression test for scripts/pr-ready.sh
# (issue #439, ask 3).
#
# The gap: today only an explicit `self-review-pr.sh --post` posts the
# `SWARM_SELF_REVIEW` verdict marker on a PR — a worker that runs bare
# `gh pr ready` for a 🟡/🔴 PR never posts one, so swarm-merge.sh's BLOCK
# gate and a human merging from the GitHub web UI both see nothing.
# pr-ready.sh closes that by always running self-review (unless the PR is
# marked 🟢 low, matching worker.md's own rubric) before readying.
#
# self-review-pr.sh itself shells out to a real `claude -p` session and
# can't be exercised here — instead this test stubs it out entirely via
# SELF_REVIEW_SCRIPT (pr-ready.sh's override hook) with a fake that just
# echoes its args and exits with a controlled code, so this test verifies
# pr-ready.sh's own DECISION LOGIC (risk gating, exit-code handling,
# whether `gh pr ready` actually runs) rather than the review itself. gh
# stubbed via a PATH shim, same technique as test-pr-brief-marker.sh.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_READY="$SCRIPT_DIR/../scripts/pr-ready.sh"
[ -x "$PR_READY" ] || red "pr-ready.sh not executable: $PR_READY"

TEST_DIR=$(mktemp -d -t pr-ready-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
GH_LOG="$TEST_DIR/gh.log"
BODY_FILE="$TEST_DIR/pr-body.txt"
: > "$GH_LOG"

cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    cat "$BODY_FILE"
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "ready" ]; then
    exit 0
fi
exit 1
EOF
chmod +x "$SHIM_DIR/gh"

FAKE_REVIEW="$TEST_DIR/fake-self-review.sh"
FAKE_REVIEW_LOG="$TEST_DIR/fake-review.log"
FAKE_REVIEW_RC_FILE="$TEST_DIR/fake-review-rc"
make_fake_review() {
    echo "$1" > "$FAKE_REVIEW_RC_FILE"
    cat > "$FAKE_REVIEW" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE_REVIEW_LOG"
exit "\$(cat "$FAKE_REVIEW_RC_FILE")"
EOF
    chmod +x "$FAKE_REVIEW"
}

gh_ready_called() { grep -q 'pr ready' "$GH_LOG"; }

run_pr_ready() {
    : > "$GH_LOG"
    : > "$FAKE_REVIEW_LOG"
    rc=0
    PATH="$SHIM_DIR:$PATH" SELF_REVIEW_SCRIPT="$FAKE_REVIEW" "$PR_READY" 42 \
        > "$TEST_DIR/out.log" 2>&1 || rc=$?
    return "$rc"
}

# ============================================================================
heading "Test 1: risk=low — self-review skipped entirely, gh pr ready runs"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nfixed a typo\n' > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 for risk=low, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review NOT invoked for risk=low, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready to run for risk=low"
green "risk=low skips self-review and readies immediately"

# ============================================================================
heading "Test 2: risk=medium, self-review APPROVE (0) — readies"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 for APPROVE, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q '42 --post' "$FAKE_REVIEW_LOG" || red "expected self-review invoked with '42 --post', log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready to run after APPROVE"
green "risk=medium + APPROVE runs self-review --post then readies"

# ============================================================================
heading "Test 3: risk=high, self-review APPROVE_WITH_CAVEATS (3) — readies"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: high -->\nrisky change\n' > "$BODY_FILE"
make_fake_review 3
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 for APPROVE_WITH_CAVEATS, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run after APPROVE_WITH_CAVEATS"
green "risk=high + APPROVE_WITH_CAVEATS still readies"

# ============================================================================
heading "Test 4: self-review BLOCK (2) — refuses, gh pr ready NEVER runs"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nbroken change\n' > "$BODY_FILE"
make_fake_review 2
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 2 ] || red "expected exit 2 for BLOCK, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run after a BLOCK verdict"
grep -qi 'REFUSED' "$TEST_DIR/out.log" || red "expected a REFUSED message in output: $(cat "$TEST_DIR/out.log")"
green "a BLOCK verdict refuses to ready the PR at all"

# ============================================================================
heading "Test 5: self-review skipped (WORKER_SELF_REVIEW=0, exit 4) — readies anyway"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 4
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 when self-review is skipped, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to still run when self-review was skipped"
green "a skipped self-review (exit 4) still readies, doesn't block on missing infra"

# ============================================================================
heading "Test 6: self-review errors (exit 1) — WARNs, readies anyway (fail open)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 1
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 when self-review errors, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to still run when self-review errored"
grep -qi 'WARN' "$TEST_DIR/out.log" || red "expected a WARN in output for a self-review failure: $(cat "$TEST_DIR/out.log")"
green "a self-review infra failure WARNs loudly but fails open (never silently blocks readiness)"

# ============================================================================
heading "Test 7: no BLIND_MERGE_RISK marker at all — treated as medium"
# ============================================================================
printf 'no risk marker in this body\n' > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
[ -s "$FAKE_REVIEW_LOG" ] || red "expected self-review invoked when no risk marker is present (fail toward requiring review)"
grep -qi 'WARN' "$TEST_DIR/out.log" || red "expected a WARN about the missing risk marker: $(cat "$TEST_DIR/out.log")"
green "a missing risk marker is treated as medium, not skipped"

green "ALL TESTS PASSED"
