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
#
# issue #473 (Tests 12-19, numbered in file order): also covers the
# CI-green-before-ready gate (a
# `gh pr checks` snapshot taken right before readying, controlled here via
# GH_CHECKS_RC/GH_CHECKS_STDERR/GH_WORKFLOW_COUNT) and the self-review round
# cap (WORKER_SELF_REVIEW_MAX_ROUNDS, controlled via GH_ROUNDS_DONE standing
# in for the count of prior SWARM_SELF_REVIEW marker comments, and
# GH_LATEST_VERDICT for the latest one's verdict).
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
    if printf '%s\n' "\$*" | grep -q -- '--json comments'; then
        if printf '%s\n' "\$*" | grep -q -- 'capture('; then
            echo "\${GH_LATEST_VERDICT:-}"
        else
            echo "\${GH_ROUNDS_DONE:-0}"
        fi
    elif printf '%s\n' "\$*" | grep -q -- '--json headRefOid'; then
        if [ "\${GH_SHA_LOOKUP_FAILS:-0}" = "1" ]; then
            echo "gh: pr view failed" >&2
            exit 1
        fi
        echo "\${GH_SHA:-deadbeef}"
    else
        cat "$BODY_FILE"
    fi
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "checks" ]; then
    [ -n "\${GH_CHECKS_STDERR:-}" ] && echo "\$GH_CHECKS_STDERR" >&2
    exit "\${GH_CHECKS_RC:-0}"
fi
if [ "\$1" = "pr" ] && [ "\$2" = "ready" ]; then
    exit 0
fi
if [ "\$1" = "run" ] && [ "\$2" = "list" ]; then
    [ -n "\${GH_RUNLIST_STDERR:-}" ] && echo "\$GH_RUNLIST_STDERR" >&2
    echo "\${GH_RUNLIST_JSON:-[]}"
    exit "\${GH_RUNLIST_RC:-0}"
fi
if [ "\$1" = "api" ]; then
    echo "\${GH_WORKFLOW_COUNT:-0}"
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
    PATH="$SHIM_DIR:$PATH" SELF_REVIEW_SCRIPT="$FAKE_REVIEW" WORKER_SELF_REVIEW="${WORKER_SELF_REVIEW:-1}" \
        WORKER_SELF_REVIEW_MAX_ROUNDS="${WORKER_SELF_REVIEW_MAX_ROUNDS:-3}" \
        GH_ROUNDS_DONE="${GH_ROUNDS_DONE:-0}" GH_LATEST_VERDICT="${GH_LATEST_VERDICT:-}" \
        GH_CHECKS_RC="${GH_CHECKS_RC:-0}" GH_CHECKS_STDERR="${GH_CHECKS_STDERR:-}" \
        GH_WORKFLOW_COUNT="${GH_WORKFLOW_COUNT:-0}" \
        GH_SHA="${GH_SHA:-deadbeef}" GH_SHA_LOOKUP_FAILS="${GH_SHA_LOOKUP_FAILS:-0}" \
        GH_RUNLIST_JSON="${GH_RUNLIST_JSON:-[]}" GH_RUNLIST_RC="${GH_RUNLIST_RC:-0}" \
        GH_RUNLIST_STDERR="${GH_RUNLIST_STDERR:-}" \
        "$PR_READY" 42 \
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
grep -q '42 --post --force' "$FAKE_REVIEW_LOG" || red "expected self-review invoked with '42 --post --force' (issue #439 self-review finding: --force is mandatory so a post-BLOCK retry doesn't post nothing over a stale marker), log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready to run after APPROVE"
green "risk=medium + APPROVE runs self-review --post --force then readies"

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
heading "Test 5: WORKER_SELF_REVIEW=0 — self-review never invoked, readies anyway"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
WORKER_SELF_REVIEW=0
rc=0; run_pr_ready || rc=$?
WORKER_SELF_REVIEW=1
[ "$rc" -eq 0 ] || red "expected exit 0 when WORKER_SELF_REVIEW=0, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review NOT invoked at all under WORKER_SELF_REVIEW=0, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready to still run when WORKER_SELF_REVIEW=0"
green "WORKER_SELF_REVIEW=0 skips the call entirely (never reaches --force) and still readies"

