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
# (prompts/skill-self-review.md) fed to a fresh Claude or Codex session together
# with the PR title/body and full diff — zero shared context with whoever
# wrote the code; that's the point.
#
# Usage:
#   self-review-pr.sh <PR#> [--post] [--force] [--model <id>] [--actor <name>]
#   self-review-pr.sh <PR#> --caveats-nonblocking <issue#> --actor coordinator|operator
#
#   --post    also post the verdict as a PR comment with a
#             <!-- SWARM_SELF_REVIEW: <VERDICT> actor=<name> head=<sha> -->
#             marker (head= is the PR head commit that was reviewed).
#             Idempotent: skips posting if a marker comment already exists
#             (--force re-posts).
#   --force   run even when WORKER_SELF_REVIEW=0, and re-post over an
#             existing marker comment.
#   --model   model for the review session (default: $SELF_REVIEW_MODEL,
#             else $WORKER_MODEL for Codex, else the CLI's default).
#   --actor   who is running this round — "worker" (default), "coordinator",
#             or "operator". Recorded in the posted marker's actor=<name>
#             attribute (issue #601): scripts/pr-ready.sh's round cap
#             (WORKER_SELF_REVIEW_MAX_ROUNDS) counts only actor=worker
#             rounds against the worker, so an independent "Find ≠ fix"
#             review the coordinator or operator runs on top of the
#             worker's own rounds never eats into the worker's budget. The
#             BLOCK/latest-verdict gate itself still looks at EVERY actor's
#             marker — a coordinator- or operator-found BLOCK blocks
#             readying same as a worker-found one; only the round COUNT is
#             actor-scoped. Pass --actor coordinator from
#             prompts/coordinator.md's "Find ≠ fix" dispatch, and --actor
#             operator for a manual re-review from a shell.
#   --caveats-nonblocking <issue#>
#             runs NO review: records that the latest coordinator/operator
#             APPROVE_WITH_CAVEATS on the current head has only non-blocking
#             caveats, tracked in follow-up <issue#>, by posting
#             `<!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=<name>
#             head=<sha> caveats=nonblocking followup=<issue#> -->`.
#             swarm-merge.sh --auto-medium Gate 9 accepts that marker.
#             Refuses (exit 1) unless the actor is coordinator/operator, the
#             issue exists, and that review is APPROVE_WITH_CAVEATS on the
#             current head. Exit 0 once posted.
#   SELF_REVIEW_CMD selects claude or codex; defaults to WORKER_CMD when
#             it is codex, otherwise claude for compatibility.
#   SELF_REVIEW_UNSET_API_KEY=1  run `claude -p` under `env -u
#             ANTHROPIC_API_KEY`, so the review uses the claude.ai login
#             instead of an exhausted/unrelated API key a project .envrc
#             exported (issue #673).
#
# Exit codes (gate-friendly — swarm-merge.sh consumes the marker comment):
#   0  APPROVE
#   3  APPROVE_WITH_CAVEATS
#   2  BLOCK
#   4  skipped (WORKER_SELF_REVIEW=0 and no --force)
#   1  error (gh/agent failure, unparseable verdict, bad args)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${LLM_SWARM_DIR:-$SCRIPT_DIR/..}/prompts/skill-self-review.md"

PR=""
POST=0
FORCE=0
ACTOR="worker"
NONBLOCKING_FOLLOWUP=""
MODEL="${SELF_REVIEW_MODEL:-}"
REVIEW_CMD="${SELF_REVIEW_CMD:-claude}"
if [ -z "${SELF_REVIEW_CMD:-}" ] && [ "${WORKER_CMD:-}" = "codex" ]; then
    REVIEW_CMD=codex
fi
if [ "$REVIEW_CMD" = "codex" ]; then
    MODEL="${SELF_REVIEW_MODEL:-${WORKER_MODEL:-}}"
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --post)  POST=1 ;;
        --force) FORCE=1 ;;
        --model) shift; MODEL="${1:-}" ;;
        --actor) shift; ACTOR="${1:-}" ;;
        --caveats-nonblocking) shift; NONBLOCKING_FOLLOWUP="${1:-}"
            [[ "$NONBLOCKING_FOLLOWUP" =~ ^[0-9]+$ ]] \
                || { echo "ERROR: --caveats-nonblocking needs a follow-up issue number" >&2; exit 1; } ;;
        -h|--help) sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        *)  [ -z "$PR" ] || { echo "ERROR: multiple PR numbers" >&2; exit 1; }
            PR="$1" ;;
    esac
    shift
