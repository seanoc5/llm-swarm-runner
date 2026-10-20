#!/usr/bin/env bash
#
# test-pr-ci-rollup.sh — unit test for coordinator-watch.sh's pr_ci_state
# jq filter (issue #650): a check that was CANCELLED because a newer run
# for the same name superseded it (concurrency, rerun) must not flip the
# combined CI state to "fail" once that newer run has passed.
#
# Extracts the real --jq program out of coordinator-watch.sh (the block
# between "--jq 'def ci:" and the .[] | "\(.number)..." projection line)
# and runs it directly against crafted `gh pr list
# --json number,body,statusCheckRollup` fixtures, so this test fails if
# the source filter drifts without this test being updated too.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -f "$WATCH" ] || red "coordinator-watch.sh not found: $WATCH"

FILTER="$(sed -n "/--jq 'def ci:/,/\.\[\] | \"\\\\(\.number)/p" "$WATCH" \
    | sed "1s/^ *--jq '//; \$s/' 2>\/dev\/null)\$//")"
[ -n "$FILTER" ] || red "could not extract the ci jq filter from $WATCH"

run_case() {
    local label="$1" json="$2" expect="$3" got
    got="$(printf '%s' "$json" | jq -r "$FILTER" | cut -f3)"
    [ "$got" = "$expect" ] || red "$label: expected ci=$expect, got ci=$got"
    green "$label -> ci=$got"
}

# Issue #650's exact scenario: a Fast run cancelled (superseded by
# concurrency) sitting next to a later, successful Fast run for the same
# workflow+name, plus an unrelated clean Integration check.
run_case "cancelled-then-pass (superseded run)" '[{
  "number": 1458, "body": "",
  "statusCheckRollup": [
    {"__typename":"CheckRun","workflowName":"CI","name":"Fast","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-10-19T23:20:00Z","completedAt":"2026-10-19T23:24:00Z"},
    {"__typename":"CheckRun","workflowName":"CI","name":"Fast","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T23:25:00Z","completedAt":"2026-10-19T23:30:00Z"},
    {"__typename":"CheckRun","workflowName":"CI","name":"Integration","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T23:25:00Z","completedAt":"2026-10-19T23:31:00Z"}
  ]
}]' "pass"

# A check whose NEWEST run really is cancelled must still fail.
run_case "pass-then-cancelled (genuinely cancelled)" '[{
  "number": 1459, "body": "",
  "statusCheckRollup": [
    {"__typename":"CheckRun","workflowName":"CI","name":"Fast","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T23:20:00Z","completedAt":"2026-10-19T23:24:00Z"},
    {"__typename":"CheckRun","workflowName":"CI","name":"Fast","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-10-19T23:25:00Z","completedAt":"2026-10-19T23:30:00Z"}
  ]
}]' "fail"

# A genuine failure elsewhere in the rollup still fails, unaffected by
# the collapse.
run_case "unrelated real failure" '[{
  "number": 1460, "body": "",
  "statusCheckRollup": [
    {"__typename":"CheckRun","workflowName":"CI","name":"Fast","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T23:20:00Z","completedAt":"2026-10-19T23:24:00Z"},
    {"__typename":"CheckRun","workflowName":"CI","name":"Lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-19T23:20:00Z","completedAt":"2026-10-19T23:24:00Z"}
  ]
}]' "fail"

# A still-running check (no completedAt yet) is pending, not swallowed by
# the collapse.
run_case "in-progress check" '[{
  "number": 1461, "body": "",
  "statusCheckRollup": [
    {"__typename":"CheckRun","workflowName":"CI","name":"Fast","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T23:20:00Z","completedAt":"2026-10-19T23:24:00Z"},
    {"__typename":"CheckRun","workflowName":"CI","name":"Integration","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-19T23:25:00Z"}
  ]
}]' "pending"

# No checks reported at all.
run_case "no checks" '[{"number": 1462, "body": "", "statusCheckRollup": []}]' "none"

green "all pr_ci_state rollup-collapse cases passed"
