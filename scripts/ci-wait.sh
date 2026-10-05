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
# Fine-grained personal access tokens (see docs/gh-token-scoping.md): GitHub
# offers no "Checks" permission for this token type, so `gh pr checks` fails
# outright with "Resource not accessible by personal access token" — not a
# real/pending/failed result, a permission error. When that text is seen
# once, this script switches for the rest of the run to polling
# `gh run list --commit <sha>` instead (needs only Actions: read, which
# these tokens already have) and maps the runs itself: any completed run
# concluding failure/cancelled/timed_out/action_required/startup_failure/
# stale → fail; once every run has completed with success/skipped/neutral
# → pass; otherwise (anything still queued/in_progress, or no runs yet) →
# pending. Exit codes and the deadline are unchanged. Behaviour with a
# normal OAuth login token (which can read Checks) is unaffected — the
# fallback only engages on that exact permission-error text.
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
#   5  no CI checks are configured on this repo at all — distinct from a
#      real failure (1): nothing ran, so nothing failed. A caller that wants
#      "pass with a loud warning" instead of "refuse" for a CI-less project
#      (swarm-merge.sh --auto-low Gate 2 does exactly this) should treat 5
#      separately from 1; a caller that wants any non-green to refuse can
#      still treat 5 like any other non-zero exit.
#
#      `gh pr checks` reporting "no checks reported on the ... branch" is
#      NOT by itself proof of 5 — that same message also fires in the real,
#      ordinary race where CI *is* configured but this push's workflow run
#      hasn't been registered by GitHub yet (a window of seconds after
#      `git push`, sometimes longer). Trusting the message on its own would
#      recreate the exact failure this script exists to close (#452: PR #713
#      merged before its CI had actually run). So a "no checks reported"
#      reading is resolved against a repo-level, timing-independent signal —
#      the workflow count from `gh api .../actions/workflows` — instead of
#      the message text alone: zero workflows configured → 5, immediately.
#      One or more workflows configured but this snapshot still shows no
#      checks → treated as PENDING (keeps polling, same as gh pr checks
#      exit 8), not as absence; it either resolves to a real check result or
#      times out (2) like any other slow-to-start CI.
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
WORKFLOW_COUNT=""   # lazily resolved at most once, only if "no checks" is ever seen
FALLBACK=0          # set once "gh pr checks" proves unreadable by this token
while true; do
    if [ "$FALLBACK" != "1" ]; then
        set +e
        CHECKS_OUT="$(gh pr checks "$PR" 2>&1)"
        CHECKS_RC=$?
        set -e

        if grep -qi "resource not accessible by personal access token" <<<"$CHECKS_OUT"; then
            FALLBACK=1
            echo "ci-wait: gh pr checks is not readable by this token (fine-grained PATs have no Checks permission) — falling back to polling gh run list --commit ${SHA:0:12} for PR #$PR." >&2
        fi
    fi

    if [ "$FALLBACK" = "1" ]; then
        set +e
        RUNS_JSON="$(gh run list --commit "$SHA" --json status,conclusion 2>&1)"
        RUNS_RC=$?
        set -e
        [ "$RUNS_RC" -eq 0 ] || { echo "ci-wait: gh run list --commit $SHA failed: $RUNS_JSON" >&2; exit 4; }

        RUN_STATE="$(jq -r '
            (map(select(.status == "completed"))) as $done |
            if ($done | map(select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale")) | length) > 0 then "fail"
            elif (length > 0) and (($done | length) == length) and (($done | map(select(.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral")) | length) == length) then "pass"
            else "pending"
            end' <<<"$RUNS_JSON")"

        case "$RUN_STATE" in
            pass) echo "ci-wait: PR #$PR checks green (via Actions-runs fallback)."; exit 0 ;;
            fail)
                echo "ci-wait: PR #$PR has failing checks (via Actions-runs fallback):" >&2
                echo "$RUNS_JSON" >&2
                exit 1 ;;
            pending) : ;; # fall through to deadline/sleep below
        esac
    else
        case "$CHECKS_RC" in
            0) echo "ci-wait: PR #$PR checks green."; exit 0 ;;
            1)
                if grep -qi "no checks reported" <<<"$CHECKS_OUT"; then
                    if [ -z "$WORKFLOW_COUNT" ]; then
                        WORKFLOW_COUNT="$(gh api repos/{owner}/{repo}/actions/workflows --jq '.total_count' 2>/dev/null || true)"
                        # A failed lookup must still count as "resolved" (just
                        # not "0") — otherwise a persistently-failing `gh api`
                        # call gets re-run on every single poll instead of once.
                        [ -n "$WORKFLOW_COUNT" ] || WORKFLOW_COUNT="unknown"
                    fi
                    if [ "$WORKFLOW_COUNT" = "0" ]; then
                        echo "ci-wait: PR #$PR has no CI checks configured on this repo at all (0 workflows) — nothing ran, so nothing failed." >&2
                        exit 5
                    fi
                    # Workflows exist (or the workflow-count lookup itself
                    # failed, in which case failing closed means NOT assuming
                    # absence) — this is the run-not-registered-yet race, not a
                    # CI-less repo. Treat as pending, same as exit 8 below.
                    echo "ci-wait: PR #$PR shows no checks yet, but the repo has CI configured — treating as pending, not absent." >&2
                else
                    echo "ci-wait: PR #$PR has failing checks:"; echo "$CHECKS_OUT" >&2; exit 1
                fi
                ;;
            8) : ;; # pending — fall through to deadline/sleep below
            *) echo "ci-wait: gh pr checks $PR exited $CHECKS_RC:"; echo "$CHECKS_OUT" >&2; exit 4 ;;
        esac
    fi

    NOW=$(date -u +%s)
    [ "$NOW" -lt "$DEADLINE" ] || {
        echo "ci-wait: timed out after ${TIMEOUT}s waiting on PR #$PR (still pending)." >&2
        exit 2
    }
    sleep "$POLL"
done