# ============================================================================
heading "Test 6: self-review errors (exit 1) — REFUSES, gh pr ready NEVER runs (fail closed, issue #446)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 1
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 2 ] || red "expected exit 2 when self-review errors, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when self-review errored (exit 1 conflates infra failure with an unparseable verdict that could be a real BLOCK)"
grep -qi 'REFUSED' "$TEST_DIR/out.log" || red "expected a REFUSED message in output: $(cat "$TEST_DIR/out.log")"
green "a self-review exit 1 (infra failure or unparseable verdict) fails closed, same as an explicit BLOCK"

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

# ============================================================================
heading "Test 8: COORDINATOR HOLD banner — self-review still posts, gh pr ready NEVER runs (issue #534)"
# ============================================================================
printf '> ⛔ **COORDINATOR HOLD** — fix queued; do not merge\n\n<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 3 ] || red "expected exit 3 for a held PR, got $rc: $(cat "$TEST_DIR/out.log")"
[ -s "$FAKE_REVIEW_LOG" ] || red "expected self-review to still run (and post) for a held PR"
gh_ready_called && red "expected gh pr ready NOT to run for a held PR"
grep -qi 'HOLD' "$TEST_DIR/out.log" || red "expected a HOLD message in output: $(cat "$TEST_DIR/out.log")"
green "a COORDINATOR HOLD banner posts self-review but never un-drafts the PR"

# ============================================================================
heading "Test 9: COORDINATOR HOLD banner on a risk=low PR — still held, not readied"
# ============================================================================
printf '> ⛔ **COORDINATOR HOLD** — fix queued; do not merge\n\n<!-- BLIND_MERGE_RISK: low -->\nfixed a typo\n' > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 3 ] || red "expected exit 3 for a held low-risk PR, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run for a held low-risk PR"
green "a COORDINATOR HOLD banner holds even a risk=low PR"

# ============================================================================
heading "Test 10: body merely MENTIONS the phrase (no banner) — not held, readies normally"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nThis PR adds the COORDINATOR HOLD check to pr-ready.sh.\n' > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 — a prose mention of the phrase should not self-hold, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run when the body only mentions the phrase in prose, not the actual banner"
green "a prose mention of the phrase (not the actual banner) does not trigger a hold"

# ============================================================================
heading "Test 11: body QUOTES the exact banner markup mid-paragraph (not at line-start) — not held"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nThis fixes pr-ready.sh so a `> \xe2\x9b\x94 **COORDINATOR HOLD**` banner is respected.\n' > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 — quoting the banner markup mid-paragraph should not self-hold, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run when the banner markup only appears quoted inline, not as its own leading line"
green "quoting the banner's exact markup inline (not as a leading blockquote line) does not trigger a hold"

# ============================================================================
heading "Test 12: CI checks pending (gh pr checks exit 8) — refuses, gh pr ready NEVER runs (issue #473)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=8
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
[ "$rc" -eq 4 ] || red "expected exit 4 for pending CI, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run while CI is still pending"
grep -qi 'REFUSED' "$TEST_DIR/out.log" || red "expected a REFUSED message in output: $(cat "$TEST_DIR/out.log")"
green "pending CI (gh pr checks exit 8) refuses to ready the PR"

# ============================================================================
heading "Test 13: CI checks failing (gh pr checks exit 1, real failure) — refuses, gh pr ready NEVER runs"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="lint-and-test  fail  4m12s"
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
[ "$rc" -eq 4 ] || red "expected exit 4 for failing CI, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run with failing CI checks"
grep -qi 'REFUSED' "$TEST_DIR/out.log" || red "expected a REFUSED message in output: $(cat "$TEST_DIR/out.log")"
green "failing CI checks refuse to ready the PR (the fand-etl PR #1063 bug this issue closes)"

# ============================================================================
heading "Test 14: no CI checks configured at all (0 workflows) — WARNs, still readies"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=0
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
[ "$rc" -eq 0 ] || red "expected exit 0 when no CI is configured, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to still run when no CI checks are configured"
grep -qi 'WARN' "$TEST_DIR/out.log" || red "expected a WARN about the absent checks: $(cat "$TEST_DIR/out.log")"
green "no CI configured at all (0 workflows) is a pass-with-warning, not a refusal"

