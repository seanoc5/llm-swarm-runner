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
EDITED_BODY="$TEST_DIR/edited-body.txt"
: > "$GH_LOG"

cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    if printf '%s\n' "\$*" | grep -q -- '--json comments'; then
        if printf '%s\n' "\$*" | grep -q -- 'SWARM_COORDINATOR_HOLD'; then
            # issue #616: pr-ready.sh's hold-comment lookup. Runs the
            # script's REAL --jq expression against GH_HOLD_COMMENTS_JSON
            # (a {"comments":[...]} fixture; none = no comments), or against
            # GH_HOLD_LATE_COMMENTS_JSON once a \`gh pr checks\` call has
            # happened — models a hold landing between the CI snapshot and
            # \`gh pr ready\`.
            HOLD_JSON="\${GH_HOLD_COMMENTS_JSON:-}"
            [ -n "\$HOLD_JSON" ] || HOLD_JSON='{"comments":[]}'
            if [ -e "$TEST_DIR/hold-late" ] && [ -n "\${GH_HOLD_LATE_COMMENTS_JSON:-}" ]; then
                HOLD_JSON="\$GH_HOLD_LATE_COMMENTS_JSON"
            fi
            JQ_EXPR=""
            prev=""
            for arg in "\$@"; do
                [ "\$prev" = "--jq" ] && JQ_EXPR="\$arg"
                prev="\$arg"
            done
            printf '%s' "\$HOLD_JSON" | jq -r "\$JQ_EXPR"
        elif [ -n "\${GH_COMMENTS_JSON:-}" ]; then
            # issue #601: run pr-ready.sh's REAL --jq expression (the arg
            # right after --jq) against a real comments fixture, instead of
            # the canned GH_ROUNDS_DONE/GH_LATEST_VERDICT stand-ins below —
            # proves the actual actor-exclusion filter, not just pr-ready.sh's
            # downstream decision logic given an already-computed count.
            JQ_EXPR=""
            prev=""
            for arg in "\$@"; do
                [ "\$prev" = "--jq" ] && JQ_EXPR="\$arg"
                prev="\$arg"
            done
            printf '%s' "\$GH_COMMENTS_JSON" | jq -r "\$JQ_EXPR"
        elif printf '%s\n' "\$*" | grep -q -- 'last // empty'; then
            # LATEST_VERDICT's query ends '| last // empty'; ROUNDS_DONE's
            # now also contains 'capture(' (issue #601's actor extraction),
            # so that substring alone no longer tells the two apart.
            echo "\${GH_LATEST_VERDICT:-}"
        else
            echo "\${GH_ROUNDS_DONE:-0}"
        fi
    elif printf '%s\n' "\$*" | grep -q -- '--json headRefName'; then
        echo "\${GH_HEAD_REF:-fix/issue-7}"
    elif printf '%s\n' "\$*" | grep -q -- '--json headRefOid'; then
        if [ "\${GH_SHA_LOOKUP_FAILS:-0}" = "1" ]; then
            echo "gh: pr view failed" >&2
            exit 1
        fi
        echo "\${GH_SHA:-deadbeef}"
    elif printf '%s\n' "\$*" | grep -q -- '--json statusCheckRollup'; then
        echo "\${GH_ROLLUP_JSON:-{\"statusCheckRollup\":[]\}}"
    elif printf '%s\n' "\$*" | grep -q -- '--json isDraft'; then
        echo "\${GH_IS_DRAFT:-true}"
    else
        cat "$BODY_FILE"
    fi
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "checks" ]; then
    # issue #616: from here on, a "late" hold exists (see the comments
    # lookup above); GH_HOLD_LATE_BODY swaps in a body that now carries the
    # banner, as the coordinator's own draft-as-hold edit would.
    touch "$TEST_DIR/hold-late"
    [ -z "\${GH_HOLD_LATE_BODY:-}" ] || printf '%s\n' "\$GH_HOLD_LATE_BODY" > "$BODY_FILE"
    [ -n "\${GH_CHECKS_STDERR:-}" ] && echo "\$GH_CHECKS_STDERR" >&2
    [ -n "\${GH_CHECKS_STDOUT:-}" ] && printf '%b\n' "\$GH_CHECKS_STDOUT"
    exit "\${GH_CHECKS_RC:-0}"
fi
if [ "\$1" = "pr" ] && [ "\$2" = "ready" ]; then
    exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "edit" ]; then
    cat > "$EDITED_BODY"
    exit 0
fi
if [ "\$1" = "run" ] && [ "\$2" = "list" ]; then
    [ -n "\${GH_RUNLIST_STDERR:-}" ] && echo "\$GH_RUNLIST_STDERR" >&2
    echo "\${GH_RUNLIST_JSON:-[]}"
    exit "\${GH_RUNLIST_RC:-0}"
fi
if [ "\$1" = "api" ]; then
    args="\$*"
    # issue #644 follow-up: \`gh api\` sends POST, not GET, whenever ANY
    # -f/-F is given — proven live against real GitHub (a bare -f ref=...
    # content fetch 404s; the same call with -X GET succeeds). Fail the
    # stub the same way the real API would 404 it, so this test proves the
    # METHOD actually sent, not just that the right args were built.
    if printf '%s\n' "\$args" | grep -qE -- '(^| )-[fF] ' && ! printf '%s\n' "\$args" | grep -q -- '-X GET'; then
        echo '{"message":"Not Found","status":"404"}' >&2
        exit 1
    fi
    if printf '%s\n' "\$args" | grep -q -- 'actions/workflows'; then
        if printf '%s\n' "\$args" | grep -q -- '.total_count'; then
            echo "\${GH_WORKFLOW_COUNT:-0}"
        else
            # issue #639: the second shape of this same endpoint —
            # ci_fallback_workflows_relevant_to_pr's own lookup of active
            # workflow paths, distinguished from the total_count query above
            # by its --jq expression, not by a second gh subcommand.
            echo "\${GH_WORKFLOW_PATHS_JSON:-[]}"
        fi
    elif printf '%s\n' "\$args" | grep -q -- 'pulls/.*/files'; then
        # ci_fallback_workflows_relevant_to_pr's changed-files lookup (REST,
        # --paginate — gh pr view --json files truncates at 100, cli/cli#5366).
        # GH_PR_FILES_JSON is usually the flat ["path", ...] shape (a plain
        # string element is one changed file with no rename), normalized
        # below into the real API's per-file object shape; an element
        # already given as an object (issue #644 round-5) is
        # {"filename":"new/path","previous_filename":"old/path"}, a real
        # GitHub rename entry. Unlike a hard-coded stand-in filter, this
        # extracts and runs THE SCRIPT'S OWN --jq expression against that
        # normalized fixture, so a regression that drops previous_filename
        # from the real query is actually caught here.
        JQ_FILES_EXPR=""
        prev_fa=""
        for fa in "\$@"; do
            [ "\$prev_fa" = "--jq" ] && JQ_FILES_EXPR="\$fa"
            prev_fa="\$fa"
        done
        printf '%s' "\${GH_PR_FILES_JSON:-[]}" \
            | jq '[.[] | if type == "object" then . else {filename: .} end]' \
            | jq -r "\$JQ_FILES_EXPR"
    elif printf '%s\n' "\$args" | grep -qF -- '.base.ref'; then
        # issue #644 final round + round-4: ci_fallback_workflows_relevant_to_pr's
        # lookup of the PR's OWN base AND head branch (base, to fetch each
        # workflow file at that ref instead of the repo default branch;
        # head, to evaluate a push trigger's branches/branches-ignore
        # filter — never its path filter).
        printf '%s\t%s\n' "\${GH_PR_BASE_REF:-main}" "\${GH_PR_HEAD_REF:-feature/change}"
    elif printf '%s\n' "\$args" | grep -q -- 'contents/'; then
        # issue #644 final round: the content fetch now carries '-f
        # ref=<base-branch>' — serve a DIFFERENT workflow YAML when that ref
        # matches the PR's actual base branch, so a test can prove the right
        # ref was requested instead of just ignoring it.
        if [ -n "\${GH_PR_BASE_REF:-}" ] && printf '%s\n' "\$args" | grep -qF -- "ref=\${GH_PR_BASE_REF}"; then
            printf '%s' "\${GH_WORKFLOW_YAML_FOR_BASE_REF:-\${GH_WORKFLOW_YAML:-}}"
        else
            printf '%s' "\${GH_WORKFLOW_YAML:-}"
        fi
    else
        echo "\${GH_WORKFLOW_COUNT:-0}"
    fi
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


