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
# issue #644 follow-up: `gh api` sends POST, not GET, whenever ANY -f/-F is
# given — proven live against real GitHub (a bare -f ref=... content fetch
# 404s; the same call with -X GET succeeds). Fail the stub the same way the
# real API would 404 it, so this proves the METHOD actually sent, not just
# that the right args were built.
if [ "$1" = "api" ] && printf '%s\n' "$*" | grep -qE -- '(^| )-[fF] ' && ! printf '%s\n' "$*" | grep -q -- '-X GET'; then
    echo '{"message":"Not Found","status":"404"}' >&2
    exit 1
fi
case "$1 $2" in
    "pr view")
        n=0
        if [ -f "${GH_CALL_COUNT_FILE:-/dev/null}" ]; then n="$(cat "$GH_CALL_COUNT_FILE")"; fi
        n=$((n + 1))
        [ -n "${GH_CALL_COUNT_FILE:-}" ] && echo "$n" > "$GH_CALL_COUNT_FILE"
        # issue #643 regression: a `gh` that exits 0 but still writes to
        # stderr (an update notice, a deprecation warning) must never
        # corrupt the JSON ci-wait.sh parses from stdout.
        if [ "${GH_VIEW_STDERR_NOISE:-0}" = "1" ]; then
            echo "warning: a new release of gh is available (simulated)" >&2
        fi
        # issue #643 regression: `gh` returning non-JSON on stdout (exit 0)
        # must fail closed as exit 4, never leak jq's own exit 5 as
        # ci-wait.sh's exit code (misread downstream as "no CI configured").
        if [ "${GH_VIEW_BAD_JSON:-0}" = "1" ]; then
            echo "not valid json {"
            exit 0
        fi
        if [[ "$*" == *"--json headRefOid"* ]] && [[ "$*" != *"mergeable"* ]]; then
            # issue #629 follow-up: ci-wait.sh's own per-poll-iteration
            # re-read (bare --json headRefOid, no mergeable/mergeStateStatus)
            # — distinct from the initial triple-field call below.
            # GH_VIEW_HEADSHA_MIDWAIT lets a test simulate a push landing
            # mid-wait; defaults to GH_VIEW_HEADSHA so every pre-existing
            # test (none of which sets this var) sees the same head
            # throughout, unaffected.
            mn=0
            if [ -f "${GH_MIDWAIT_CALL_COUNT_FILE:-/dev/null}" ]; then mn="$(cat "$GH_MIDWAIT_CALL_COUNT_FILE")"; fi
            mn=$((mn + 1))
            [ -n "${GH_MIDWAIT_CALL_COUNT_FILE:-}" ] && echo "$mn" > "$GH_MIDWAIT_CALL_COUNT_FILE"
            # issue #643 follow-up: GH_VIEW_MIDWAIT_FAIL_UNTIL=<n> makes this
            # bare per-poll read fail for its first n calls (a transient
            # `gh pr view` error), then succeed from call n+1 on — so a test
            # can prove a single transient failure gets retried rather than
            # ending the wait.
            if [ -n "${GH_VIEW_MIDWAIT_FAIL_UNTIL:-}" ] && [ "$mn" -le "$GH_VIEW_MIDWAIT_FAIL_UNTIL" ]; then
                echo "GraphQL: transient error (simulated)" >&2
                exit 1
            fi
            echo "{\"headRefOid\":\"${GH_VIEW_HEADSHA_MIDWAIT:-${GH_VIEW_HEADSHA:-deadbeef}}\"}"
            exit 0
        fi
        if [[ "$*" == *"--json isDraft"* ]]; then echo "${GH_VIEW_ISDRAFT:-false}"; exit 0; fi
        if [ "$n" = "1" ] && [ "${GH_VIEW_UNKNOWN_FIRST:-0}" = "1" ]; then
            echo "{\"mergeable\":\"UNKNOWN\",\"mergeStateStatus\":\"UNKNOWN\",\"headRefOid\":\"${GH_VIEW_HEADSHA_STALE:-deadbeef}\"}"
        else
            echo "{\"mergeable\":\"${GH_VIEW_MERGEABLE:-MERGEABLE}\",\"mergeStateStatus\":\"${GH_VIEW_STATE:-CLEAN}\",\"headRefOid\":\"${GH_VIEW_HEADSHA:-deadbeef}\"}"
        fi
        exit 0 ;;
    "pr checks")
        cn=0
        if [ -f "${GH_CHECKS_CALL_COUNT_FILE:-/dev/null}" ]; then cn="$(cat "$GH_CHECKS_CALL_COUNT_FILE")"; fi
        cn=$((cn + 1))
        [ -n "${GH_CHECKS_CALL_COUNT_FILE:-}" ] && echo "$cn" > "$GH_CHECKS_CALL_COUNT_FILE"
        if [ -n "${GH_CHECKS_OUT:-}" ]; then printf '%b\n' "$GH_CHECKS_OUT"; fi
        if [ "${GH_CHECKS_PERM_ERROR:-0}" = "1" ]; then
            echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.contexts.nodes)" >&2
            exit 1
        fi
        if [ "$cn" -le "${GH_CHECKS_NO_CHECKS_UNTIL:-0}" ] || [ "${GH_CHECKS_NO_CHECKS:-0}" = "1" ]; then
            echo "no checks reported on the 'main' branch" >&2
            exit 1
        fi
        exit "${GH_CHECKS_RC:-0}" ;;
    "api --paginate")
        # issue #639: ci_fallback_workflows_relevant_to_pr's own changed-
        # files lookup (REST, --paginate — gh pr view --json files truncates
        # at 100, cli/cli#5366). GH_PR_FILES_JSON is usually the flat
        # ["path", ...] shape (a plain string element is one changed file
        # with no rename), normalized below into the real API's per-file
        # object shape; an element already given as an object (issue #644
        # round-5) is {"filename":"new/path","previous_filename":"old/path"},
        # a real GitHub rename entry. Unlike a hard-coded stand-in filter,
        # this extracts and runs THE SCRIPT'S OWN --jq expression against
        # that normalized fixture, so a regression that drops
        # previous_filename from the real query is actually caught here
        # rather than only in this stub's separate emulation of it.
        jq_expr=""
        prev_arg=""
        for a in "$@"; do
            [ "$prev_arg" = "--jq" ] && jq_expr="$a"
            prev_arg="$a"
        done
        printf '%s' "${GH_PR_FILES_JSON:-[]}" \
            | jq '[.[] | if type == "object" then . else {filename: .} end]' \
            | jq -r "$jq_expr"
        exit 0 ;;
    "api repos/{owner}/{repo}/pulls/"*|"api repos/owner/repo/pulls/"*)
        # issue #644 final round + round-4: ci_fallback_workflows_relevant_to_pr's
        # lookup of the PR's OWN base AND head branch (gh api .../pulls/<pr>
        # --jq '[.base.ref, .head.ref] | @tsv') — base, to fetch each workflow
        # file at that ref instead of the repo default branch; head, to
        # evaluate a push trigger's branches/branches-ignore filter.
        printf '%s\t%s\n' "${GH_PR_BASE_REF:-main}" "${GH_PR_HEAD_REF:-feature/change}"
        exit 0 ;;
    "api repos/{owner}/{repo}/actions/workflows"|"api repos/owner/repo/actions/workflows")
        if printf '%s\n' "$*" | grep -q -- '.total_count'; then
            echo "${GH_WORKFLOW_COUNT:-1}"
        else
            # issue #639: ci_fallback_workflows_relevant_to_pr's own lookup
            # of active workflow paths — same endpoint, a different --jq.
            echo "${GH_WORKFLOW_PATHS_JSON:-[]}"
        fi
        exit 0 ;;
    "api -H")
        # issue #639: ci_fallback_workflows_relevant_to_pr fetching a single
        # workflow file's raw YAML (gh api -H "Accept: ..." .../contents/<path>
        # -f ref=<base-branch>). issue #644 final round: serve a DIFFERENT
        # YAML when the requested ref matches the PR's actual base branch, so
        # a test can prove the right ref was sent instead of just ignoring it.
        if [ -n "${GH_PR_BASE_REF:-}" ] && printf '%s\n' "$*" | grep -qF -- "ref=${GH_PR_BASE_REF}"; then
            printf '%s' "${GH_WORKFLOW_YAML_FOR_BASE_REF:-${GH_WORKFLOW_YAML:-}}"
        else
            printf '%s' "${GH_WORKFLOW_YAML:-}"
        fi
        exit 0 ;;
    "run list")
        rn=0
        if [ -f "${GH_RUNLIST_CALL_COUNT_FILE:-/dev/null}" ]; then rn="$(cat "$GH_RUNLIST_CALL_COUNT_FILE")"; fi
        rn=$((rn + 1))
        [ -n "${GH_RUNLIST_CALL_COUNT_FILE:-}" ] && echo "$rn" > "$GH_RUNLIST_CALL_COUNT_FILE"
        if [ "${GH_RUNLIST_STDERR_NOISE:-0}" = "1" ]; then
            echo "warning: some deprecation notice from gh itself" >&2
        fi
        # issue #629 regression (Test 16): respond differently depending on
        # which --commit SHA was actually requested, so a test can prove
        # ci-wait queried the FRESH head and not a stale one left over from
        # before the mergeability retry.
        reqsha=""; prevarg=""
        for a in "$@"; do
            [ "$prevarg" = "--commit" ] && reqsha="$a"
            prevarg="$a"
        done
        if [ -n "${GH_RUNLIST_SHA_A:-}" ] && [ "$reqsha" = "$GH_RUNLIST_SHA_A" ]; then
            echo "${GH_RUNLIST_JSON_A}"
            exit "${GH_RUNLIST_RC:-0}"
        fi
        if [ -n "${GH_RUNLIST_SHA_B:-}" ] && [ "$reqsha" = "$GH_RUNLIST_SHA_B" ]; then
            echo "${GH_RUNLIST_JSON_B}"
            exit "${GH_RUNLIST_RC:-0}"
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