# ============================================================================
heading "Test 15: 'no checks reported' but the repo HAS workflows (post-push race) — refuses"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=2
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
[ "$rc" -eq 4 ] || red "expected exit 4 when checks report absent but workflows exist (round-2 self-review finding), got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when this commit's CI run hasn't registered yet"
green "'no checks reported' with workflows configured is treated as pending, not absent (closes the post-push race self-review found)"

# ============================================================================
heading "Test 16: self-review round cap reached — skips another round, still readies on CI-green"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_ROUNDS_DONE=3
WORKER_SELF_REVIEW_MAX_ROUNDS=3
rc=0; run_pr_ready || rc=$?
GH_ROUNDS_DONE=0
WORKER_SELF_REVIEW_MAX_ROUNDS=3
[ "$rc" -eq 0 ] || red "expected exit 0 once the cap is hit and CI is green, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review-pr.sh NOT invoked once the round cap is reached, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready to still run once the round cap is reached"
grep -qi 'round cap reached' "$TEST_DIR/out.log" || red "expected a round-cap message in output: $(cat "$TEST_DIR/out.log")"
green "hitting the self-review round cap skips another round and folds findings into Follow-up suggestions instead"

# ============================================================================
heading "Test 17: WORKER_SELF_REVIEW_MAX_ROUNDS=0 — self-review disabled, readies anyway"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
WORKER_SELF_REVIEW_MAX_ROUNDS=0
rc=0; run_pr_ready || rc=$?
WORKER_SELF_REVIEW_MAX_ROUNDS=3
[ "$rc" -eq 0 ] || red "expected exit 0 when WORKER_SELF_REVIEW_MAX_ROUNDS=0, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review-pr.sh NOT invoked when WORKER_SELF_REVIEW_MAX_ROUNDS=0, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready to still run when WORKER_SELF_REVIEW_MAX_ROUNDS=0"
green "WORKER_SELF_REVIEW_MAX_ROUNDS=0 disables self-review entirely and still readies"

# ============================================================================
heading "Test 18: below the round cap — self-review still runs normally, round number logged"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_ROUNDS_DONE=1
rc=0; run_pr_ready || rc=$?
GH_ROUNDS_DONE=0
[ "$rc" -eq 0 ] || red "expected exit 0 below the cap, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q '42 --post --force' "$FAKE_REVIEW_LOG" || red "expected self-review invoked below the cap, log: $(cat "$FAKE_REVIEW_LOG")"
grep -q 'round 2/3' "$TEST_DIR/out.log" || red "expected the round number in output: $(cat "$TEST_DIR/out.log")"
green "below the cap, self-review runs normally and logs its round number"

# ============================================================================
heading "Test 19: round cap reached with a BLOCK as the latest verdict — still refuses"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_ROUNDS_DONE=3
GH_LATEST_VERDICT=BLOCK
WORKER_SELF_REVIEW_MAX_ROUNDS=3
rc=0; run_pr_ready || rc=$?
GH_ROUNDS_DONE=0
GH_LATEST_VERDICT=
WORKER_SELF_REVIEW_MAX_ROUNDS=3
[ "$rc" -eq 2 ] || red "expected exit 2 when capped with a BLOCK as the latest verdict, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review-pr.sh NOT invoked once the round cap is reached, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called && red "expected gh pr ready NOT to run when capped with a BLOCK latest verdict"
grep -qi 'BLOCK' "$TEST_DIR/out.log" || red "expected a BLOCK refusal message in output: $(cat "$TEST_DIR/out.log")"
green "hitting the round cap with BLOCK as the latest verdict still refuses to ready (does not ready unreviewed)"

# ============================================================================
heading "Test 20: gh pr checks unreadable by a fine-grained token, Actions-runs fallback green — readies (issue #560)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.contexts.nodes)"
GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success","workflowName":"CI","createdAt":"2026-10-06T05:00:00Z"}]'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_RUNLIST_JSON="[]"
[ "$rc" -eq 0 ] || red "expected exit 0 once the Actions-runs fallback sees a green run, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run once the fallback confirms green"
grep -qi 'via Actions-runs fallback' "$TEST_DIR/out.log" || red "expected the output to name the fallback path: $(cat "$TEST_DIR/out.log")"
green "a token-permission error on gh pr checks falls back to Actions runs and readies on green"