# issue #731: stand-in for risk-floor.sh (the real script is covered by
# test-risk-floor.sh). FAKE_FLOOR_RC: 0 = rating fine, 10 = "bumped" (also
# rewrites the PR body's marker to medium, as the real --apply does), other =
# script failure. Default 0 so older tests see no floor effect.
FAKE_FLOOR="$TEST_DIR/fake-risk-floor.sh"
FAKE_FLOOR_LOG="$TEST_DIR/fake-floor.log"
FAKE_FLOOR_RC_FILE="$TEST_DIR/fake-floor-rc"
make_fake_floor() {
    echo "$1" > "$FAKE_FLOOR_RC_FILE"
    cat > "$FAKE_FLOOR" <<FEOF
#!/usr/bin/env bash
echo "\$*" >> "$FAKE_FLOOR_LOG"
rc="\$(cat "$FAKE_FLOOR_RC_FILE")"
echo "floor: medium"
echo "rule: migrations — touches a database migration (db/migration/V9__x.sql)"
[ "\$rc" != 10 ] || sed -i 's/BLIND_MERGE_RISK: low/BLIND_MERGE_RISK: medium/' "$BODY_FILE"
exit "\$rc"
FEOF
    chmod +x "$FAKE_FLOOR"
}
make_fake_floor 0
# The real "ready" call is logged as `pr ready 42`; the hold's re-draft is
# `pr ready --undo 42` and must not count (issue #616).
gh_ready_called() { grep -q '^pr ready 42$' "$GH_LOG"; }
gh_undo_called() { grep -q '^pr ready --undo 42$' "$GH_LOG"; }

run_pr_ready() {
    : > "$GH_LOG"
    rm -f "$EDITED_BODY" "$TEST_DIR/hold-late"
    : > "$FAKE_REVIEW_LOG"; : > "$FAKE_FLOOR_LOG"
    rc=0
    pushd "${PR_READY_CWD:-.}" >/dev/null
    PATH="$SHIM_DIR:$PATH" SELF_REVIEW_SCRIPT="$FAKE_REVIEW" RISK_FLOOR_SCRIPT="$FAKE_FLOOR" WORKER_SELF_REVIEW="${WORKER_SELF_REVIEW:-1}" \
        WORKER_SELF_REVIEW_MAX_ROUNDS="${WORKER_SELF_REVIEW_MAX_ROUNDS:-3}" \
        GH_ROUNDS_DONE="${GH_ROUNDS_DONE:-0}" GH_LATEST_VERDICT="${GH_LATEST_VERDICT:-}" \
        GH_COMMENTS_JSON="${GH_COMMENTS_JSON:-}" \
        GH_HOLD_COMMENTS_JSON="${GH_HOLD_COMMENTS_JSON:-}" GH_HOLD_LATE_COMMENTS_JSON="${GH_HOLD_LATE_COMMENTS_JSON:-}" \
        GH_HOLD_LATE_BODY="${GH_HOLD_LATE_BODY:-}" GH_IS_DRAFT="${GH_IS_DRAFT:-true}" \
        GH_CHECKS_RC="${GH_CHECKS_RC:-0}" GH_CHECKS_STDERR="${GH_CHECKS_STDERR:-}" GH_CHECKS_STDOUT="${GH_CHECKS_STDOUT:-}" GH_ROLLUP_JSON="${GH_ROLLUP_JSON:-}" \
        GH_WORKFLOW_COUNT="${GH_WORKFLOW_COUNT:-0}" \
        GH_PR_FILES_JSON="${GH_PR_FILES_JSON:-[]}" GH_WORKFLOW_PATHS_JSON="${GH_WORKFLOW_PATHS_JSON:-[]}" \
        GH_WORKFLOW_YAML="${GH_WORKFLOW_YAML:-}" \
        GH_PR_BASE_REF="${GH_PR_BASE_REF:-}" GH_PR_HEAD_REF="${GH_PR_HEAD_REF:-}" GH_WORKFLOW_YAML_FOR_BASE_REF="${GH_WORKFLOW_YAML_FOR_BASE_REF:-}" \
        MIGRATION_CHECK_SCRIPT="${MIGRATION_CHECK_SCRIPT:-}" \
        GH_SHA="${GH_SHA:-deadbeef}" GH_SHA_LOOKUP_FAILS="${GH_SHA_LOOKUP_FAILS:-0}" \
        GH_RUNLIST_JSON="${GH_RUNLIST_JSON:-[]}" GH_RUNLIST_RC="${GH_RUNLIST_RC:-0}" \
        GH_RUNLIST_STDERR="${GH_RUNLIST_STDERR:-}" \
        "$PR_READY" ${PR_READY_FLAGS:-} 42 ${PR_READY_TRAILING:-} \
        > "$TEST_DIR/out.log" 2>&1 || rc=$?
    popd >/dev/null
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
heading "Test 13b: gh pr checks exits 0 but prints a fail row (cancelled-only run) — refuses as ci-cancelled (issue #793)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=0
GH_CHECKS_STDOUT='build\tfail\t24h0m0s\thttps://example/runs/1'
GH_ROLLUP_JSON='{"statusCheckRollup":[{"conclusion":"CANCELLED","status":"COMPLETED"}]}'
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 4 ] || red "expected exit 4 for exit-0 + cancelled row, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run for a cancelled-only run"
grep -q 'gh run rerun' "$TEST_DIR/out.log" || red "expected the re-run hint: $(cat "$TEST_DIR/out.log")"
grep -q 'SWARM_DRAFT_REASON: ci-cancelled' "$EDITED_BODY" || red "expected a ci-cancelled banner: $(cat "$EDITED_BODY" 2>/dev/null)"
green "exit-0 + fail row with a CANCELLED-only rollup refuses as ci-cancelled"

printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
GH_ROLLUP_JSON='{"statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"},{"conclusion":"CANCELLED","status":"COMPLETED"}]}'
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 4 ] || red "expected exit 4 for exit-0 + real failure row, got $rc"
gh_ready_called && red "expected gh pr ready NOT to run"
grep -q 'SWARM_DRAFT_REASON: ci-failing' "$EDITED_BODY" || red "expected ci-failing banner for a real failure: $(cat "$EDITED_BODY")"
green "exit-0 + fail row with a genuine FAILURE refuses as ci-failing"

GH_CHECKS_STDOUT=""
GH_ROLLUP_JSON=""

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
heading "Test 15b: 'no checks reported', a docs-only PR, the one configured workflow paths-ignores docs — WARNs, still readies (issue #639)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["docs/foo.md","README.md"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_WORKFLOW_YAML=
[ "$rc" -eq 0 ] || red "expected exit 0 — a docs-only PR excluded by paths-ignore should never wait forever, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run once every changed file is excluded by the workflow's paths-ignore"
grep -qi 'WARN' "$TEST_DIR/out.log" || red "expected a WARN about the path-filtered changed files: $(cat "$TEST_DIR/out.log")"
green "a docs-only PR whose changed files are all paths-ignored readies with a WARN instead of refusing forever (civicstrata#602/#603)"