done
[ -n "$PR" ] || { echo "Usage: $0 <PR#> [--post] [--force] [--model <id>] [--actor <name>]" >&2; exit 1; }
case "$ACTOR" in
    worker|coordinator|operator) ;;
    *) echo "ERROR: --actor must be worker, coordinator, or operator (got '$ACTOR')" >&2; exit 1 ;;
esac

# --- record non-blocking caveats (no review run) ----------------------------
if [ -n "$NONBLOCKING_FOLLOWUP" ]; then
    command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }
    [ "$ACTOR" != worker ] \
        || { echo "ERROR: --caveats-nonblocking needs --actor coordinator or operator (the author never judges its own caveats)" >&2; exit 1; }
    # The follow-up must be a real, OPEN issue that mentions this PR, so an
    # old/closed/unrelated issue can't stand in for it (issue #687).
    FOLLOWUP_JSON="$(gh issue view "$NONBLOCKING_FOLLOWUP" --json url,state,title,body,labels 2>/dev/null || true)"
    FOLLOWUP_URL="$(jq -r '.url // ""' <<<"$FOLLOWUP_JSON" 2>/dev/null || true)"
    [[ "$FOLLOWUP_URL" == */issues/"$NONBLOCKING_FOLLOWUP" ]] \
        || { echo "ERROR: follow-up #$NONBLOCKING_FOLLOWUP is not an issue in this repo — file it first" >&2; exit 1; }
    [ "$(jq -r '.state // ""' <<<"$FOLLOWUP_JSON")" = OPEN ] \
        || { echo "ERROR: follow-up #$NONBLOCKING_FOLLOWUP is not OPEN — file a new open follow-up for PR #$PR" >&2; exit 1; }
    jq -e --arg re "#$PR([^0-9]|\$)" --arg lb "from-pr-$PR" '(((.title // "") + "\n" + (.body // "")) | test($re)) or any(.labels[]?; .name == $lb)' <<<"$FOLLOWUP_JSON" >/dev/null 2>&1 \
        || { echo "ERROR: follow-up #$NONBLOCKING_FOLLOWUP does not mention #$PR in its title or body and lacks label from-pr-$PR — it must reference the PR whose caveats it tracks" >&2; exit 1; }
    PR_JSON="$(gh pr view "$PR" --json comments,headRefOid)" \
        || { echo "ERROR: gh pr view $PR failed" >&2; exit 1; }
    HEAD_SHA="$(jq -r '.headRefOid // ""' <<<"$PR_JSON")"
    # Same selection as swarm-merge.sh Gate 9: latest independent marker.
    LAST="$(jq -r '.comments[] | select(.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) | .body // ""' <<<"$PR_JSON" \
        | grep -oE 'SWARM_SELF_REVIEW: [A-Z_]+ actor=(coordinator|operator)( head=[0-9a-f]+)?' | tail -1 || true)"
    LAST_VERDICT="$(sed -E 's/^SWARM_SELF_REVIEW: ([A-Z_]+).*/\1/' <<<"$LAST")"
    LAST_HEAD="$(grep -oE 'head=[0-9a-f]+' <<<"$LAST" | cut -d= -f2 || true)"
    if [ -z "$HEAD_SHA" ] || [ "$LAST_VERDICT" != APPROVE_WITH_CAVEATS ] || [ "$LAST_HEAD" != "$HEAD_SHA" ]; then
        echo "ERROR: latest coordinator/operator review on PR #$PR is '${LAST:-<none>}', not APPROVE_WITH_CAVEATS on head ${HEAD_SHA:-<unreadable>}." >&2
        echo "       Run self-review-pr.sh $PR --post --force --actor $ACTOR first." >&2
        exit 1
    fi
    COMMENT="$(printf '<!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=%s head=%s caveats=nonblocking followup=%s -->\n## Caveats recorded as non-blocking\n\nThe %s judged the caveats in the review of %s not about correctness, security, data loss, or schema/migrations. Follow-up: #%s.\n' \
        "$ACTOR" "$HEAD_SHA" "$NONBLOCKING_FOLLOWUP" "$ACTOR" "${HEAD_SHA:0:7}" "$NONBLOCKING_FOLLOWUP")"
    gh pr comment "$PR" --body "$COMMENT" || { echo "ERROR: gh pr comment failed" >&2; exit 1; }
    echo "PR #$PR: caveats recorded as non-blocking (follow-up #$NONBLOCKING_FOLLOWUP, head $HEAD_SHA)"
    exit 0