# ============================================================================
heading "Test 21: token error, Actions-runs fallback sees a failing run — refuses (exit 4), gh pr ready NEVER runs"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.contexts.nodes)"
GH_RUNLIST_JSON='[{"status":"completed","conclusion":"failure","workflowName":"CI","createdAt":"2026-10-06T05:00:00Z"}]'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_RUNLIST_JSON="[]"
[ "$rc" -eq 4 ] || red "expected exit 4 when the fallback sees a failing run, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when the fallback sees a failing run"
grep -qi 'failing CI checks (via Actions-runs fallback)' "$TEST_DIR/out.log" || red "expected a fallback-specific failing-CI message: $(cat "$TEST_DIR/out.log")"
green "token error + a failing run via the fallback refuses to ready, same exit as a confirmed red (4)"

# ============================================================================
heading "Test 22: token error, Actions-runs fallback itself can't decide — refuses with a DISTINCT exit (5), not 'failing CI checks'"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.contexts.nodes)"
GH_RUNLIST_RC=1
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_RUNLIST_RC=0
[ "$rc" -eq 5 ] || red "expected a distinct exit 5 when the fallback can't decide either, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when CI status can't be determined at all"
grep -qi "can't read CI status" "$TEST_DIR/out.log" || red "expected a 'can't read CI status' message, distinct from 'failing CI checks': $(cat "$TEST_DIR/out.log")"
grep -qi 'failing CI checks' "$TEST_DIR/out.log" && red "must NOT reuse the 'failing CI checks' wording when the status is merely unknown: $(cat "$TEST_DIR/out.log")"
green "an undecidable fallback (gh run list itself fails) refuses with a distinct 'can't read CI status' exit, never misread as failing CI"

# ============================================================================
heading "Test 23: token error, can't even resolve the head SHA — refuses with the distinct exit (5)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.contexts.nodes)"
GH_SHA_LOOKUP_FAILS=1
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_SHA_LOOKUP_FAILS=0
[ "$rc" -eq 5 ] || red "expected exit 5 when the head SHA itself can't be resolved, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when the head SHA can't be resolved"
grep -qi "can't read CI status" "$TEST_DIR/out.log" || red "expected a 'can't read CI status' message: $(cat "$TEST_DIR/out.log")"
green "a failed head-SHA lookup for the fallback also refuses with the distinct exit, not a crash"

# ============================================================================
heading "Test 24: token error, Actions-runs fallback given valid-JSON-but-non-array input — fails closed (exit 5), never reaches gh pr ready"
# ============================================================================
# Self-review finding on this PR: pr-ready's `case "$CI_FALLBACK_STATE"` had
# no `*)` branch, so an unrecognized state would silently fall through to
# `gh pr ready` instead of refusing. In practice ci_fallback_run_state's own
# jq query only ever produces pass/fail/pending for valid ARRAY input (this
# test's `{}` is valid JSON but not an array, so jq's group_by errors out
# and the function returns non-zero — the same "fallback also failed" path
# Test 22 covers, just via a different malformed-input shape). The `*)`
# branch itself stays defensively unreachable through this black-box
# harness; what's verified here is that malformed fallback output of any
# kind still fails closed rather than readying. (Before the jq guard in
# _ci-fallback.sh, `{}` actually returned 0 with an empty state and was
# caught by the `*)` branch instead — #568 self-review caveat.)
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.contexts.nodes)"
GH_RUNLIST_JSON='{}'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_RUNLIST_JSON="[]"
[ "$rc" -eq 5 ] || red "expected exit 5 for malformed (non-array) fallback JSON, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run on malformed fallback JSON (must fail closed)"
grep -qi "can't read CI status" "$TEST_DIR/out.log" || red "expected a 'can't read CI status' message: $(cat "$TEST_DIR/out.log")"
green "valid-JSON-but-non-array fallback output fails closed instead of readying"

green "ALL TESTS PASSED"