# ============================================================================
heading "Test 15b2: 'no checks reported', stacked PR whose base branch every pull_request workflow's branches filter excludes — WARNs, still readies (issue #670)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["src/main.py"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/ci.yml"]'
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    branches: [master]\n'
GH_PR_BASE_REF='fix/issue-1823'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_WORKFLOW_YAML=
GH_PR_BASE_REF=
[ "$rc" -eq 0 ] || red "expected exit 0 — a stacked PR whose base branch is filtered out gets no CI, ever; got $rc: $(cat "$TEST_DIR/out.log")"
grep -qi 'base branch excluded' "$TEST_DIR/out.log" || red "expected the WARN to name the base-branch cause: $(cat "$TEST_DIR/out.log")"
green "a stacked PR with an excluded base branch readies with a base-branch WARN instead of refusing as pending forever"

# ============================================================================
heading "Test 15c: 'no checks reported', changed files touch a NON-ignored path too — still refuses ci-pending (the #473 race guard holds)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["docs/foo.md","src/main.py"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_WORKFLOW_YAML=
[ "$rc" -eq 4 ] || red "expected exit 4 — a changed file outside paths-ignore means a real run is still pending, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when at least one changed file falls outside every paths-ignore"
green "a mixed PR (one ignored file, one not) is still treated as the ordinary post-push race, not path-filtered absence"

