#!/usr/bin/env bash
#
# test-shape-ci-wait.sh — Non-LLM shape tests for scripts/ci-wait.sh (#297):
# the CONFLICTING/DIRTY mergeability short-circuit, plus the green/red/
# timeout exit codes from the bounded `gh pr checks` poll. `gh` is stubbed
# via a PATH override so no network/GitHub access is needed.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_WAIT="$SCRIPT_DIR/../scripts/ci-wait.sh"
[ -x "$CI_WAIT" ] || red "not executable: $CI_WAIT"

TEST_DIR=$(mktemp -d -t shape-ci-wait-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

PASS=0
check() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        green "$desc"
        PASS=$((PASS + 1))
    else
        red "$desc"
    fi
}

# ─────────────────────────── gh stub ────────────────────────────────────────

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -n "${GH_ARGS_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_ARGS_LOG"
case "$1 $2" in
    "pr view")
        n=0
        if [ -f "${GH_CALL_COUNT_FILE:-/dev/null}" ]; then n="$(cat "$GH_CALL_COUNT_FILE")"; fi
        n=$((n + 1))
        [ -n "${GH_CALL_COUNT_FILE:-}" ] && echo "$n" > "$GH_CALL_COUNT_FILE"
        if [ "$n" = "1" ] && [ "${GH_VIEW_UNKNOWN_FIRST:-0}" = "1" ]; then
            echo '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefOid":"deadbeef"}'
        else
            echo "{\"mergeable\":\"${GH_VIEW_MERGEABLE:-MERGEABLE}\",\"mergeStateStatus\":\"${GH_VIEW_STATE:-CLEAN}\",\"headRefOid\":\"deadbeef\"}"
        fi
        exit 0 ;;
    "pr checks")
        cn=0
        if [ -f "${GH_CHECKS_CALL_COUNT_FILE:-/dev/null}" ]; then cn="$(cat "$GH_CHECKS_CALL_COUNT_FILE")"; fi
        cn=$((cn + 1))
        [ -n "${GH_CHECKS_CALL_COUNT_FILE:-}" ] && echo "$cn" > "$GH_CHECKS_CALL_COUNT_FILE"
        if [ "${GH_CHECKS_PERM_ERROR:-0}" = "1" ]; then
            echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.contexts.nodes)" >&2
            exit 1
        fi
        if [ "$cn" -le "${GH_CHECKS_NO_CHECKS_UNTIL:-0}" ] || [ "${GH_CHECKS_NO_CHECKS:-0}" = "1" ]; then
            echo "no checks reported on the 'main' branch" >&2
            exit 1
        fi
        exit "${GH_CHECKS_RC:-0}" ;;
    "api repos/{owner}/{repo}/actions/workflows"|"api repos/owner/repo/actions/workflows")
        echo "${GH_WORKFLOW_COUNT:-1}"
        exit 0 ;;
    "run list")
        rn=0
        if [ -f "${GH_RUNLIST_CALL_COUNT_FILE:-/dev/null}" ]; then rn="$(cat "$GH_RUNLIST_CALL_COUNT_FILE")"; fi
        rn=$((rn + 1))
        [ -n "${GH_RUNLIST_CALL_COUNT_FILE:-}" ] && echo "$rn" > "$GH_RUNLIST_CALL_COUNT_FILE"
        if [ "${GH_RUNLIST_STDERR_NOISE:-0}" = "1" ]; then
            echo "warning: some deprecation notice from gh itself" >&2
        fi
        if [ -n "${GH_RUNLIST_JSON_SEQUENCE:-}" ]; then
            idx="$rn"
            lines="$(wc -l < "$GH_RUNLIST_JSON_SEQUENCE")"
            [ "$idx" -le "$lines" ] || idx="$lines"
            sed -n "${idx}p" "$GH_RUNLIST_JSON_SEQUENCE"
        else
            echo "${GH_RUNLIST_JSON:-[]}"
        fi
        exit "${GH_RUNLIST_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"

# ─────────────────────────── Test 1: CONFLICTING ⇒ exit 3, no checks polled ─