heading "Test 2: mergeable PR, checks green and the run-level cross-check agrees → exit 0"
rc=0
# GH_RUNLIST_JSON here and below (wherever GH_CHECKS_RC=0 is expected to
# resolve to a pass): issue #596's run-level cross-check (ci_fallback_run_state,
# exercised on its own with a late-finishing run in Test 13) now runs on
# every green `gh pr checks` reading too, so these tests must give it a
# matching completed/success run or the cross-check reads the stub's
# default empty run list as "pending" and the test times out instead of
# passing.
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
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
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
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
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 10 2>&1)" || rc=$?
check "resolves to green once the real check run registers (not a false exit 5)" '[ "$rc" -eq 0 ]'
check "message names the pending-not-absent distinction" 'grep -qi "treating as pending, not absent" <<<"$out"'
check "gh pr checks was actually polled more than once (the race was real)" '[ "$(cat "$CHECKS_COUNT_FILE")" -ge 3 ]'

# ── Test 8b/8c/8d: issue #639 — "no checks reported" with workflows configured, but none apply to THESE changed files ──
#
# civicstrata#602/#603 (2026-10-15): a docs-only PR in a repo whose CI
# `paths-ignore`s docs never gets a run at all — not a race, a permanent
# fact about the commit. ci_fallback_workflows_relevant_to_pr checks the
# actual path filters; only its confident "no" should short-circuit the
# pending wait into exit 5 (same as zero workflows configured).

