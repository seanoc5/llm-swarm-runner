#!/usr/bin/env bash
#
# pr-ready.sh — `gh pr ready` wrapper that posts the self-review verdict
# marker BEFORE readying, so a human merging straight from the GitHub web
# UI sees BLOCK/APPROVE_WITH_CAVEATS/APPROVE history without any
# coordinator involvement.
#
# issue #439 (ask 3): today only an explicit `self-review-pr.sh --post`
# posts the `<!-- SWARM_SELF_REVIEW: ... -->` marker comment — a worker
# that runs bare `gh pr ready` for a 🟡/🔴 PR never posts it, so
# swarm-merge.sh's BLOCK gate and a web-UI merger both see nothing (the
# SAMlytics wt-issue-296 incident: a PR with a self-review BLOCK -> fixed
# -> APPROVE_WITH_CAVEATS history was merged from the web UI with none of
# that visible on the PR itself).
#
# Usage:
#   pr-ready.sh <PR#>
#
# Reads the PR body's `<!-- BLIND_MERGE_RISK: low|medium|high -->` marker
# (prompts/worker.md § "PR risk assessment") to decide whether self-review
# applies at all, mirroring that doc's own rubric exactly:
#   low            self-review not required — readies immediately.
#   medium/high    runs `self-review-pr.sh <PR#> --post` first.
#                    BLOCK                -> refuses to ready, exit 2
#                    APPROVE / WITH_CAVEATS -> proceeds to `gh pr ready`
#                    skipped (WORKER_SELF_REVIEW=0) -> proceeds anyway
#                    error (gh/claude failure)      -> WARNs, proceeds anyway
#                      (fail open: self-review infra being down must never
#                      silently block a PR from ever going ready — but this
#                      is printed loudly, not swallowed, per worker.md's
#                      "never silently bypass the layer")
#   missing/unparseable  treated as medium (fail toward requiring review)
#
# Exit codes:
#   0  readied (gh pr ready ran)
#   2  refused — self-review returned BLOCK
#   1  usage / gh error resolving the PR body
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"
# Overridable for testing (a stub in place of the real self-review-pr.sh,
# which shells out to `claude -p` and can't be exercised in CI/tests).
SELF_REVIEW="${SELF_REVIEW_SCRIPT:-$SCRIPT_DIR/self-review-pr.sh}"

PR="${1:?usage: pr-ready.sh <PR#>}"
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }

BODY="$(gh pr view "$PR" --json body --jq .body 2>/dev/null)" \
    || { echo "ERROR: gh pr view $PR failed" >&2; exit 1; }

RISK="$(grep -oE '<!-- BLIND_MERGE_RISK: (low|medium|high) -->' <<<"$BODY" \
    | head -1 | sed -E 's/.*: (low|medium|high) -->/\1/' || true)"

case "$RISK" in
    low)
        echo "pr-ready: risk=low — self-review not required (worker.md rubric); readying"
        ;;
    medium|high|"")
        if [ -z "$RISK" ]; then
            echo "pr-ready: WARN: no BLIND_MERGE_RISK marker found on PR #$PR's body — treating as medium (fail toward requiring review)" >&2
            RISK="medium"
        fi
        echo "pr-ready: risk=$RISK — running self-review ($SELF_REVIEW $PR --post)..."
        rc=0
        "$SELF_REVIEW" "$PR" --post || rc=$?
        case "$rc" in
            0|3)
                : # APPROVE / APPROVE_WITH_CAVEATS — proceed
                ;;
            2)
                echo "pr-ready: REFUSED — self-review returned BLOCK on PR #$PR. Fix the finding and re-push," >&2
                echo "          then re-run pr-ready.sh, or bypass this wrapper entirely with:" >&2
                echo "            gh pr ready $PR" >&2
                exit 2
                ;;
            4)
                echo "pr-ready: self-review skipped (WORKER_SELF_REVIEW=0) — readying anyway. Flag this in your handoff."
                ;;
            *)
                echo "pr-ready: WARN: self-review-pr.sh failed (exit $rc) — could not post a verdict marker. Readying anyway; flag this in your handoff." >&2
                ;;
        esac
        ;;
esac

echo "pr-ready: gh pr ready $PR"
gh pr ready "$PR"
