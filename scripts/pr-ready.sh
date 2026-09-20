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
#   medium/high    checks WORKER_SELF_REVIEW itself (same kill switch
#                  self-review-pr.sh honors) BEFORE calling it, then runs
#                  `self-review-pr.sh <PR#> --post --force` (--force: see
#                  the code comment at the call site for why this is
#                  mandatory, not optional, once we've decided to run at
#                  all — WORKER_SELF_REVIEW=0 is handled here instead, so
#                  --force never bypasses that kill switch).
#                    WORKER_SELF_REVIEW=0    -> skips the call, proceeds anyway
#                    BLOCK                   -> refuses to ready, exit 2
#                    APPROVE / WITH_CAVEATS  -> proceeds to `gh pr ready`
#                    error (gh/claude failure) -> WARNs, proceeds anyway
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
        if [ "${WORKER_SELF_REVIEW:-1}" = "0" ]; then
            # Checked HERE, before ever invoking self-review-pr.sh, rather
            # than relying on its own exit-4 "skipped" path: --force below
            # is mandatory for the retry case (see that comment), and
            # self-review-pr.sh's --force also bypasses ITS OWN
            # WORKER_SELF_REVIEW=0 check (--force means "run even when
            # WORKER_SELF_REVIEW=0" by its own docs) — passing --force
            # unconditionally would silently defeat the kill switch worker.md
            # documents. Gating on the same env var here, before the call,
            # keeps the kill switch intact while still letting --force do
            # its actual job once we've already decided to run.
            echo "pr-ready: self-review skipped (WORKER_SELF_REVIEW=0) — readying anyway. Flag this in your handoff."
        else
            echo "pr-ready: risk=$RISK — running self-review ($SELF_REVIEW $PR --post --force)..."
            rc=0
            # --force is required, not optional (self-review's own
            # self-review finding on this script's first version):
            # self-review-pr.sh's --post skips posting whenever ANY
            # SWARM_SELF_REVIEW comment already exists, regardless of
            # verdict (see its own header comment). Without --force, a
            # worker's documented retry path (BLOCK -> fix -> re-run
            # pr-ready.sh) would get a fresh APPROVE here but post
            # nothing — the PR would ready with a stale BLOCK marker as
            # its latest verdict, which is exactly the gate this script
            # exists to keep accurate.
            "$SELF_REVIEW" "$PR" --post --force || rc=$?
            case "$rc" in
                0|3)
                    : # APPROVE / APPROVE_WITH_CAVEATS — proceed
                    ;;
                2)
                    # issue #439 self-review (round 7): deliberately does
                    # NOT print a bypass command. worker.md tells workers
                    # to call this wrapper instead of bare `gh pr ready`
                    # specifically so a BLOCK can't be readied past —
                    # handing that exact bypass to the worker the gate
                    # exists to slow down would defeat the whole point.
                    # Fix the finding and re-run; an operator who
                    # genuinely wants to override already knows they can
                    # run gh directly.
                    echo "pr-ready: REFUSED — self-review returned BLOCK on PR #$PR." >&2
                    echo "          Fix the finding and re-push, then re-run pr-ready.sh." >&2
                    exit 2
                    ;;
                *)
                    # self-review-pr.sh's own exit 4 (skipped,
                    # WORKER_SELF_REVIEW=0) is unreachable here — we always
                    # pass --force once we've decided to call it at all, and
                    # the WORKER_SELF_REVIEW=0 case is handled above, before
                    # this call, instead. So anything landing here is a
                    # genuine error (gh/claude failure, exit 1).
                    echo "pr-ready: WARN: self-review-pr.sh failed (exit $rc) — could not post a verdict marker. Readying anyway; flag this in your handoff." >&2
                    ;;
            esac
        fi
        ;;
esac

echo "pr-ready: gh pr ready $PR"
gh pr ready "$PR"