heading "Test 1: CONFLICTING/DIRTY PR short-circuits before any checks poll"
rc=0
out="$(GH_VIEW_MERGEABLE=CONFLICTING GH_VIEW_STATE=DIRTY GH_CHECKS_RC=0 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 3 on CONFLICTING/DIRTY" '[ "$rc" -eq 3 ]'
check "message names the rebase-first remedy" 'grep -qi "rebase" <<<"$out"'

# ─────────────────────────── Test 2: mergeable + checks green ⇒ exit 0 ──────

heading "Test 2: mergeable PR, checks green → exit 0"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0 on green checks" '[ "$rc" -eq 0 ]'

# ─────────────────────────── Test 3: mergeable + checks failing ⇒ exit 1 ────

heading "Test 3: mergeable PR, checks failing → exit 1"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=1 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 1 on failing checks" '[ "$rc" -eq 1 ]'

# ─────────────────────────── Test 4: mergeable + checks pending ⇒ timeout ───

heading "Test 4: mergeable PR, checks pending past deadline → exit 2 (timeout)"
rc=0
start="$(date -u +%s)"
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=8 \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
elapsed=$(( $(date -u +%s) - start ))
check "exits 2 on timeout" '[ "$rc" -eq 2 ]'
check "message says timed out" 'grep -qi "timed out" <<<"$out"'
check "actually waited close to the deadline (not an instant false-positive)" '[ "$elapsed" -ge 2 ]'

# ─────────────────────────── Test 5: UNKNOWN mergeability retried once ──────

heading "Test 5: UNKNOWN mergeable on first read is retried, not treated as conflicting"
rc=0
COUNT_FILE="$TEST_DIR/gh-call-count"
rm -f "$COUNT_FILE"
out="$(GH_CALL_COUNT_FILE="$COUNT_FILE" GH_VIEW_UNKNOWN_FIRST=1 \
    GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "resolves to success once mergeability settles" '[ "$rc" -eq 0 ]'
check "pr view was called at least twice (initial + retry)" '[ "$(cat "$COUNT_FILE")" -ge 2 ]'

# ─────────────────────────── Test 6: usage error ─────────────────────────────

heading "Test 6: no PR# argument → usage error"
rc=0
"$CI_WAIT" >/dev/null 2>&1 || rc=$?
check "exits 4 with no arguments" '[ "$rc" -eq 4 ]'

# ─────────────── Test 7: zero workflows configured ⇒ exit 5 (distinct from a real failure) ─

heading "Test 7: mergeable PR, repo has ZERO workflows configured at all → exit 5"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=0 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 5, distinct from exit 1 (real failure)" '[ "$rc" -eq 5 ]'
check "message explains nothing ran, so nothing failed" 'grep -qi "no CI checks configured" <<<"$out"'

# ── Test 8: 'no checks reported' with workflows configured is a race, not absence ──
#
# Self-review finding on this PR: `gh pr checks` prints the exact same "no
# checks reported" text in the real, ordinary window after a push before
# GitHub has registered the workflow run — trusting that message alone
# would let --auto-low merge an unverified PR, the #713 failure mode this
# script exists to close. The repo-level workflow count (not the message
# text) is what decides absence; when workflows ARE configured, "no checks
# reported" must be treated as pending and keep polling until a real result
# — never silently exit 5.

heading "Test 8: 'no checks reported' with workflows configured is treated as pending, not absence (the run-not-registered-yet race)"
rc=0
CHECKS_COUNT_FILE="$TEST_DIR/checks-call-count"
rm -f "$CHECKS_COUNT_FILE"
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_WORKFLOW_COUNT=1 \
    GH_CHECKS_CALL_COUNT_FILE="$CHECKS_COUNT_FILE" GH_CHECKS_NO_CHECKS_UNTIL=2 \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 10 2>&1)" || rc=$?
check "resolves to green once the real check run registers (not a false exit 5)" '[ "$rc" -eq 0 ]'
check "message names the pending-not-absent distinction" 'grep -qi "treating as pending, not absent" <<<"$out"'
check "gh pr checks was actually polled more than once (the race was real)" '[ "$(cat "$CHECKS_COUNT_FILE")" -ge 3 ]'

