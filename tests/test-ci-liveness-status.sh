#!/usr/bin/env bash
#
# test-ci-liveness-status.sh — issue #536 / PR #919: the `swarm/worker`
# liveness commit status must never read as CI state. Runs the REAL jq
# filters in scripts/_ci-fallback.sh over fixture `gh pr checks --json` and
# statusCheckRollup payloads (gh is a shell function that only serves the
# fixture), and checks that swarm-merge.sh reads CI only through ci-wait.sh.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
# shellcheck source=../scripts/_ci-fallback.sh
. "$SCRIPTS/_ci-fallback.sh"

GH_JSON=""; GH_RC=0; GH_ERR=""
gh() {
    case "$1 $2" in
        "pr checks") [ -z "$GH_ERR" ] || printf '%s\n' "$GH_ERR" >&2
                     [ -z "$GH_JSON" ] || printf '%s\n' "$GH_JSON"; return "$GH_RC" ;;
        "pr view")   printf '%s\n' "$GH_JSON"; return 0 ;;
        *) return 1 ;;
    esac
}

# run_checks <json> <gh rc>: sets CHECKS_OUT / CHECKS_RC via the real helper.
run_checks() { GH_JSON="$1"; GH_RC="$2"; ci_pr_checks 7 --repo o/r; }
expect() { # <desc> <want rc>
    [ "$CHECKS_RC" = "$2" ] || red "$1: want rc $2, got $CHECKS_RC (out: $CHECKS_OUT)"
    green "$1"
}

LINT_PASS='{"name":"lint","bucket":"pass","link":"u1"}'
for state in pending fail; do
    live="{\"name\":\"swarm/worker\",\"bucket\":\"$state\",\"link\":\"\"}"
    # gh itself exits 8 (pending) / 1 (fail) because of the liveness row.
    [ "$state" = pending ] && grc=8 || grc=1
    run_checks "[$LINT_PASS,$live]" "$grc"
    expect "green lint + liveness $state reads green (rc 0), not CI $state" 0
    grep -q 'swarm/worker' <<<"$CHECKS_OUT" && red "liveness row leaked into CHECKS_OUT"
    ci_checks_output_has_bad_row "$CHECKS_OUT" && red "liveness $state row read as a bad row"
done

run_checks '[{"name":"lint","bucket":"fail","link":"u"},{"name":"swarm/worker","bucket":"pending","link":""}]' 1
expect "a real failing check still reads red" 1
run_checks '[{"name":"lint","bucket":"pending","link":"u"},{"name":"swarm/worker","bucket":"fail","link":""}]' 1
expect "a real pending check still reads pending" 8
run_checks '[{"name":"lint","bucket":"cancel","link":"u"},{"name":"swarm/worker","bucket":"pass","link":""}]' 0
ci_checks_output_has_bad_row "$CHECKS_OUT" || red "a cancel row must stay visible to the #793 bad-row check"
green "a cancelled check still shows as a bad row (issue #793 path intact)"

run_checks '[{"name":"swarm/worker","bucket":"pending","link":""}]' 8
expect "liveness status alone reads as no CI reported (rc 1)" 1
grep -qi 'no checks reported' <<<"$CHECKS_OUT" || red "expected the no-checks-reported wording, got: $CHECKS_OUT"
green "liveness-only commit takes the callers' existing 'no checks reported' path"

run_checks "no checks reported on the 'main' branch" 1
expect "non-JSON gh output passes through with gh's rc" 1
grep -q "no checks reported on the 'main'" <<<"$CHECKS_OUT" || red "non-JSON output was rewritten"
run_checks "GraphQL: Resource not accessible by personal access token" 1
ci_fallback_is_token_error "$CHECKS_OUT" || red "token-permission error no longer recognisable"
green "gh errors (token permission, no checks) pass through untouched"

# #919 merge gate: a gh stderr warning next to a JSON array holding a failing
# check must read red (rc 1), never green; gh --json itself exits 0 here.
GH_ERR="warning: a new gh release is available"
run_checks "[$LINT_PASS,{\"name\":\"unit\",\"bucket\":\"fail\",\"link\":\"u2\"}]" 0
expect "stderr warning next to a failing check still reads red" 1
run_checks "[$LINT_PASS,{\"name\":\"unit\",\"bucket\":\"pending\",\"link\":\"u2\"}]" 0
expect "stderr warning next to a pending check still reads pending" 8
# Non-array stdout with gh rc 0 is unreadable: non-zero, never green.
run_checks "" 0
[ "$CHECKS_RC" != 0 ] || red "empty gh output with rc 0 read green"
green "gh rc 0 with no JSON array is unreadable, not green"
# An older gh that rejects --json: unreadable (rc 2), not red (rc 1).
GH_ERR="unknown flag: --json"
run_checks "" 1
expect "gh without --json reads unreadable (rc 2), not red" 2
GH_ERR=""

# statusCheckRollup readers: CheckRun (.name) and StatusContext (.context).
ROLLUP='{"statusCheckRollup":[
  {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"CANCELLED"},
  {"__typename":"StatusContext","context":"swarm/worker","state":"FAILURE"}]}'
GH_JSON="$ROLLUP"
ci_rollup_cancelled_only 7 || red "cancelled-only rollup misread because of the liveness FAILURE"
green "ci_rollup_cancelled_only ignores a failed liveness status"

out="$(jq -r "$CI_ROLLUP_DROP_LIVENESS_JQ"'.statusCheckRollup | ci_real | map(.context // .name) | join(",")' <<<"$ROLLUP")"
[ "$out" = "lint" ] || red "ci_real kept: $out"
green "ci_real rollup def keeps only the real check"

# swarm-merge.sh has no CI reader of its own: its CI gate is ci-wait.sh, which
# goes through ci_pr_checks (proved above and in test-shape-ci-wait.sh).
if grep -nE 'gh pr checks|statusCheckRollup' "$SCRIPTS/swarm-merge.sh" | grep -v '^[0-9]*:[[:space:]]*#' ; then
    red "swarm-merge.sh reads CI state directly; it must go through ci-wait.sh"
fi
grep -q 'ci_pr_checks' "$SCRIPTS/ci-wait.sh" || red "ci-wait.sh no longer uses ci_pr_checks"
grep -q 'ci_pr_checks' "$SCRIPTS/ready-sweep.sh" || red "ready-sweep.sh no longer uses ci_pr_checks"
grep -q 'ci_pr_checks' "$SCRIPTS/pr-ready.sh" || red "pr-ready.sh no longer uses ci_pr_checks"
if grep -nE 'gh pr checks "\$(PR|pr)"' "$SCRIPTS/ci-wait.sh" "$SCRIPTS/pr-ready.sh" "$SCRIPTS/ready-sweep.sh" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#'; then
    red "a bare gh pr checks call bypasses the liveness filter"
fi
green "swarm-merge.sh reads CI only via ci-wait.sh; ci-wait.sh and pr-ready.sh only via ci_pr_checks"