fi

[ -r "$SKILL" ] || { echo "ERROR: skill prompt not readable: $SKILL" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }
case "$REVIEW_CMD" in
    claude|codex) ;;
    *) echo "ERROR: unsupported SELF_REVIEW_CMD: $REVIEW_CMD" >&2; exit 1 ;;
esac
command -v "$REVIEW_CMD" >/dev/null 2>&1 || { echo "ERROR: $REVIEW_CMD CLI required" >&2; exit 1; }

if [ "${WORKER_SELF_REVIEW:-1}" = "0" ] && [ "$FORCE" = "0" ]; then
    echo "self-review: skipped — WORKER_SELF_REVIEW=0 (use --force to run anyway)"
    exit 4
fi

# --- gather PR content ------------------------------------------------------
# Head SHA read BEFORE the diff and recorded in the marker as head=<sha>, so
# swarm-merge.sh --auto-medium can require an APPROVE on the exact commit it
# merges. A push landing between these two reads makes the recorded head
# older than the reviewed diff, which the gate sees as a mismatch and
# refuses: fail closed.
HEAD_SHA="$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null || true)"

# Once per (head, actor) (issue #599): a --post run is a no-op when an
# owner/member/collaborator-authored marker for THIS head by THIS actor
# already exists; the prior verdict is replayed as the exit code. A worker
# round plus the coordinator's independent "Find ≠ fix" round on one head
# are still two reviews (different actors); only a same-actor repeat is
# skipped. Markers without head= (pre-#601) never match. --force re-runs.
if [ "$POST" = "1" ] && [ "$FORCE" = "0" ] && [ -n "$HEAD_SHA" ]; then
    PRIOR="$(gh pr view "$PR" --json comments 2>/dev/null | jq -r --arg a "$ACTOR" --arg h "$HEAD_SHA" '
        [.comments[]? | select(.authorAssociation as $x | ["OWNER","MEMBER","COLLABORATOR"] | index($x))
         | (.body // "") | capture("SWARM_SELF_REVIEW: (?<v>[A-Z_]+) actor=" + $a + " head=" + $h + "(?![0-9a-f])")? | .v]
        | last // ""' 2>/dev/null || true)"
    case "$PRIOR" in
        APPROVE|APPROVE_WITH_CAVEATS|BLOCK)
            echo "self-review: skipped — PR #$PR head ${HEAD_SHA:0:7} already has an actor=$ACTOR review ($PRIOR); --force to re-run"
            case "$PRIOR" in APPROVE) exit 0 ;; BLOCK) exit 2 ;; *) exit 3 ;; esac ;;
    esac
fi

DIFF="$(gh pr diff "$PR")" || { echo "ERROR: gh pr diff $PR failed" >&2; exit 1; }
BODY="$(gh pr view "$PR" --json title,body --jq '"\(.title)\n\n\(.body)"')" \
    || { echo "ERROR: gh pr view $PR failed" >&2; exit 1; }

# --- run the fresh-context review ------------------------------------------
MODEL_OPTS=()
[ -n "$MODEL" ] && MODEL_OPTS=(--model "$MODEL")
review_payload() {
    printf '%s\n\n--- PR ---\n%s\n\n--- DIFF ---\n%s\n' "$(cat "$SKILL")" "$BODY" "$DIFF"
}
if [ "$REVIEW_CMD" = "codex" ]; then
    # Capture only the final answer: progress/tool output must not be parsed
    # as a verdict. A review has no reason to write to the project checkout.
    REVIEW_FILE="$(mktemp -t swarm-review-XXXXXX)"
    trap 'rm -f "$REVIEW_FILE"' EXIT
    if ! review_payload | codex exec "${MODEL_OPTS[@]}" --sandbox read-only \
            -c 'approval_policy="never"' --output-last-message "$REVIEW_FILE" - >&2; then
        echo "ERROR: codex exec review invocation failed" >&2
        exit 1
    fi
    REVIEW="$(cat "$REVIEW_FILE")"