heading "Test 8b: a docs-only PR excluded by the one workflow's paths-ignore → exit 5, not an unbounded wait"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["docs/foo.md","README.md"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 5 — no run will ever register for an all-ignored changed-file set" '[ "$rc" -eq 5 ]'
check "message names the path-filter exclusion" 'grep -qi "excluded by every pull_request/push workflow" <<<"$out"'

heading "Test 8c: changed files touch a NON-ignored path too → treated as the ordinary pending race, not absence"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["docs/foo.md","src/main.py"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5, once a changed file falls outside paths-ignore" '[ "$rc" -eq 2 ]'

heading "Test 8d: the one workflow has NO path filter at all → still treated as pending (always applies)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["docs/foo.md"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n  push:\n    branches: [master]\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5, when the workflow has no path filter" '[ "$rc" -eq 2 ]'

# issue #644 round-3 self-review: GitHub runs a pull_request event's
# workflow YAML from the PR's merge commit, not the base branch, so a PR
# that itself edits a workflow file (here: removes the paths-ignore that
# would otherwise exclude its own docs change) can get a real run the
# base-branch YAML this helper reads says will never happen — the fail-open
# direction the whole helper exists to avoid.
heading "Test 8e: a docs-only PR that ALSO edits a workflow file → never path-filtered, even though the (untrusted) base-branch YAML would exclude it"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["docs/foo.md",".github/workflows/build.yml"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n      - \x27.github/workflows/**\x27\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5, when the PR itself touches .github/workflows/" '[ "$rc" -eq 2 ]'

# issue #644 third follow-up: a same-repo PR's branch push fires a
# push-only workflow too, and that run lands on the exact head SHA
# `gh pr checks` reads — a bare `on: push` with no path filter at all must
# never be read as no-trigger/excluded (the fail-open the independent
# review caught: _ci-fallback.sh used to fold no-trigger into the same
# bucket as excluded).
heading "Test 8f: a push-only workflow with NO path filter, a source-file change → exit 2 (pending), never 5"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["src/main.py"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_WORKFLOW_YAML=$'on:\n  push:\n    branches: [main]\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5, when a push-only workflow has no path filter at all" '[ "$rc" -eq 2 ]'

# issue #644 round-4 (coordinator review): GitHub evaluates a push trigger's
# paths-ignore against THAT PUSH'S OWN diff, not pulls/<pr>/files — a
# docs-only PR branch can later merge master in and carry source files on
# its next push, so reading this filter at all risked a false "excluded"
# (exit 5) for a push that will actually run for real. Fixed: a push
# trigger's path filter is never read, in either direction — only its
# branch filter is, so this push-only workflow (branch filter matches the
# PR's own head branch) must still be waited on.
heading "Test 8g: a push-only workflow whose branch filter matches this head branch, paths-ignore covers an all-docs changed-file set → exit 2 (pending), never 5"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["docs/foo.md","README.md"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_PR_HEAD_REF='main' \
    GH_WORKFLOW_YAML=$'on:\n  push:\n    branches: [main]\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5 — a push trigger's own paths-ignore is never evaluated, only its branch filter" '[ "$rc" -eq 2 ]'

heading "Test 8i: push trigger's branches-ignore matches this PR's own head branch → legitimate no-trigger, but ALONE still exit 2 (not proof of exclusion by itself)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["src/main.py"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_PR_HEAD_REF='release/2.0' \
    GH_WORKFLOW_YAML=$'on:\n  push:\n    branches-ignore:\n      - \x27release/*\x27\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending) — a lone push trigger ruled out by its own branch filter is not, by itself, confident evidence that no CI will ever register" '[ "$rc" -eq 2 ]'

heading "Test 8j: civicstrata's real build.yml fixture — pull_request + push both paths-ignore docs/md, docs-only PR from fix/issue-N (not master) → exit 5"
# The coordinator's real-world check (issue #644 round-4 point 2): push's
# branches: [master] doesn't match this PR's head branch (legitimate
# no-trigger), and pull_request's own paths-ignore confidently excludes
# every changed file — together, still a confident "no CI will ever
# register", same as before this round's fix.
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["docs/foo.md","README.md"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_PR_HEAD_REF='fix/issue-639' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore: [\x27**.md\x27, \x27docs/**\x27]\n  push:\n    branches: [master]\n    paths-ignore: [\x27**.md\x27, \x27docs/**\x27]\n' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 5 — a docs-only PR from a non-master branch is still confidently excluded, matching civicstrata's real workflow" '[ "$rc" -eq 5 ]'

# ── Test 8h: issue #644 final round — the PR's OWN base branch's workflow copy is read, not the repo default ──
#
# A workflow's path filters can differ by target branch. Before this fix,
# ci_fallback_workflows_relevant_to_pr always fetched the DEFAULT branch's
# copy of each workflow file — a PR opened against a different base branch
# with different filters got evaluated against the wrong ones, and could
# come out "excluded" (exit 5, no wait) even though its real base branch
# would run CI for real.

heading "Test 8h: PR targets a non-default base branch whose own workflow copy has NO paths-ignore → exit 2 (pending), never 5, even though the default branch's copy ignores docs"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["docs/foo.md","README.md"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_PR_BASE_REF='release/2.0' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n' \
    GH_WORKFLOW_YAML_FOR_BASE_REF=$'on:\n  pull_request:\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5 — the PR's actual base branch has no path filter at all" '[ "$rc" -eq 2 ]'

# issue #644 round-5 (coordinator review): the REST files endpoint reports a
# rename as one entry whose NEW path is docs/Foo.kt and whose OLD path
# (previous_filename) was src/Foo.kt. Only the new path is under the
# paths-ignore filter below — if the old path were never added to the
# changed-file set, this would misread as docs-only and exit 5 even though
# it's a real source-file move.
heading "Test 8k: a PR's ONLY change is a rename from a non-ignored path into docs/ → exit 2 (pending), never 5"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='[{"filename":"docs/Foo.kt","previous_filename":"src/Foo.kt"}]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n      - \x27**.md\x27\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5 — a rename's OLD path (src/Foo.kt) falls outside paths-ignore" '[ "$rc" -eq 2 ]'

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
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
    GH_ARGS_LOG="$ARGS_LOG_12" "$CI_WAIT" 42 5 --repo owner/repo 2>&1)" || rc=$?
check "exits 0 with --repo after the positional args" '[ "$rc" -eq 0 ]'
check "pr view was called with --repo owner/repo" 'grep -q "^pr view 42 --repo owner/repo" "$ARGS_LOG_12"'
check "pr checks was called with --repo owner/repo" 'grep -q "^pr checks 42 --repo owner/repo" "$ARGS_LOG_12"'

heading "Test 12b: --repo=<owner/repo> (= form) is also accepted"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
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

heading "Test 12e: ci_fallback_workflows_relevant_to_pr's own repo_args also recognizes -R, not just --repo (issue #644 round-4, minor)"
# ci-wait.sh itself only ever builds its REPO_ARGS as (--repo "$REPO"), so
# this exercises the shared helper directly, standing in for a caller that
# passes repo_args the way gh itself accepts them (-R is gh's own shorthand
# for --repo). Checked against the ACTUAL gh invocation, not just the final
# verdict: the stub's case statement accepts both "repos/{owner}/{repo}"
# (the unrecognized-flag default) and "repos/owner/repo" (the real -R
# value) as equally valid paths, so only the logged args can tell apart "-R
# was parsed" from "-R was silently ignored".
ARGS_LOG_12E="$TEST_DIR/args-12e.log"
: > "$ARGS_LOG_12E"
(
    # shellcheck source=../scripts/_ci-fallback.sh
    . "$SCRIPT_DIR/../scripts/_ci-fallback.sh"
    GH_ARGS_LOG="$ARGS_LOG_12E" GH_WORKFLOW_COUNT=1 GH_PR_FILES_JSON='["docs/foo.md"]' \
        GH_WORKFLOW_PATHS_JSON='[".github/workflows/build.yml"]' \
        GH_PR_BASE_REF=main GH_PR_HEAD_REF=feature/change \
        GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    paths-ignore:\n      - \x27docs/**\x27\n' \
        ci_fallback_workflows_relevant_to_pr 42 -R owner/repo
    echo "$CI_FALLBACK_RELEVANT" > "$TEST_DIR/dash-r.out"
)
check "a -R repo_args entry is recognized the same as --repo (confidently excluded via the owner/repo path)" '[ "$(cat "$TEST_DIR/dash-r.out")" = "no" ]'
check "the actual gh api calls used the -R-supplied repo path (repos/owner/repo), not the unrecognized-flag default" 'grep -q "repos/owner/repo" "$ARGS_LOG_12E"'

# ── Test 13: the corpusminder-spring #1126 shape — gh pr checks reads green while the run itself is still in progress ──
#
# Issue #596's real incident, reproduced from PR #1126/run 37944084110's
# actual timestamps: `gh pr checks` sees only the Fast job (green) and
# reports exit 0 the whole time, because the `needs:`-gated Integration
# job's check-run hadn't even been created yet (self-hosted runner
# contention, corpusminder-spring's ci.yml). The run-level cross-check
# (`gh run list --commit`, status "in_progress" — exactly what run
# 37944084110 showed at the real 14:32:02 merge time) must NOT let that
# green `gh pr checks` reading through until the run itself is done.

heading "Test 13: non-fallback path, gh pr checks reads green while the run-level cross-check is still in_progress → waited for, not an instant pass"
rc=0
RUNLIST_SEQ_13="$TEST_DIR/runlist-seq-13"
RUNLIST_COUNT_FILE_13="$TEST_DIR/runlist-call-count-13"
rm -f "$RUNLIST_COUNT_FILE_13"
printf '%s\n' \
    '[{"status":"in_progress","conclusion":null,"workflowName":"CI","createdAt":"2026-10-09T14:25:00Z"}]' \
    '[{"status":"in_progress","conclusion":null,"workflowName":"CI","createdAt":"2026-10-09T14:25:00Z"}]' \
    '[{"status":"completed","conclusion":"success","workflowName":"CI","createdAt":"2026-10-09T14:25:00Z"}]' \
    > "$RUNLIST_SEQ_13"
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    GH_RUNLIST_CALL_COUNT_FILE="$RUNLIST_COUNT_FILE_13" GH_RUNLIST_JSON_SEQUENCE="$RUNLIST_SEQ_13" \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 10 2>&1)" || rc=$?
check "resolves to green only once the run-level cross-check also says done" '[ "$rc" -eq 0 ]'
check "message named the run still in progress before it resolved" 'grep -qi "still in progress" <<<"$out"'

# ── Test 14: the cross-check contradicts a green gh pr checks reading with a real failure → exit 1, not a timeout ──

heading "Test 14: non-fallback path, gh pr checks reads green but the run-level cross-check shows a completed failure → exit 1"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"failure","workflowName":"CI","createdAt":"2026-10-09T14:25:00Z"}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 10 2>&1)" || rc=$?
check "exits 1 (fail), not 2 (timeout), when the cross-check contradicts a green reading" '[ "$rc" -eq 1 ]'

# ── Test 15: the cross-check call itself can't be read → never trusts a bare green reading, refuses rather than merging on it ──

heading "Test 15: non-fallback path, the run-level cross-check call itself fails → times out (refuses), never a false pass"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 GH_RUNLIST_RC=1 \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/refuse), never a false pass, when the cross-check itself can't be read" '[ "$rc" -eq 2 ]'
check "message says it isn't trusting a bare green reading" 'grep -qi "not trusting a bare green reading" <<<"$out"'

# ── Test 16: issue #629 — headRefOid read before the mergeability retry must not freeze SHA on a stale, already-green commit ──
#
# corpusminder-spring PR #1280's real shape: `gh pr view` first reads back
# UNKNOWN mergeable (GitHub still catching up to a just-landed push) — the
# same moment headRefOid is also likeliest to still report the PREVIOUS
# commit, not the new one. Before this fix, SHA was captured from that
# FIRST (stale) response and never refreshed from the retry's. Here the
# stale SHA ("oldsha", a commit that already has a fully green completed
# run) and the real new SHA ("newsha", still in_progress) deliberately
# resolve to opposite verdicts in gh run list, so a leftover stale SHA
# shows up as an instant false pass instead of the correct wait.

heading "Test 16: a stale headRefOid read before the mergeability retry must not freeze the cross-check on the OLD, already-green commit"
rc=0
COUNT_FILE_16="$TEST_DIR/gh-call-count-16"
rm -f "$COUNT_FILE_16"
out="$(GH_CALL_COUNT_FILE="$COUNT_FILE_16" GH_VIEW_UNKNOWN_FIRST=1 GH_VIEW_HEADSHA_STALE=oldsha GH_VIEW_HEADSHA=newsha \
    GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    GH_RUNLIST_SHA_A=oldsha GH_RUNLIST_JSON_A='[{"status":"completed","conclusion":"success"}]' \
    GH_RUNLIST_SHA_B=newsha GH_RUNLIST_JSON_B='[{"status":"in_progress","conclusion":null}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "never exits 0 on the stale commit's old green run (times out/refuses instead)" '[ "$rc" -ne 0 ]'
check "exits 2 (timeout), correctly still pending on the real new head" '[ "$rc" -eq 2 ]'

# ── Test 17: acceptance criterion — one in-progress run plus a cancelled sibling run of the SAME workflow must never read as pass ──
#
# The corpusminder-spring #1280 shape distilled to the exact run-level data:
# a concurrency-cancelled sibling run and the in-progress run that
# superseded it, both for the same workflow and commit. Must stay pending
# (keep polling) however gh orders the two in its response — this locks in
# both the ordinary non-tied case and the equal-createdAt tie-break fix.

heading "Test 17: one in-progress run plus a cancelled sibling run of the same workflow → stays pending, never a pass"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"in_progress","conclusion":null,"workflowName":"CI","createdAt":"2026-10-13T05:29:22Z"},{"status":"completed","conclusion":"cancelled","workflowName":"CI","createdAt":"2026-10-13T05:28:46Z"}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout) — never a false pass from the cancelled sibling" '[ "$rc" -eq 2 ]'

heading "Test 17b: same shape, but gh returns the two runs with equal createdAt (a real tie), in-progress listed FIRST → still stays pending, not the fail a plain last-wins tie-break would give"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"in_progress","conclusion":null,"workflowName":"CI","createdAt":"2026-10-13T05:29:22Z"},{"status":"completed","conclusion":"cancelled","workflowName":"CI","createdAt":"2026-10-13T05:29:22Z"}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout), not 1 (fail) — the tie never lets the cancelled sibling win" '[ "$rc" -eq 2 ]'

heading "Test 17c: same tie, cancelled run listed FIRST instead → also stays pending (order-independent)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_PERM_ERROR=1 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"cancelled","workflowName":"CI","createdAt":"2026-10-13T05:29:22Z"},{"status":"in_progress","conclusion":null,"workflowName":"CI","createdAt":"2026-10-13T05:29:22Z"}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout) with the reverse array order too" '[ "$rc" -eq 2 ]'

# ── Test 18: coordinator follow-up — a push landing MID-POLL (no mergeability retry involved) must not pass on the OLD commit's already-green CI ──
#
# Distinct from Test 16: Test 16 covers the pre-loop mergeability-UNKNOWN
# retry. Here mergeability is normal from the very first read (no retry
# fires at all) — the only thing that can catch the moved head is the new
# per-poll-iteration headRefOid re-read inside the loop body itself. The old
# commit ("oldsha") already has a fully green completed run; the real,
# current commit ("newsha") is still in_progress. Before this fix, SHA was
# captured once before the loop and never refreshed, so the cross-check
# would keep querying oldsha and pass instantly on its stale green run.

heading "Test 18: a push mid-poll (no mergeability retry) must not pass on the old commit's already-green CI"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_VIEW_HEADSHA=oldsha GH_VIEW_HEADSHA_MIDWAIT=newsha \
    GH_CHECKS_RC=0 \
    GH_RUNLIST_SHA_A=oldsha GH_RUNLIST_JSON_A='[{"status":"completed","conclusion":"success"}]' \
    GH_RUNLIST_SHA_B=newsha GH_RUNLIST_JSON_B='[{"status":"in_progress","conclusion":null}]' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "never exits 0 on the old commit's stale green run (times out/refuses instead)" '[ "$rc" -ne 0 ]'
check "exits 2 (timeout), correctly still pending on the real, current head" '[ "$rc" -eq 2 ]'
check "message logs the head move detected mid-wait" 'grep -qi "head moved" <<<"$out"'

# ── Test 19: issue #643 — one transient per-poll `gh pr view` failure must be retried once, not end the wait ──
#
# The bare --json headRefOid read at the top of the poll loop fails exactly
# ONCE (a simulated rate-limit/network blip), then succeeds on every call
# after. Before this fix, ci-wait.sh exited 4 on the very first failure;
# now it must retry once and carry on to a normal green pass, never
# surfacing the transient error as a hard refusal.

heading "Test 19: a single transient per-poll gh pr view failure is retried, not treated as exit 4"
rc=0
MIDWAIT_COUNT_FILE_19="$TEST_DIR/gh-midwait-call-count-19"
rm -f "$MIDWAIT_COUNT_FILE_19"
out="$(GH_MIDWAIT_CALL_COUNT_FILE="$MIDWAIT_COUNT_FILE_19" GH_VIEW_MIDWAIT_FAIL_UNTIL=1 \
    GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
    "$CI_WAIT" 42 10 2>&1)" || rc=$?
check "survives the transient failure and still passes (exit 0), never exit 4" '[ "$rc" -eq 0 ]'
check "message logs the retry, not a hard refusal" 'grep -qi "retrying once" <<<"$out"'
check "does not report gh pr view failing twice in a row" '! grep -qi "failed twice in a row" <<<"$out"'

# ── Test 20: issue #643 — a stray stderr line from `gh pr view` (exit 0) must never corrupt the JSON parse ──
#
# PR #643's coordinator review (BLOCK on c51b8f6): `gh pr view`'s JSON reads
# captured stdout+stderr into the same variable (`2>&1`). An exit-0 call
# that still writes a warning/notice to stderr left that variable holding
# JSON-plus-noise, which `jq -r` then failed to parse with jq's OWN exit
# code 5 — and `set -e` turned that into ci-wait.sh's exit 5, misread by
# swarm-merge.sh's Gate 2 as "no CI configured", merging an unverified
# commit. Confirmed failing against c51b8f6 (exit 5) before this fix.

heading "Test 20: gh pr view exits 0 but writes noise to stderr → stdout JSON still parses clean, exit 0"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_VIEW_STDERR_NOISE=1 GH_CHECKS_RC=0 \
    GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0 — gh pr view's stderr noise never reached the JSON parse" '[ "$rc" -eq 0 ]'

# ── Test 21: issue #643 — gh pr view returning non-JSON on stdout must fail closed as exit 4, never exit 5 ──

heading "Test 21: gh pr view returns non-JSON on stdout (exit 0) → exit 4 (unparseable), never 5 (misread as no-CI)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_VIEW_BAD_JSON=1 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 4 on unparseable gh pr view output, never misread as exit 5" '[ "$rc" -eq 4 ]'
check "message names the unparseable output" 'grep -qi "unparseable" <<<"$out"'

# ── Test 22: issue #670 — stacked PR whose base branch every pull_request workflow's branches filter excludes ──
#
# fand-etl PR #1839 (2026-10-30): stacked on another PR's branch, workflow
# filtered to `branches: [master]` → zero runs, ever. Used to read as pending
# until timeout (ci-wait) / exit 4 "likely hasn't registered yet" (pr-ready).

heading "Test 22: stacked PR, base branch excluded by pull_request branches filter → exit 5 naming the base-branch cause"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["src/main.py"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/ci.yml"]' \
    GH_PR_BASE_REF='fix/issue-1823' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    branches: [master]\n' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 5 — no run will ever register for this base branch" '[ "$rc" -eq 5 ]'
check "message says the base branch is excluded" 'grep -qi "base branch excluded" <<<"$out"'
check "message names the fix (retarget)" 'grep -qi "retarget" <<<"$out"'

heading "Test 22b: same workflow, PR based on master → still the ordinary pending race (exit 2)"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_NO_CHECKS=1 GH_WORKFLOW_COUNT=1 \
    GH_PR_FILES_JSON='["src/main.py"]' \
    GH_WORKFLOW_PATHS_JSON='[".github/workflows/ci.yml"]' \
    GH_PR_BASE_REF='master' \
    GH_WORKFLOW_YAML=$'on:\n  pull_request:\n    branches: [master]\n' \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
check "exits 2 (timeout/pending), never 5 — the base branch is allowed" '[ "$rc" -eq 2 ]'

heading "Test 23: issue #617 — draft PR with a skipping check warns"
rc=0
out="$(GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' GH_VIEW_ISDRAFT=true GH_CHECKS_OUT='Fast\tpass\t1m\turl\nIntegration\tskipping\t0\turl' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "still exits 0" '[ "$rc" -eq 0 ]'
check "warns that a skipped check is not a pass" 'grep -q "WARNING.*draft.*skipping" <<<"$out"'

heading "Test 23b: non-draft PR with a skipping check → no warning"
rc=0
out="$(GH_RUNLIST_JSON='[{"status":"completed","conclusion":"success"}]' GH_VIEW_ISDRAFT=false GH_CHECKS_OUT='Fast\tpass\t1m\turl\nIntegration\tskipping\t0\turl' \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0" '[ "$rc" -eq 0 ]'
check "no warning" '! grep -q WARNING <<<"$out"'

heading "Results: $PASS checks passed"
green "All checks passed."