# ── Test 9: fine-grained token can't read Checks → falls back to gh run list, green ──
#
# Issue #513: a fine-grained PAT has Actions:read but no Checks permission,
# so `gh pr checks` fails outright with "Resource not accessible by
# personal access token" instead of returning a real/pending/failed result.
# ci-wait.sh must recognize that exact text and switch to polling
# `gh run list --commit <sha>` for the rest of the run.

heading "Test 9: gh pr checks unreadable by a fine-grained token → falls back to gh run list, run green → exit 0"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0 once the fallback sees a green run" '[ "$rc" -eq 0 ]'
check "logs that the fallback was used" 'grep -qi "falling back to polling gh run list" <<<"$out"'

# ─────────── Test 10: fallback sees a failing run ⇒ exit 1 ──────────────────

heading "Test 10: fallback path, a run failed → exit 1"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success","workflowName":"Lint","createdAt":"2026-10-05T05:00:00Z"},{"status":"completed","conclusion":"failure","workflowName":"CI","createdAt":"2026-10-05T05:00:00Z"}]' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 1 when the fallback sees a failing run" '[ "$rc" -eq 1 ]'

# ── Test 10b: fallback, a run timed out (not "failure"/"cancelled") ⇒ still exit 1 ──
#
# Self-review finding on this PR: an earlier version only mapped
# failure/cancelled to "fail", leaving timed_out/action_required/
# startup_failure/stale stuck as "pending" until the deadline (exit 2
# instead of 1). A red PR must fail fast, not time out.

heading "Test 10b: fallback path, a run timed out → exit 1 (not a timeout-shaped exit 2)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"timed_out"}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 3 2>&1)" || rc=$?
check "exits 1 (fail), not 2 (timeout), on a timed_out run conclusion" '[ "$rc" -eq 1 ]'

# ── Test 10c: fallback, a skipped run alongside a successful one ⇒ still exit 0 ──

heading "Test 10c: fallback path, one run skipped + one succeeded → exit 0 (skipped doesn't block green)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success","workflowName":"CI","createdAt":"2026-10-05T05:00:00Z"},{"status":"completed","conclusion":"skipped","workflowName":"Docs","createdAt":"2026-10-05T05:00:00Z"}]' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0 when the only non-success run is skipped" '[ "$rc" -eq 0 ]'

# ── Test 10f: fallback dedupes by workflow — a superseded cancelled run must not fail a PR whose latest run is green ──
#
# Self-review finding, third round: `gh run list --commit` returns every
# run for a commit, including ones a newer run superseded (a re-run, or a
# concurrency group cancelling an older push-triggered run in favour of
# the pull_request one) — unlike `gh pr checks`, which already shows only
# the latest per check name. Without dedup, the leftover `cancelled` run
# would falsely fail a PR whose current run is green.

heading "Test 10f: fallback path, an older cancelled run of the same workflow is superseded by a newer green one → exit 0"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"cancelled","workflowName":"CI","createdAt":"2026-10-05T05:00:00Z"},{"status":"completed","conclusion":"success","workflowName":"CI","createdAt":"2026-10-05T05:05:00Z"}]' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0 — the superseded cancelled run of the same workflow is ignored" '[ "$rc" -eq 0 ]'

# ── Test 10d: fallback, gh's own stderr noise never corrupts the JSON parse ──
#
# Self-review finding, second round: stdout and stderr must be kept apart
# for `gh run list`, or a stray stderr line merged into stdout would fail
# the jq parse and (under `set -e`) leak jq's own exit code 5 out as this
# script's exit code — misread downstream as "no CI configured" instead of
# a real gh/parse error (exit 4).

heading "Test 10d: fallback path, gh emits noise on stderr → stdout JSON still parses clean, exit 0"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_STDERR_NOISE=1 GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0 — stderr noise never reached the JSON parse" '[ "$rc" -eq 0 ]'

# ── Test 10e: fallback, gh run list itself fails ⇒ exit 4, never 5 ───────────

heading "Test 10e: fallback path, gh run list fails outright → exit 4 (gh error), not 5"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_RC=1 "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 4 on a gh run list failure, never misread as exit 5" '[ "$rc" -eq 4 ]'