# ============================================================================
heading "Test 15d: 'no checks reported', the one workflow has NO path filter at all — still refuses ci-pending"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["docs/foo.md"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n  push:\n    branches: [master]\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_WORKFLOW_YAML=
[ "$rc" -eq 4 ] || red "expected exit 4 — an unfiltered pull_request trigger always applies, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when the workflow has no path filter at all"
green "a workflow with no paths/paths-ignore filter always counts as relevant, even for a docs-only PR"

# ============================================================================
heading "Test 15e: 'no checks reported', a docs-only PR that ALSO edits a workflow file — never path-filtered (issue #644 round-3 self-review)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["docs/foo.md",".github/workflows/build.yml"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
# A path filter that WOULD exclude every changed file if it were trusted —
# proves the workflow-edit short-circuit fires before this YAML is ever
# read, not that the filter happens to still match.
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n      - \x27.github/workflows/**\x27\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_WORKFLOW_YAML=
[ "$rc" -eq 4 ] || red "expected exit 4 — a PR that edits a workflow file must never be read as path-filtered, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when the PR itself touches .github/workflows/"
green "a PR that changes a workflow file is always treated as CI-relevant, even if every OTHER changed file is path-filtered (GitHub runs the merge-commit YAML, not the base branch's)"

# ============================================================================
heading "Test 15f: 'no checks reported', a push-only workflow with NO path filter, a source-file change — still refuses ci-pending (issue #644 third follow-up)"
# ============================================================================
# A same-repo PR's branch push fires a push-only workflow too, and that run
# lands on the exact head SHA gh pr checks reads — a bare 'on: push' with no
# paths/paths-ignore filter must never be read as no-trigger/excluded.
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["src/main.py"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_WORKFLOW_YAML=$'on:\n  push:\n    branches: [main]\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_WORKFLOW_YAML=
[ "$rc" -eq 4 ] || red "expected exit 4 — a push-only workflow with no path filter always applies, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when a push-only workflow has no path filter and a source file changed"
green "a push-only workflow with no path filter is never read as no-trigger — still refuses on a source-file change"

# ============================================================================
heading "Test 15g: 'no checks reported', a push-only workflow whose branch filter matches, paths-ignore covering a docs-only PR — still refuses ci-pending (issue #644 round-4 fix)"
# ============================================================================
# GitHub evaluates a push trigger's paths-ignore against that PUSH'S OWN
# diff, never pulls/<pr>/files — a docs-only PR branch can merge master in
# and carry source files on its next push, so this filter is never read at
# all (in either direction). Only the branch filter is, and it matches here,
# so this must still wait rather than readying off a false "excluded".
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["docs/foo.md","README.md"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_PR_HEAD_REF='main'
GH_WORKFLOW_YAML=$'on:\n  push:\n    branches: [main]\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_PR_HEAD_REF=
GH_WORKFLOW_YAML=
[ "$rc" -eq 4 ] || red "expected exit 4 — a push trigger's own paths-ignore is never evaluated, only its branch filter, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run — the branch filter matches, so this commit's run likely hasn't registered yet"
green "a push-only workflow's paths-ignore never excuses readying early — only its branch filter is ever consulted"

# ============================================================================
heading "Test 15i: civicstrata's real build.yml fixture — pull_request + push both paths-ignore docs/md, docs-only PR from fix/issue-639 (not master) — WARNs, still readies"
# ============================================================================
# The coordinator's real-world check (issue #644 round-4 point 2): push's
# branches: [master] doesn't match this PR's head branch (legitimate
# no-trigger), and pull_request's own paths-ignore confidently excludes
# every changed file — together, still a confident "no CI will ever
# register".
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["docs/foo.md","README.md"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_PR_HEAD_REF='fix/issue-639'
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore: [\x27**.md\x27, \x27docs/**\x27]\n  push:\n    branches: [master]\n    paths-ignore: [\x27**.md\x27, \x27docs/**\x27]\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_PR_HEAD_REF=
GH_WORKFLOW_YAML=
[ "$rc" -eq 0 ] || red "expected exit 0 — a docs-only PR from a non-master branch is still confidently excluded, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run once both triggers confirm no CI will ever register"
grep -qi 'WARN' "$TEST_DIR/out.log" || red "expected a WARN about the path-filtered changed files: $(cat "$TEST_DIR/out.log")"
green "civicstrata's exact build.yml shape readies with a WARN for a docs-only PR off a non-master branch"

# ============================================================================
heading "Test 15h: 'no checks reported', PR targets a non-default base branch whose own workflow copy has NO paths-ignore — still refuses ci-pending, even though the default branch's copy ignores docs (issue #644 final round)"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='["docs/foo.md","README.md"]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_PR_BASE_REF='release/2.0'
# The DEFAULT branch's copy ignores docs — if the lookup ever reads this
# instead of the PR's actual base branch, the PR would wrongly ready.
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n'
# The PR's REAL base branch's copy has no path filter at all.
GH_WORKFLOW_YAML_FOR_BASE_REF=$'on:\n  pull_request:\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_PR_BASE_REF=
GH_WORKFLOW_YAML=
GH_WORKFLOW_YAML_FOR_BASE_REF=
[ "$rc" -eq 4 ] || red "expected exit 4 — the PR's own base branch has no path filter at all, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run — the default branch's paths-ignore must never substitute for the PR's actual base branch"
green "a non-default-base PR is evaluated against its OWN base branch's workflow copy, not the repo default branch's"

# ============================================================================
heading "Test 15j: 'no checks reported', a PR's ONLY change is a rename from a non-ignored path into docs/ — still refuses ci-pending (issue #644 round-5)"
# ============================================================================
# The REST files endpoint reports a rename as one entry whose NEW path is
# docs/Foo.kt and whose OLD path (previous_filename) was src/Foo.kt. Only the
# new path is under the paths-ignore filter below — if the old path were
# never added to the changed-file set, this would misread as docs-only and
# ready early even though it's a real source-file move.
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_CHECKS_RC=1
GH_CHECKS_STDERR="no checks reported on the 'main' branch"
GH_WORKFLOW_COUNT=1
GH_PR_FILES_JSON='[{"filename":"docs/Foo.kt","previous_filename":"src/Foo.kt"}]'
GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]'
GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n'
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
GH_CHECKS_STDERR=""
GH_WORKFLOW_COUNT=0
GH_PR_FILES_JSON=
GH_WORKFLOW_PATHS_JSON=
GH_WORKFLOW_YAML=
[ "$rc" -eq 4 ] || red "expected exit 4 — a rename's OLD path (src/Foo.kt) falls outside paths-ignore, so a real run is still pending, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run when a renamed file's old path falls outside every paths-ignore"
green "a rename into docs/ is judged by its OLD path too, not just its new paths-ignored name"

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
heading "Test 19b: --one-more-round past the cap — runs exactly one more round, then readies"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_ROUNDS_DONE=3
GH_LATEST_VERDICT=BLOCK
PR_READY_FLAGS=-y
rc=0; run_pr_ready || rc=$?
PR_READY_FLAGS=
GH_ROUNDS_DONE=0
GH_LATEST_VERDICT=
[ "$rc" -eq 0 ] || red "expected exit 0 after a fresh APPROVE round via -y, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q '42 --post --force' "$FAKE_REVIEW_LOG" || red "expected self-review invoked with -y past the cap, log: $(cat "$FAKE_REVIEW_LOG")"
grep -q 'round 4/4' "$TEST_DIR/out.log" || red "expected 'round 4/4' in output: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run after the extra round approved"
green "-y runs one round past the cap (4/4) and readies on APPROVE"

# ============================================================================
heading "Test 19c: --one-more-round with a BLOCK result still refuses"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 2
GH_ROUNDS_DONE=3
PR_READY_FLAGS=--one-more-round
rc=0; run_pr_ready || rc=$?
PR_READY_FLAGS=
GH_ROUNDS_DONE=0
[ "$rc" -eq 2 ] || red "expected exit 2 when the extra round returns BLOCK, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run after a BLOCK on the extra round"
green "--one-more-round does not bypass a BLOCK verdict"

# ============================================================================
heading "Test 19d: --one-more-round does not override WORKER_SELF_REVIEW_MAX_ROUNDS=0 or an unknown flag"
# ============================================================================
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
WORKER_SELF_REVIEW_MAX_ROUNDS=0
PR_READY_FLAGS=-y
rc=0; run_pr_ready || rc=$?
WORKER_SELF_REVIEW_MAX_ROUNDS=3
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected no self-review with MAX_ROUNDS=0 even with -y, log: $(cat "$FAKE_REVIEW_LOG")"
PR_READY_FLAGS=--bogus
rc=0; run_pr_ready || rc=$?
PR_READY_FLAGS=
[ "$rc" -eq 1 ] || red "expected exit 1 for an unknown flag, got $rc"
gh_ready_called && red "expected gh pr ready NOT to run on an unknown flag"
green "-y leaves a cap of 0 alone; unknown flags exit 1 before touching the PR"

# issue #674: a flag AFTER the PR number must be refused, not silently dropped.
make_fake_review 0
PR_READY_TRAILING=--one-more-round
rc=0; run_pr_ready || rc=$?
PR_READY_TRAILING=
[ "$rc" -eq 1 ] || red "expected exit 1 for a trailing flag, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q "must come before the PR number" "$TEST_DIR/out.log" || red "expected usage hint, got: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run on a trailing flag"
green "trailing flag after the PR number exits 1 and never readies (issue #674)"

# ============================================================================
heading "Test 19e: coordinator-tagged rounds do not inflate the worker's round count (issue #601)"
# ============================================================================
# Real comments fixture (GH_COMMENTS_JSON), not the canned GH_ROUNDS_DONE
# stand-in: exercises pr-ready.sh's ACTUAL jq filter end to end. 3 worker
# rounds + 1 coordinator round, cap=3: ROUNDS_DONE must come out to 3 (the
# coordinator comment excluded), reaching the cap on the worker's own rounds
# alone — not 4, which would also reach it and mask the bug.
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_COMMENTS_JSON='{"comments":[
  {"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\nreview text"},
  {"body":"<!-- SWARM_SELF_REVIEW: BLOCK actor=worker -->\nreview text"},
  {"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\nreview text"},
  {"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=coordinator -->\nreview text"}
]}'
WORKER_SELF_REVIEW_MAX_ROUNDS=3
rc=0; run_pr_ready || rc=$?
GH_COMMENTS_JSON=
WORKER_SELF_REVIEW_MAX_ROUNDS=3
[ "$rc" -eq 0 ] || red "expected exit 0 (capped on APPROVE, no BLOCK anywhere) got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review-pr.sh NOT invoked once the WORKER's 3 rounds reach the cap, log: $(cat "$FAKE_REVIEW_LOG")"
grep -q '3/3 rounds' "$TEST_DIR/out.log" || red "expected '3/3 rounds' (coordinator comment excluded from the count) in output: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run once capped with APPROVE as the latest verdict"
green "3 worker rounds + 1 coordinator round hits the cap at 3/3, not 4/3 — coordinator comment excluded from the count"

# ============================================================================
heading "Test 19f: a coordinator-tagged BLOCK still refuses readying even though it is excluded from the worker's round count (issue #601)"
# ============================================================================
# Same 3 worker rounds (hits the cap on its own), but the actual latest
# comment overall is a coordinator BLOCK. ROUNDS_DONE excludes it (still
# 3/3, same as 19e) yet the LATEST_VERDICT check — deliberately NOT
# actor-scoped — must still see it and refuse. Proves the two queries are
# independently correct: one actor-filtered (the cost/time budget), one not
# (the correctness/safety gate).
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_COMMENTS_JSON='{"comments":[
  {"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\nreview text"},
  {"body":"<!-- SWARM_SELF_REVIEW: BLOCK actor=worker -->\nreview text"},
  {"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\nreview text"},
  {"body":"<!-- SWARM_SELF_REVIEW: BLOCK actor=coordinator -->\nreview text"}
]}'
WORKER_SELF_REVIEW_MAX_ROUNDS=3
rc=0; run_pr_ready || rc=$?
GH_COMMENTS_JSON=
WORKER_SELF_REVIEW_MAX_ROUNDS=3
[ "$rc" -eq 2 ] || red "expected exit 2 (coordinator BLOCK still refuses) got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review-pr.sh NOT invoked, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called && red "expected gh pr ready NOT to run when a coordinator-found BLOCK is the latest verdict"
grep -qi 'BLOCK' "$TEST_DIR/out.log" || red "expected a BLOCK refusal message in output: $(cat "$TEST_DIR/out.log")"
green "a coordinator BLOCK still refuses readying although it never counted toward the worker's own 3/3 round cap"

# ============================================================================
heading "Test 19g: a worker round whose review PROSE mentions 'actor=coordinator' still counts as the worker's own (self-review finding, issue #601)"
# ============================================================================
# The actor must come from the marker tag itself (capture() anchored right
# after "SWARM_SELF_REVIEW: <VERDICT>"), not a bare contains() anywhere in
# the comment body — a worker's own review discussing this very PR's
# actor-exclusion fix, which quotes "actor=coordinator" in its prose, must
# not get misread as a coordinator round and silently dropped from the
# worker's own count (which would let one extra round through uncounted).
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
GH_COMMENTS_JSON='{"comments":[
  {"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\nreview text"},
  {"body":"<!-- SWARM_SELF_REVIEW: BLOCK actor=worker -->\nreview mentions actor=coordinator and actor=operator in its prose while describing the fix, but is itself a worker round"},
  {"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\nreview text"}
]}'
WORKER_SELF_REVIEW_MAX_ROUNDS=3
rc=0; run_pr_ready || rc=$?
GH_COMMENTS_JSON=
WORKER_SELF_REVIEW_MAX_ROUNDS=3
[ "$rc" -eq 0 ] || red "expected exit 0 (capped on APPROVE, no BLOCK) got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review-pr.sh NOT invoked, log: $(cat "$FAKE_REVIEW_LOG")"
grep -q '3/3 rounds' "$TEST_DIR/out.log" || red "expected all 3 worker rounds to count despite one's prose mentioning other actors: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run once capped with APPROVE as the latest verdict"
green "a worker round's prose mentioning 'actor=coordinator'/'actor=operator' still counts as the worker's own — the actor comes from the marker tag, not a body-wide substring match"

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

# ============================================================================
# issue #602 (Tests 25-30): the SWARM_DRAFT_REASON banner.
# ============================================================================
banner() {  # banner <reason> <sha> — a body carrying an existing banner
    printf '<!-- SWARM_DRAFT_REASON: %s sha=%s -->\n> ⏳ **Still a draft:** old text\n<!-- /SWARM_DRAFT_REASON -->\n<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' "$1" "$2"
}

heading "Test 25: CI pending — refusal writes a ci-pending banner with the head SHA, body kept"
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
GH_CHECKS_RC=8
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
[ "$rc" -eq 4 ] || red "expected exit 4, got $rc: $(cat "$TEST_DIR/out.log")"
[ -f "$EDITED_BODY" ] || red "expected the PR body to be edited with a banner"
head -1 "$EDITED_BODY" | grep -qx '<!-- SWARM_DRAFT_REASON: ci-pending sha=deadbeef -->' || red "expected ci-pending banner first: $(cat "$EDITED_BODY")"
grep -q 'Still a draft:.*CI was still running' "$EDITED_BODY" || red "expected plain-language reason: $(cat "$EDITED_BODY")"
grep -qxF '> **Next:** coordinator (watcher, automatic) — re-runs pr-ready.sh 42 — waiting on CI to finish on deadbee' "$EDITED_BODY" || red "expected issue #635 Next line: $(cat "$EDITED_BODY")"
grep -q '^<!-- BLIND_MERGE_RISK: low -->$' "$EDITED_BODY" || red "expected original body kept: $(cat "$EDITED_BODY")"
green "CI-pending refusal records why on the PR itself"

heading "Test 26: self-review BLOCK — refusal writes a review-block banner"
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 2
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 2 ] || red "expected exit 2, got $rc"
head -1 "$EDITED_BODY" | grep -qx '<!-- SWARM_DRAFT_REASON: review-block sha=deadbeef -->' || red "expected review-block banner: $(cat "$EDITED_BODY" 2>/dev/null)"
grep -q '^> \*\*Next:\*\* worker iss-7 — fix the finding, push, re-run pr-ready.sh 42 — waiting on nothing$' "$EDITED_BODY" || red "expected Next line naming worker iss-7: $(cat "$EDITED_BODY")"
green "BLOCK refusal records review-block"

heading "Test 27: ci-pending banner on the current head + green CI — skips self-review, strips banner, readies"
banner ci-pending deadbeef > "$BODY_FILE"
make_fake_review 2  # would BLOCK if it ran
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "expected self-review skipped for an already-reviewed head"
gh_ready_called || red "expected gh pr ready to run"
grep -q 'SWARM_DRAFT_REASON\|Still a draft' "$EDITED_BODY" && red "expected banner stripped: $(cat "$EDITED_BODY")"
grep -q '^<!-- BLIND_MERGE_RISK: medium -->$' "$EDITED_BODY" || red "expected rest of body kept: $(cat "$EDITED_BODY")"
green "retry on the same commit spends no review round and cleans up the banner"

heading "Test 28: ci-pending banner on an OLD sha — self-review runs again"
banner ci-pending 0ddc0de > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q '42 --post --force' "$FAKE_REVIEW_LOG" || red "expected self-review to run for a new head commit"
green "a new push re-earns its review"

heading "Test 29: review-block banner on the current head — self-review still runs"
banner review-block deadbeef > "$BODY_FILE"
make_fake_review 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc"
grep -q '42 --post --force' "$FAKE_REVIEW_LOG" || red "expected self-review to run after a review-block"
green "only ci-* banners skip review"

heading "Test 30: same reason on the same sha — body left alone (no churn on sweep retries)"
banner ci-pending deadbeef > "$BODY_FILE"
GH_CHECKS_RC=8
rc=0; run_pr_ready || rc=$?
GH_CHECKS_RC=0
[ "$rc" -eq 4 ] || red "expected exit 4, got $rc"
[ ! -f "$EDITED_BODY" ] || red "expected no body edit for an unchanged reason: $(cat "$EDITED_BODY")"
green "repeat refusal doesn't rewrite the body"


heading "Test 31: held PR + BLOCK — the banner's Next line defers to the COORDINATOR HOLD (issue #635)"
printf '> ⛔ **COORDINATOR HOLD** — fix queued; do not merge\n\n<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 2
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 2 ] || red "expected exit 2, got $rc"
[ "$(grep -c '\*\*Next:\*\*' "$EDITED_BODY")" -eq 1 ] || red "expected exactly one Next line: $(cat "$EDITED_BODY")"
grep -q '^> \*\*Next:\*\* coordinator — whatever the ⛔ COORDINATOR HOLD banner' "$EDITED_BODY" || red "expected Next to defer to the hold: $(cat "$EDITED_BODY")"
green "a held PR's draft-reason banner doesn't compete with the hold's own Next line"


# ============================================================================
# issue #616: a coordinator hold must survive a worker's body rewrite and a
# hold that lands while pr-ready.sh is mid-flight. The hold signal is the
# newest hold-vs-lift COMMENT as well as the body banner.
# ============================================================================
HOLD_C='{"body":"⛔ **COORDINATOR HOLD** — fix queued\n<!-- SWARM_COORDINATOR_HOLD -->"}'
LIFT_C='{"body":"✅ **COORDINATOR HOLD lifted** — fix verified\n<!-- SWARM_COORDINATOR_HOLD_LIFTED -->"}'

heading "Test 32: replay of #616 — hold comment, body rewritten WITHOUT the banner — stays draft, banner restored"
printf '<!-- BLIND_MERGE_RISK: low -->\nworker rewrote the whole body\n' > "$BODY_FILE"
GH_HOLD_COMMENTS_JSON="{\"comments\":[$HOLD_C]}"
GH_IS_DRAFT=false
make_fake_review 0
rc=0; run_pr_ready || rc=$?
GH_HOLD_COMMENTS_JSON=; GH_IS_DRAFT=true
[ "$rc" -eq 3 ] || red "expected exit 3 (held by comment), got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run on a comment-held PR"
gh_undo_called || red "expected the non-draft held PR to be drafted again: $(cat "$GH_LOG")"
head -1 "$EDITED_BODY" | grep -qE '^> ⛔ \*\*COORDINATOR HOLD\*\*' || red "expected the banner restored on top: $(cat "$EDITED_BODY" 2>/dev/null)"
grep -q 'worker rewrote the whole body' "$EDITED_BODY" || red "expected the rewritten body kept under the banner: $(cat "$EDITED_BODY")"
green "a dropped banner is restored and the PR stays draft (exit 3)"

heading "Test 33: hold comment followed by a lift comment — not held, readies"
printf '<!-- BLIND_MERGE_RISK: low -->\nfix landed\n' > "$BODY_FILE"
GH_HOLD_COMMENTS_JSON="{\"comments\":[$HOLD_C,$LIFT_C]}"
rc=0; run_pr_ready || rc=$?
GH_HOLD_COMMENTS_JSON=
[ "$rc" -eq 0 ] || red "expected exit 0 once the hold is lifted, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run after the lift"
green "a lift comment newer than the hold releases it"

heading "Test 34: lift comment followed by a NEWER hold comment — held"
printf '<!-- BLIND_MERGE_RISK: low -->\nsecond round\n' > "$BODY_FILE"
GH_HOLD_COMMENTS_JSON="{\"comments\":[$HOLD_C,$LIFT_C,$HOLD_C]}"
rc=0; run_pr_ready || rc=$?
GH_HOLD_COMMENTS_JSON=
[ "$rc" -eq 3 ] || red "expected exit 3 for a re-held PR, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run"
green "only the newest of hold/lift counts"

heading "Test 35: comment text forms — only the hold marker holds, only the strict lift forms lift; self-review prose that quotes either form does neither"
printf '<!-- BLIND_MERGE_RISK: low -->\nbody\n' > "$BODY_FILE"
GH_HOLD_COMMENTS_JSON='{"comments":[{"body":"⛔ **COORDINATOR HOLD** — x\n<!-- SWARM_COORDINATOR_HOLD -->"},{"body":"COORDINATOR HOLD lifted — fix verified"}]}'
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected a 'COORDINATOR HOLD lifted' line to lift, got $rc: $(cat "$TEST_DIR/out.log")"
GH_HOLD_COMMENTS_JSON='{"comments":[{"body":"⛔ **COORDINATOR HOLD** — x\n<!-- SWARM_COORDINATOR_HOLD -->"},{"body":"Hold lifted — a stray aside from anyone"}]}'
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 3 ] || red "expected a loose 'Hold lifted' aside NOT to lift (fail toward held), got $rc"
GH_HOLD_COMMENTS_JSON='{"comments":[{"body":"⛔ **COORDINATOR HOLD** — x\n<!-- SWARM_COORDINATOR_HOLD -->"},{"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\nreview\nhold lifted\n"}]}'
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 3 ] || red "expected a self-review comment quoting 'hold lifted' NOT to lift, got $rc"
GH_HOLD_COMMENTS_JSON='{"comments":[{"body":"<!-- SWARM_SELF_REVIEW: APPROVE actor=worker -->\n> ⛔ **COORDINATOR HOLD** quoted in review prose\n"}]}'
rc=0; run_pr_ready || rc=$?
GH_HOLD_COMMENTS_JSON=
[ "$rc" -eq 0 ] || red "expected a self-review comment quoting the banner NOT to hold, got $rc: $(cat "$TEST_DIR/out.log")"
green "the hold marker and strict lift forms decide; review prose is ignored"

heading "Test 35b: a comment merely QUOTING the hold marker (prose or backticks) does not hold; a real one still does (issue #707)"
printf '<!-- BLIND_MERGE_RISK: low -->\nbody\n' > "$BODY_FILE"
GH_HOLD_COMMENTS_JSON='{"comments":[{"body":"The marker `<!-- SWARM_COORDINATOR_HOLD -->` is what pr-ready.sh looks for, and <!-- SWARM_COORDINATOR_HOLD --> in prose is just text."}]}'
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected a comment quoting the marker NOT to hold, got $rc: $(cat "$TEST_DIR/out.log")"
GH_HOLD_COMMENTS_JSON="{\"comments\":[$HOLD_C]}"
rc=0; run_pr_ready || rc=$?
GH_HOLD_COMMENTS_JSON=
[ "$rc" -eq 3 ] || red "expected a real hold comment to still hold, got $rc: $(cat "$TEST_DIR/out.log")"
green "only the marker on a line of its own holds"

heading "Test 36: hold comment lands AFTER the CI snapshot, before gh pr ready — refuses to ready"
printf '<!-- BLIND_MERGE_RISK: low -->\nfinalizing\n' > "$BODY_FILE"
GH_HOLD_LATE_COMMENTS_JSON="{\"comments\":[$HOLD_C]}"
rc=0; run_pr_ready || rc=$?
GH_HOLD_LATE_COMMENTS_JSON=
[ "$rc" -eq 3 ] || red "expected exit 3 for a hold landing mid-run, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run after a late hold: $(cat "$GH_LOG")"
green "the hold is re-checked immediately before gh pr ready"

heading "Test 37: banner lands mid-run while a draft-reason banner is on the body — held, body not overwritten from the stale copy"
banner ci-pending deadbeef > "$BODY_FILE"
GH_HOLD_LATE_BODY="$(printf '> ⛔ **COORDINATOR HOLD** — fix queued\n\n<!-- SWARM_DRAFT_REASON: ci-pending sha=deadbeef -->\n> ⏳ **Still a draft:** x\n<!-- /SWARM_DRAFT_REASON -->\n<!-- BLIND_MERGE_RISK: medium -->\nsome change')"
make_fake_review 2  # skipped: ci-pending on the current head
rc=0; run_pr_ready || rc=$?
GH_HOLD_LATE_BODY=
[ "$rc" -eq 3 ] || red "expected exit 3, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "expected gh pr ready NOT to run"
[ ! -f "$EDITED_BODY" ] || red "expected no body rewrite (it would have dropped the new banner): $(cat "$EDITED_BODY")"
green "a banner added mid-run is never overwritten by the stale start-of-run body"

heading "Test 38: banner-held PR that is no longer a draft is drafted again"
printf '> ⛔ **COORDINATOR HOLD** — fix queued\n\n<!-- BLIND_MERGE_RISK: low -->\nx\n' > "$BODY_FILE"
GH_IS_DRAFT=false
rc=0; run_pr_ready || rc=$?
GH_IS_DRAFT=true
[ "$rc" -eq 3 ] || red "expected exit 3, got $rc"
gh_undo_called || red "expected gh pr ready --undo 42: $(cat "$GH_LOG")"
gh_ready_called && red "expected the real gh pr ready NOT to run"
green "a held PR found ready is put back to draft"

heading "Test 39: legacy marker-less hold comment + free-text lift, no banner in the body — NOT re-held (PR #705 review)"
printf '<!-- BLIND_MERGE_RISK: low -->\nfix landed\n' > "$BODY_FILE"
# Old-prompt era: the hold comment had no marker (one even starts with the
# banner text) and the lift was free text. Neither is recognised, so the PR
# must ready normally instead of being re-held until a lift marker appears.
GH_HOLD_COMMENTS_JSON='{"comments":[{"body":"Holding this PR: fix brief queued to iss-9."},{"body":"⛔ **COORDINATOR HOLD** — fix queued to iss-9"},{"body":"Hold lifted: fix verified, re-readying."}]}'
rc=0; run_pr_ready || rc=$?
GH_HOLD_COMMENTS_JSON=
[ "$rc" -eq 0 ] || red "expected exit 0 — legacy hold + free-text lift must not re-hold, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run: $(cat "$GH_LOG")"
[ -s "$EDITED_BODY" ] && grep -q 'COORDINATOR HOLD' "$EDITED_BODY" && red "expected no hold banner written to the body: $(cat "$EDITED_BODY")"
green "marker-less legacy hold comments are ignored, so an old free-text lift cannot re-hold"

heading "Test 40: open-PR migration clash (check exits 6) — WARN with the clash text, still readies (issue #633)"
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
FAKE_MIGRATION_CHECK="$TEST_DIR/fake-migration-check.sh"
printf '#!/usr/bin/env bash\necho "- Flyway V9 is added by: PR #42 (a.sql); PR #43 (b.sql)"\nexit 6\n' > "$FAKE_MIGRATION_CHECK"
chmod +x "$FAKE_MIGRATION_CHECK"
MIGRATION_CHECK_SCRIPT="$FAKE_MIGRATION_CHECK"
rc=0; run_pr_ready || rc=$?
MIGRATION_CHECK_SCRIPT=""
[ "$rc" -eq 0 ] || red "an open-PR clash must not block, got exit $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to still run despite the clash warning"
grep -q 'WARN: another open PR adds the same migration version' "$TEST_DIR/out.log" || red "expected the clash WARN: $(cat "$TEST_DIR/out.log")"
grep -q 'Flyway V9 is added by' "$TEST_DIR/out.log" || red "expected the check's clash text in the WARN: $(cat "$TEST_DIR/out.log")"
green "exit 6 from the migration check → WARN printed, PR still readied"

heading "Test 41: migration check exits 0 — no warning at all"
printf '#!/usr/bin/env bash\necho "verdict: clean"\nexit 0\n' > "$FAKE_MIGRATION_CHECK"
MIGRATION_CHECK_SCRIPT="$FAKE_MIGRATION_CHECK"
rc=0; run_pr_ready || rc=$?
MIGRATION_CHECK_SCRIPT=""
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
grep -qi 'another open PR' "$TEST_DIR/out.log" && red "clean migration check must be silent: $(cat "$TEST_DIR/out.log")"
green "exit 0 from the migration check → silent"

heading "Test 42: hung migration check is time-bounded — pr-ready still readies (issue #713)"
# GNU timeout signals its whole process group, so a plain `sleep 30 &` would die
# with the script and a $(...) capture would pass too. `setsid` moves the
# grandchild to its own session so it genuinely survives and holds the pipe open.
printf '#!/usr/bin/env bash\nsetsid sleep 30 &\nwait\nexit 6\n' > "$FAKE_MIGRATION_CHECK"
MIGRATION_CHECK_SCRIPT="$FAKE_MIGRATION_CHECK"
export MIGRATION_CHECK_TIMEOUT=1
SECONDS=0; rc=0; run_pr_ready || rc=$?
unset MIGRATION_CHECK_TIMEOUT
MIGRATION_CHECK_SCRIPT=""
[ "$rc" -eq 0 ] || red "expected exit 0 with a hung check, got $rc: $(cat "$TEST_DIR/out.log")"
[ "$SECONDS" -lt 20 ] || red "pr-ready waited ${SECONDS}s on a hung check"
grep -qi 'another open PR' "$TEST_DIR/out.log" && red "timed-out check must not report a clash"
grep -q 'migration check timed out after 1s' "$TEST_DIR/out.log" || red "expected one timeout line: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run despite the hung check"
green "hung check killed by timeout → one timeout line, PR readied"

heading "Test 43: migration check WARN on stderr reaches the caller (issue #736)"
printf '#!/usr/bin/env bash\necho "WARN: PR #9 lists >=100 files; truncated" >&2\nexit 0\n' > "$FAKE_MIGRATION_CHECK"
MIGRATION_CHECK_SCRIPT="$FAKE_MIGRATION_CHECK"
rc=0; run_pr_ready || rc=$?
MIGRATION_CHECK_SCRIPT=""
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q 'migration check: WARN: PR #9 lists' "$TEST_DIR/out.log" || red "check's stderr warning was dropped: $(cat "$TEST_DIR/out.log")"
green "stderr warning surfaced"

# ============================================================================
# issue #731: risk floor (Tests 44-47) and the optional 🟢 review (Tests 48-52)
# ============================================================================
heading "Test 44: 🟢 whose diff is above the floor is bumped and takes the 🟡 review path"
printf '<!-- BLIND_MERGE_RISK: low -->\nadds a migration\n' > "$BODY_FILE"
make_fake_review 0; make_fake_floor 10
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q -- '--apply 42' "$FAKE_FLOOR_LOG" || red "risk-floor.sh --apply not called: $(cat "$FAKE_FLOOR_LOG")"
grep -q 'rating bumped' "$TEST_DIR/out.log" || red "bump not announced: $(cat "$TEST_DIR/out.log")"
grep -q 'migrations' "$TEST_DIR/out.log" || red "rule that fired not shown: $(cat "$TEST_DIR/out.log")"
grep -q -- '--post --force --actor worker' "$FAKE_REVIEW_LOG" || red "bumped PR must go through self-review, log: $(cat "$FAKE_REVIEW_LOG")"
grep -q -- '--model' "$FAKE_REVIEW_LOG" && red "a bumped 🟡 review must not use the green-review model: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready after the review passed"
green "bump → marker now medium → self-review runs → readies"

heading "Test 45: a bumped PR whose review says BLOCK is still refused"
printf '<!-- BLIND_MERGE_RISK: low -->\nadds a migration\n' > "$BODY_FILE"
make_fake_review 2; make_fake_floor 10
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 2 ] || red "expected exit 2 (BLOCK), got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "gh pr ready must not run after BLOCK"
green "bumped PR + BLOCK → refused"

heading "Test 46: risk-floor.sh failing → 🟢 treated as 🟡 for this run (fails toward review)"
printf '<!-- BLIND_MERGE_RISK: low -->\nsmall\n' > "$BODY_FILE"
make_fake_review 0; make_fake_floor 1
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q 'risk-floor.sh failed' "$TEST_DIR/out.log" || red "failure not surfaced: $(cat "$TEST_DIR/out.log")"
grep -q -- '--post --force --actor worker' "$FAKE_REVIEW_LOG" || red "floor failure must trigger review, log: $(cat "$FAKE_REVIEW_LOG")"
green "floor failure → review runs"

heading "Test 47: floor satisfied (🟢 stays 🟢) and RISK_FLOOR=0 skips the check entirely"
printf '<!-- BLIND_MERGE_RISK: low -->\nsmall\n' > "$BODY_FILE"
make_fake_review 0; make_fake_floor 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc"
grep -q -- '--apply 42' "$FAKE_FLOOR_LOG" || red "floor should have been consulted"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "no review expected for an unbumped 🟢, log: $(cat "$FAKE_REVIEW_LOG")"
rc=0; RISK_FLOOR=0 run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 with RISK_FLOOR=0, got $rc"
[ ! -s "$FAKE_FLOOR_LOG" ] || red "RISK_FLOOR=0 must not call risk-floor.sh, log: $(cat "$FAKE_FLOOR_LOG")"
green "floor consulted by default; RISK_FLOOR=0 skips it"

heading "Test 48: GREEN_REVIEW unset / 0 — no review call for 🟢 (behaviour as before)"
printf '<!-- BLIND_MERGE_RISK: low -->\nsmall\n' > "$BODY_FILE"
make_fake_review 2; make_fake_floor 0
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "unset: expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "unset: review must not run, log: $(cat "$FAKE_REVIEW_LOG")"
rc=0; GREEN_REVIEW=0 run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "GREEN_REVIEW=0: expected exit 0, got $rc"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "GREEN_REVIEW=0: review must not run, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready"
green "GREEN_REVIEW off → zero review calls, even with a reviewer that would BLOCK"

heading "Test 49: GREEN_REVIEW=1 runs the review on a 🟢 PR with the haiku model by default"
make_fake_review 0
rc=0; GREEN_REVIEW=1 run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q -- '42 --post --force --actor worker --model haiku' "$FAKE_REVIEW_LOG" || red "expected review with --model haiku, log: $(cat "$FAKE_REVIEW_LOG")"
gh_ready_called || red "expected gh pr ready after APPROVE"
rc=0; GREEN_REVIEW=1 GREEN_REVIEW_MODEL=claude-haiku-5-5 run_pr_ready || rc=$?
grep -q -- '--model claude-haiku-5-5' "$FAKE_REVIEW_LOG" || red "GREEN_REVIEW_MODEL not honoured, log: $(cat "$FAKE_REVIEW_LOG")"
green "GREEN_REVIEW=1 → review with --model \${GREEN_REVIEW_MODEL:-haiku}"

heading "Test 50: GREEN_REVIEW=1 — BLOCK refuses to ready; caveats do not"
make_fake_review 2
rc=0; GREEN_REVIEW=1 run_pr_ready || rc=$?
[ "$rc" -eq 2 ] || red "expected exit 2 on BLOCK, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "gh pr ready must not run after a green-review BLOCK"
make_fake_review 3
rc=0; GREEN_REVIEW=1 run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0 on APPROVE_WITH_CAVEATS, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "caveats must not block readying"
green "BLOCK refuses, caveats proceed"

heading "Test 51: GREEN_REVIEW=1 still honours WORKER_SELF_REVIEW=0"
make_fake_review 2
rc=0; GREEN_REVIEW=1 WORKER_SELF_REVIEW=0 run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "kill switch must win, log: $(cat "$FAKE_REVIEW_LOG")"
green "kill switch wins over GREEN_REVIEW"

heading "Test 52: GREEN_REVIEW=1 does not touch a 🟡 PR's model"
printf '<!-- BLIND_MERGE_RISK: medium -->\nsource change\n' > "$BODY_FILE"
make_fake_review 0
rc=0; GREEN_REVIEW=1 run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc"
grep -q -- '--model' "$FAKE_REVIEW_LOG" && red "🟡 must keep the default model, log: $(cat "$FAKE_REVIEW_LOG")"
[ ! -s "$FAKE_FLOOR_LOG" ] || red "floor is only consulted for 🟢, log: $(cat "$FAKE_FLOOR_LOG")"
green "🟡 unaffected"

# issue #494 (Tests 44-48): optional WORKER_PR_READY_CHECK_CMD gate. It only runs when
# the caller's cwd HEAD is the PR head, so tests 45-47 run from a throwaway checkout
# whose HEAD is the faked PR head (GH_SHA); test 48 is the mismatch case.
CHECKOUT="$TEST_DIR/ready-checkout"
mkdir -p "$CHECKOUT"
git -C "$CHECKOUT" init -q
git -C "$CHECKOUT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
CHECKOUT_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
heading "Test 44: WORKER_PR_READY_CHECK_CMD unset — behaves as before, nothing run"
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
unset WORKER_PR_READY_CHECK_CMD
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q 'WORKER_PR_READY_CHECK_CMD' "$TEST_DIR/out.log" && red "unset knob must print nothing: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready to run"
green "unset → no check, readied"

heading "Test 45: ready check passes — runs once, PR readied"
export WORKER_PR_READY_CHECK_CMD="echo ran >> '$TEST_DIR/ready-check.ran'"
export PR_READY_CWD="$CHECKOUT" GH_SHA="$CHECKOUT_SHA"
rm -f "$TEST_DIR/ready-check.ran"
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
[ "$(wc -l < "$TEST_DIR/ready-check.ran")" -eq 1 ] || red "expected the check to run exactly once"
grep -q 'ready check PASS' "$TEST_DIR/out.log" || red "expected a PASS line: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready after a passing check"
green "passing ready check → run once, readied"

heading "Test 46: ready check fails — refuses (exit 6), writes check-failing banner, never readies, self-review not spent"
printf '<!-- BLIND_MERGE_RISK: medium -->\nsome change\n' > "$BODY_FILE"
make_fake_review 0
rm -f "$CHECKOUT/.git/swarm-ready-check-pass"
export WORKER_PR_READY_CHECK_CMD='echo suite-broke; exit 3'
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 6 ] || red "expected exit 6, got $rc: $(cat "$TEST_DIR/out.log")"
gh_ready_called && red "gh pr ready must not run after a failed ready check"
[ ! -s "$FAKE_REVIEW_LOG" ] || red "self-review should not run before the ready check passes"
grep -q 'suite-broke' "$TEST_DIR/out.log" || red "expected the check's output tail: $(cat "$TEST_DIR/out.log")"
head -1 "$EDITED_BODY" | grep -qx "<!-- SWARM_DRAFT_REASON: check-failing sha=$CHECKOUT_SHA -->" || red "expected check-failing banner: $(cat "$EDITED_BODY" 2>/dev/null)"
green "failing ready check → exit 6, banner, no ready, no review round"

heading "Test 47: ready check timeout also refuses"
export WORKER_PR_READY_CHECK_CMD='sleep 20' WORKER_PR_READY_CHECK_TIMEOUT=1
rc=0; run_pr_ready || rc=$?
unset WORKER_PR_READY_CHECK_CMD WORKER_PR_READY_CHECK_TIMEOUT PR_READY_CWD GH_SHA
[ "$rc" -eq 6 ] || red "expected exit 6 on timeout, got $rc: $(cat "$TEST_DIR/out.log")"
grep -q '124 = timed out' "$TEST_DIR/out.log" || red "expected the timeout hint: $(cat "$TEST_DIR/out.log")"
green "timed-out ready check → exit 6"

heading "Test 48: cwd HEAD is not the PR head — check skipped with one stderr line, not refused, PR still readied"
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
rm -f "$TEST_DIR/ready-check.ran"
export WORKER_PR_READY_CHECK_CMD="echo ran >> '$TEST_DIR/ready-check.ran'"
export PR_READY_CWD="$CHECKOUT" GH_SHA=cafef00dcafef00dcafef00dcafef00dcafef00d
rc=0; run_pr_ready || rc=$?
unset WORKER_PR_READY_CHECK_CMD PR_READY_CWD GH_SHA
[ "$rc" -eq 0 ] || red "expected exit 0 (skip, not refuse), got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -e "$TEST_DIR/ready-check.ran" ] || red "check must not run when cwd is not at the PR head"
grep -qx "pr-ready: pre-ready check skipped: cwd is not at PR head cafef00" "$TEST_DIR/out.log" || red "expected the skip line: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready after a skipped check"
green "mismatched cwd → skipped, readied"

heading "Test 56: dirty working tree at the PR head — check skipped with one stderr line, no pass record, PR still readied"
printf '<!-- BLIND_MERGE_RISK: low -->\nsome change\n' > "$BODY_FILE"
rm -f "$TEST_DIR/ready-check.ran" "$CHECKOUT/.git/swarm-ready-check-pass"
echo dirty > "$CHECKOUT/uncommitted.txt"
export WORKER_PR_READY_CHECK_CMD="echo ran >> '$TEST_DIR/ready-check.ran'"
export PR_READY_CWD="$CHECKOUT" GH_SHA="$CHECKOUT_SHA"
rc=0; run_pr_ready || rc=$?
unset WORKER_PR_READY_CHECK_CMD PR_READY_CWD GH_SHA
rm -f "$CHECKOUT/uncommitted.txt"
[ "$rc" -eq 0 ] || red "expected exit 0 (skip, not refuse), got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -e "$TEST_DIR/ready-check.ran" ] || red "check must not run on a dirty tree"
[ ! -e "$CHECKOUT/.git/swarm-ready-check-pass" ] || red "no pass may be recorded on a dirty tree"
grep -q "pre-ready check skipped: working tree has uncommitted changes" "$TEST_DIR/out.log" || red "expected the dirty-tree skip line: $(cat "$TEST_DIR/out.log")"
gh_ready_called || red "expected gh pr ready after a skipped check"
green "dirty tree → skipped, no pass record, readied"


heading "Test 53: ci-* refusal on the same SHA but no pass record — the ready check still runs"
rm -f "$CHECKOUT/.git/swarm-ready-check-pass" "$TEST_DIR/ready-check.ran"
banner ci-pending "$CHECKOUT_SHA" > "$BODY_FILE"
export WORKER_PR_READY_CHECK_CMD="echo ran >> '$TEST_DIR/ready-check.ran'"
export PR_READY_CWD="$CHECKOUT" GH_SHA="$CHECKOUT_SHA"
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
[ "$(wc -l < "$TEST_DIR/ready-check.ran")" -eq 1 ] || red "check must run when no pass record exists: $(cat "$TEST_DIR/out.log")"
grep -q 'ready check already passed' "$TEST_DIR/out.log" && red "must not claim an unrecorded pass: $(cat "$TEST_DIR/out.log")"
[ "$(cat "$CHECKOUT/.git/swarm-ready-check-pass")" = "pass sha=$CHECKOUT_SHA" ] || red "expected a pass record after the check exited 0"
green "ci-* banner alone → check runs, pass recorded"

heading "Test 54: pass record matching the head SHA + ci-* refusal — check skipped"
rm -f "$TEST_DIR/ready-check.ran"
banner ci-pending "$CHECKOUT_SHA" > "$BODY_FILE"
rc=0; run_pr_ready || rc=$?
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
[ ! -e "$TEST_DIR/ready-check.ran" ] || red "check must not re-run when the pass record matches"
grep -q 'ready check already passed' "$TEST_DIR/out.log" || red "expected the already-passed line: $(cat "$TEST_DIR/out.log")"
green "matching pass record → not re-run"

heading "Test 55: pass record for a different SHA — check runs again"
printf 'pass sha=0000000000000000000000000000000000000000\n' > "$CHECKOUT/.git/swarm-ready-check-pass"
rc=0; run_pr_ready || rc=$?
unset WORKER_PR_READY_CHECK_CMD PR_READY_CWD GH_SHA
[ "$rc" -eq 0 ] || red "expected exit 0, got $rc: $(cat "$TEST_DIR/out.log")"
[ -e "$TEST_DIR/ready-check.ran" ] || red "stale-SHA pass record must not skip the check"
green "stale record → check runs"

green "ALL TESTS PASSED"
