#!/usr/bin/env bash
#
# ci-wait.sh — the correct sequence for waiting on a PR's CI, so workers
# stop hand-rolling `until gh run list ... | grep -q <sha>; do sleep 5;
# done` loops (see prompts/worker.md "Run long commands in the foreground").
#
# Sequence:
#   1. Mergeability check first. `pull_request`-triggered workflows check
#      out the merge-preview ref (refs/pull/N/merge). When the PR is
#      CONFLICTING/DIRTY against its base, GitHub can't build that ref, so
#      no workflow run is EVER created — not pending, not failed, silence.
#      A poll loop watching for that run would spin until its timeout with
#      no failure signal. Catch this before waiting, not after.
#   2. One bounded foreground poll of `gh pr checks`, fixed interval, hard
#      deadline — never an unbounded loop.
#
# Usage:
#   ci-wait.sh <PR#> [timeout-seconds]
#
# Env:
#   CI_WAIT_TIMEOUT_SECONDS   default deadline if no arg given (default 900)
#   CI_WAIT_POLL_SECONDS      poll interval (default 15)
#
# Exit codes:
#   0  all required checks passing
#   1  one or more checks failed
#   2  timeout — still pending when the deadline hit
#   3  PR is CONFLICTING/DIRTY against its base — no run will ever fire;
#      rebase onto the base branch and re-push before waiting again
#   4  usage / gh error
#
# Run this in the foreground with an explicit Bash timeout that covers the
# deadline below (e.g. timeout-seconds + ~30s of slack for gh calls).

set -euo pipefail

PR="${1:-}"
TIMEOUT="${2:-${CI_WAIT_TIMEOUT_SECONDS:-900}}"
POLL="${CI_WAIT_POLL_SECONDS:-15}"

[ -n "$PR" ] || { echo "Usage: $0 <PR#> [timeout-seconds]" >&2; exit 4; }

MERGE_JSON="$(gh pr view "$PR" --json mergeable,mergeStateStatus,headRefOid 2>&1)" \
    || { echo "ci-wait: gh pr view $PR failed: $MERGE_JSON" >&2; exit 4; }

MERGEABLE="$(jq -r '.mergeable' <<<"$MERGE_JSON")"
MERGE_STATE="$(jq -r '.mergeStateStatus' <<<"$MERGE_JSON")"
SHA="$(jq -r '.headRefOid' <<<"$MERGE_JSON")"

# GitHub computes mergeability asynchronously — a fresh push can read back
# UNKNOWN for a few seconds. One short retry before trusting it.
if [ "$MERGEABLE" = "UNKNOWN" ]; then
    sleep 3
    MERGE_JSON="$(gh pr view "$PR" --json mergeable,mergeStateStatus,headRefOid 2>&1)" \
        || { echo "ci-wait: gh pr view $PR failed: $MERGE_JSON" >&2; exit 4; }
    MERGEABLE="$(jq -r '.mergeable' <<<"$MERGE_JSON")"
    MERGE_STATE="$(jq -r '.mergeStateStatus' <<<"$MERGE_JSON")"
fi

if [ "$MERGEABLE" = "CONFLICTING" ] || [ "$MERGE_STATE" = "DIRTY" ]; then
    echo "ci-wait: PR #$PR is $MERGEABLE/$MERGE_STATE against its base — no pull_request run will ever fire. Rebase onto the base branch and re-push, then re-run ci-wait.sh." >&2
    exit 3
fi

echo "ci-wait: PR #$PR mergeable ($MERGE_STATE), watching checks on ${SHA:0:12} (deadline ${TIMEOUT}s, poll ${POLL}s)"

DEADLINE=$(( $(date -u +%s) + TIMEOUT ))
while true; do
    set +e
    CHECKS_OUT="$(gh pr checks "$PR" 2>&1)"
    CHECKS_RC=$?
    set -e
    case "$CHECKS_RC" in
        0) echo "ci-wait: PR #$PR checks green."; exit 0 ;;
        1) echo "ci-wait: PR #$PR has failing checks:"; echo "$CHECKS_OUT" >&2; exit 1 ;;
        8) : ;; # pending — fall through to deadline/sleep below
        *) echo "ci-wait: gh pr checks $PR exited $CHECKS_RC:"; echo "$CHECKS_OUT" >&2; exit 4 ;;
    esac

    NOW=$(date -u +%s)
    [ "$NOW" -lt "$DEADLINE" ] || {
        echo "ci-wait: timed out after ${TIMEOUT}s waiting on PR #$PR (still pending)." >&2
        exit 2
    }
    sleep "$POLL"
done