else
    # ANTHROPIC_API_KEY, when set, outranks the claude.ai login. Optionally
    # drop it for this call (#673).
    CLAUDE_ENV=()
    [ "${SELF_REVIEW_UNSET_API_KEY:-0}" = "1" ] && CLAUDE_ENV=(env -u ANTHROPIC_API_KEY)
    # `claude -p` reports API errors on stdout, so keep REVIEW on failure and
    # show it instead of discarding it (#673).
    #
    # Read-only (issue #599): the review gets only Read/Grep/Glob plus three
    # git/gh read prefixes, and `dontAsk` denies everything else instead of
    # prompting, so it can neither write files nor run a test suite (46 of
    # 356 fand-etl reviews ran suites; one wrote a probe test into the
    # worker's worktree). It runs from a scratch dir so stray output cannot
    # land in a worktree; the repo is readable via --add-dir. GH_REPO keeps
    # `gh pr diff` working from there.
    SCRATCH="$(mktemp -d -t swarm-review-scratch-XXXXXX)"
    trap 'rm -rf "$SCRATCH"' EXIT
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    : "${GH_REPO:=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
    [ -z "$GH_REPO" ] || export GH_REPO
    READONLY_OPTS=(--tools "Read,Grep,Glob,Bash"
        --allowedTools "Read" "Grep" "Glob" "Bash(gh pr diff:*)" "Bash(git log:*)" "Bash(git show:*)"
        --permission-mode dontAsk --add-dir "$REPO_ROOT")
    if REVIEW="$(review_payload \
            | (cd "$SCRATCH" && "${CLAUDE_ENV[@]}" claude -p "${MODEL_OPTS[@]}" --no-chrome "${READONLY_OPTS[@]}"))"; then
        :
    else
        echo "--- claude -p output (last 20 lines) ---" >&2
        printf '%s\n' "$REVIEW" | tail -n 20 >&2
        echo "---" >&2
        if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ "${SELF_REVIEW_UNSET_API_KEY:-0}" != "1" ]; then
            echo "NOTE: ANTHROPIC_API_KEY is set, so the review ran on API-key auth, not the claude.ai login. Retry with: env -u ANTHROPIC_API_KEY (or SELF_REVIEW_UNSET_API_KEY=1)." >&2
        fi
        echo "ERROR: claude -p review invocation failed" >&2
        exit 1
    fi
fi

# The review session sometimes wraps the verdict token in markdown
# (backticks, bold, a code fence) despite the skill prompt's "no markdown"
# instruction — strip leading wrapping before matching so a good verdict
# isn't misread as unparseable (#213). Trailing wrapping is harmless: the
# case patterns below match with arbitrary suffixes.
VERDICT_LINE="$(printf '%s\n' "$REVIEW" \
    | sed 's/^[[:space:]`*]*//' \
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
    # With a known head, the (head, actor) no-op above already decided; only an
    # unreadable head falls back to "any marker blocks the post" (issue #599:
    # otherwise a worker marker would stop the coordinator's first post).
    if [ "$FORCE" = "0" ] && [ -z "$HEAD_SHA" ] && gh pr view "$PR" --json comments \
            --jq '.comments[].body' 2>/dev/null | grep -q 'SWARM_SELF_REVIEW:'; then
        echo "post: skipped — PR #$PR already has a SWARM_SELF_REVIEW comment (--force to re-post)"
    else
        # actor=<ACTOR> (issue #601): scripts/pr-ready.sh's round cap reads
        # this attribute to exclude coordinator-/operator-run rounds from
        # the WORKER's own budget — see this script's --actor header
        # comment. Always present (not just when non-default) so a
        # consumer never has to treat a missing attribute as implicitly
        # "worker"; the one exception is every marker posted before this
        # change, which pr-ready.sh's own query still treats as a worker
        # round for the same reason.
        COMMENT="$(printf '<!-- SWARM_SELF_REVIEW: %s actor=%s head=%s -->\n## Fresh-context self-review\n\n%s\n\n<sub>Adversarial review by a fresh %s session against prompts/skill-self-review.md — no shared context with the PR author. Machinery: scripts/self-review-pr.sh (docs/ringer-adoptions.md #2).</sub>\n' \
            "$VERDICT" "$ACTOR" "${HEAD_SHA:-unknown}" "$REVIEW" "$REVIEW_CMD")"
        gh pr comment "$PR" --body "$COMMENT" \
            || { echo "ERROR: gh pr comment failed" >&2; exit 1; }
        echo "post: verdict comment added to PR #$PR"
    fi
fi

exit "$EXIT"
