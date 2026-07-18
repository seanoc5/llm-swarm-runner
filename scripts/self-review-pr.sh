#!/usr/bin/env bash
#
# self-review-pr.sh — Run the fresh-context adversarial self-review on an
# open PR and (optionally) post the verdict as a machine-parseable PR comment.
#
# This turns the worker-side self-review *convention* (prompts/worker.md
# § "Self-review before merge") into *machinery*: a script any party can run
# — worker, coordinator, watcher, CI — whose verdict is parseable from the
# exit code and from a marker comment on the PR. "Review as harness
# machinery, not prompt convention" is a concept adopted from Nate B.
# Jones's ringer (original implementation, no code copied — attribution in
# docs/ringer-adoptions.md #2).
#
# The review itself is the existing skill prompt
# (prompts/skill-self-review.md) fed to a fresh `claude -p` session together
# with the PR title/body and full diff — zero shared context with whoever
# wrote the code; that's the point.
#
# Usage:
#   self-review-pr.sh <PR#> [--post] [--force] [--model <id>]
#
#   --post    also post the verdict as a PR comment with a
#             <!-- SWARM_SELF_REVIEW: <VERDICT> --> marker. Idempotent:
#             skips posting if a marker comment already exists (--force
#             re-posts).
#   --force   run even when WORKER_SELF_REVIEW=0, and re-post over an
#             existing marker comment.
#   --model   model for the review session (default: $SELF_REVIEW_MODEL,
#             else the claude CLI's default).
#
# Exit codes (gate-friendly — swarm-merge.sh consumes the marker comment):
#   0  APPROVE
#   3  APPROVE_WITH_CAVEATS
#   2  BLOCK
#   4  skipped (WORKER_SELF_REVIEW=0 and no --force)
#   1  error (gh/claude failure, unparseable verdict, bad args)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${LLM_SWARM_DIR:-$SCRIPT_DIR/..}/prompts/skill-self-review.md"

PR=""
POST=0
FORCE=0
MODEL="${SELF_REVIEW_MODEL:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --post)  POST=1 ;;
        --force) FORCE=1 ;;
        --model) shift; MODEL="${1:-}" ;;
        -h|--help) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        *)  [ -z "$PR" ] || { echo "ERROR: multiple PR numbers" >&2; exit 1; }
            PR="$1" ;;
    esac
    shift
done
[ -n "$PR" ] || { echo "Usage: $0 <PR#> [--post] [--force] [--model <id>]" >&2; exit 1; }
[ -r "$SKILL" ] || { echo "ERROR: skill prompt not readable: $SKILL" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI required" >&2; exit 1; }

if [ "${WORKER_SELF_REVIEW:-1}" = "0" ] && [ "$FORCE" = "0" ]; then
    echo "self-review: skipped — WORKER_SELF_REVIEW=0 (use --force to run anyway)"
    exit 4
fi

# --- gather PR content ------------------------------------------------------
DIFF="$(gh pr diff "$PR")" || { echo "ERROR: gh pr diff $PR failed" >&2; exit 1; }
BODY="$(gh pr view "$PR" --json title,body --jq '"\(.title)\n\n\(.body)"')" \
    || { echo "ERROR: gh pr view $PR failed" >&2; exit 1; }

# --- run the fresh-context review ------------------------------------------
MODEL_OPTS=()
[ -n "$MODEL" ] && MODEL_OPTS=(--model "$MODEL")
REVIEW="$(printf '%s\n\n--- PR ---\n%s\n\n--- DIFF ---\n%s\n' \
    "$(cat "$SKILL")" "$BODY" "$DIFF" \
    | claude -p "${MODEL_OPTS[@]}" --dangerously-skip-permissions)" \
    || { echo "ERROR: claude -p review invocation failed" >&2; exit 1; }

VERDICT_LINE="$(printf '%s\n' "$REVIEW" \
    | grep -m1 -E '^(APPROVE|APPROVE_WITH_CAVEATS:|BLOCK:)' || true)"
case "$VERDICT_LINE" in
    APPROVE*CAVEATS:*) VERDICT="APPROVE_WITH_CAVEATS"; EXIT=3 ;;
    APPROVE*)          VERDICT="APPROVE";              EXIT=0 ;;
    BLOCK:*)           VERDICT="BLOCK";                EXIT=2 ;;
    *)
        echo "ERROR: no verdict token in review output:" >&2
        printf '%s\n' "$REVIEW" >&2
        exit 1
        ;;
esac

echo "PR #$PR self-review verdict: $VERDICT"
echo "---"
printf '%s\n' "$REVIEW"
echo "---"

# --- optionally post as a PR comment ---------------------------------------
if [ "$POST" = "1" ]; then
    if [ "$FORCE" = "0" ] && gh pr view "$PR" --json comments \
            --jq '.comments[].body' 2>/dev/null | grep -q 'SWARM_SELF_REVIEW:'; then
        echo "post: skipped — PR #$PR already has a SWARM_SELF_REVIEW comment (--force to re-post)"
    else
        COMMENT="$(printf '<!-- SWARM_SELF_REVIEW: %s -->\n## Fresh-context self-review\n\n%s\n\n<sub>Adversarial review by a fresh claude session against prompts/skill-self-review.md — no shared context with the PR author. Machinery: scripts/self-review-pr.sh (docs/ringer-adoptions.md #2).</sub>\n' \
            "$VERDICT" "$REVIEW")"
        gh pr comment "$PR" --body "$COMMENT" \
            || { echo "ERROR: gh pr comment failed" >&2; exit 1; }
        echo "post: verdict comment added to PR #$PR"
    fi
fi

exit "$EXIT"