# ── Test 10g: fallback, gh run list returns valid JSON that isn't an array ⇒ exit 4, not a timeout ──
# #568 self-review caveat: `{}` passed the parse check, failed jq's group_by,
# and the function still returned 0 with an empty state, so ci-wait polled
# until its deadline instead of reporting the error.

heading "Test 10g: fallback path, gh run list returns non-array JSON → exit 4 (gh error), not a timeout"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='{}' "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 4 on non-array fallback JSON, never waits out the timeout (exit 2)" '[ "$rc" -eq 4 ]'
check "names the malformed fallback output" 'grep -qi "isn.t a list of runs" <<<"$out"'

# ─── Test 11: fallback path, pending then green — keeps polling run list, never re-tries gh pr checks ───

heading "Test 11: fallback path, runs pending then green; gh pr checks is called exactly once"
rc=0
CHECKS_COUNT_FILE_11="$TEST_DIR/checks-call-count-11"
RUNLIST_COUNT_FILE_11="$TEST_DIR/runlist-call-count-11"
RUNLIST_SEQ_11="$TEST_DIR/runlist-seq-11"
rm -f "$CHECKS_COUNT_FILE_11" "$RUNLIST_COUNT_FILE_11"
printf '%s\n' \
    '[{"status":"in_progress","conclusion":null}]' \
    '[{"status":"in_progress","conclusion":null}]' \
    '[{"status":"completed","conclusion":"success"}]' \
    > "$RUNLIST_SEQ_11"
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_CHECKS_CALL_COUNT_FILE="$CHECKS_COUNT_FILE_11" \
    GH_RUNLIST_CALL_COUNT_FILE="$RUNLIST_COUNT_FILE_11" GH_RUNLIST_JSON_SEQUENCE="$RUNLIST_SEQ_11" \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 10 2>&1)" || rc=$?
check "resolves to green once the run completes" '[ "$rc" -eq 0 ]'
check "gh run list was polled more than once" '[ "$(cat "$RUNLIST_COUNT_FILE_11")" -ge 3 ]'
check "gh pr checks was called exactly once (fallback engaged, no re-tries)" '[ "$(cat "$CHECKS_COUNT_FILE_11")" -eq 1 ]'

# ─── Test 12: --repo is accepted and forwarded to every gh call (issue #473 "also noticed") ───

heading "Test 12: --repo <owner/repo> is accepted and forwarded to pr view/checks"
rc=0
ARGS_LOG_12="$TEST_DIR/args-log-12"
: > "$ARGS_LOG_12"
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    GH_ARGS_LOG="$ARGS_LOG_12" "$CI_WAIT" 42 5 --repo owner/repo 2>&1)" || rc=$?
check "exits 0 with --repo after the positional args" '[ "$rc" -eq 0 ]'
check "pr view was called with --repo owner/repo" 'grep -q "^pr view 42 --repo owner/repo" "$ARGS_LOG_12"'
check "pr checks was called with --repo owner/repo" 'grep -q "^pr checks 42 --repo owner/repo" "$ARGS_LOG_12"'

heading "Test 12b: --repo=<owner/repo> (= form) is also accepted"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    "$CI_WAIT" --repo=owner/repo 42 5 2>&1)" || rc=$?
check "exits 0 with --repo=owner/repo before the positional args" '[ "$rc" -eq 0 ]'

heading "Test 12c: --repo changes the workflow-count lookup path (exit 5, zero workflows)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 \
    GH_WORKFLOW_COUNT=0 "$CI_WAIT" 42 5 --repo owner/repo 2>&1)" || rc=$?
check "exits 5 (no CI configured) with --repo set too" '[ "$rc" -eq 5 ]'

heading "Test 12d: no PR# at all, only --repo → usage error, not a crash"
rc=0
out="$("$CI_WAIT" --repo owner/repo 2>&1)" || rc=$?
check "exits 4 (usage) rather than crashing on an unbound variable" '[ "$rc" -eq 4 ]'

heading "Results: $PASS checks passed"
green "All checks passed."
