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
#                    self-review-pr.sh exit 1 -> refuses to ready, exit 2
#                      (fail CLOSED, issue #446: self-review-pr.sh's own exit
#                      1 conflates a genuine gh/claude infra failure with an
#                      UNPARSEABLE VERDICT — a real BLOCK the review session
#                      failed to emit in the exact expected form. This
#                      script can't tell those two apart from the exit code
#                      alone, and a swallowed BLOCK is worse than an
#                      inconvenient refusal, so both now block readying the
#                      same as an explicit BLOCK — printed loudly, not
#                      swallowed, per worker.md's "never silently bypass the
#                      layer". Inspect the review output above, then either
#                      fix the real finding or re-run once the infra issue
#                      clears.)
#   missing/unparseable BLIND_MERGE_RISK marker: treated as medium (fail
#                      toward requiring review)
#
# issue #473: before calling self-review-pr.sh at all, counts the
# `SWARM_SELF_REVIEW` marker comments already posted on the PR (one per
# prior round — self-review-pr.sh --post --force always adds a fresh
# comment, never edits one in place). Once that count reaches
# WORKER_SELF_REVIEW_MAX_ROUNDS (default 3), this script stops calling
# self-review-pr.sh — the fand-etl PR #1063 incident (2026-09-25/26) ran ~15
# rounds over 2h15m for 23 mostly-cosmetic follow-up commits with no stop
# condition. The worker is expected to fold any remaining findings into the
# PR body's `## Follow-up suggestions` block instead of chasing them with
# more commits (prompts/worker.md § "Self-review before merge"). 0 disables
# self-review entirely, same effect as WORKER_SELF_REVIEW=0. Capping the
# round does NOT skip the gate: it still checks the latest already-posted
# verdict and refuses (exit 2, same as a fresh BLOCK) if that verdict is
# BLOCK — a PR capped right after a BLOCK round must not ready unreviewed
# (self-review finding on this script's first version of the cap).
#
# issue #473: also requires CI to be observed green (or absent) on the PR's
# head commit immediately before `gh pr ready` runs — a single `gh pr
# checks` snapshot, taken here rather than trusted from anything the worker
# says earlier in its own transcript. The same fand-etl PR #1063 was marked
# ready with `lint-and-test` failing (4 ruff errors) while the PR body
# claimed "CI is green". Pending checks or failures refuse readying (exit
# 4); no checks configured at all is a pass-with-warning, consistent with
# ci-wait.sh's own exit 5 and swarm-merge.sh's Gate 2.
#
# issue #534: a PR the coordinator drafted as a hold (draft-as-hold,
# `prompts/coordinator.md` § "Draft-as-hold") carries a
# `> ⛔ **COORDINATOR HOLD**` banner in its body. Un-drafting that PR
# defeats the hold even when self-review comes back clean, so a held PR
# still gets its self-review posted (same rubric as above) but is never
# un-drafted here — only the coordinator lifts the hold.
#
# issue #560: `gh pr checks` exit 1 for "Resource not accessible by
# personal access token" (a fine-grained PAT has Actions:read but no Checks
# permission) was previously indistinguishable from a genuine failing-CI
# exit 1, so a green PR behind such a token got refused as "failing CI
# checks" and stuck as a draft. That exact text is now recognized (shared
# detector in `_ci-fallback.sh`, also used by ci-wait.sh) and routed to the
# same `gh run list --commit` Actions-runs fallback ci-wait.sh already uses
# (#513/#540) instead of being read as red. If that fallback ALSO can't
# decide (`gh run list` itself fails), this refuses with a distinct exit
# code (5) and message ("can't read CI status") rather than reusing exit 4's
# "failing CI checks" wording — the two mean different things: one is a
# confirmed red, the other is "no token can tell you right now".
#
# Exit codes:
#   0  readied (gh pr ready ran)
#   2  refused — self-review returned BLOCK, or self-review-pr.sh exited 1
#      (infra failure or an unparseable verdict, indistinguishable from the
#      exit code alone — issue #446, treated as blocking either way)
#   3  held — a COORDINATOR HOLD banner is on the PR body; self-review ran
#      (and posted) as usual, but gh pr ready was deliberately skipped
#   4  refused — CI checks on the head commit are not confirmed green
#      (pending, failing, or an unexpected `gh pr checks` error; also a
#      confirmed red or still-pending result read via the Actions-runs
#      fallback)
#   5  refused — can't read CI status at all: the token lacks Checks
#      permission AND the Actions-runs fallback itself couldn't be read
#      either (`gh pr view` for the head SHA, or `gh run list`, failed).
#      Distinct from exit 4 on purpose — this means "unknown", not
#      "confirmed failing" (issue #560).
#   1  usage / gh error resolving the PR body
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"
# shellcheck source=_ci-fallback.sh
. "$SCRIPT_DIR/_ci-fallback.sh"
# Overridable for testing (a stub in place of the real self-review-pr.sh,
# which shells out to `claude -p` and can't be exercised in CI/tests).
SELF_REVIEW="${SELF_REVIEW_SCRIPT:-$SCRIPT_DIR/self-review-pr.sh}"

PR="${1:?usage: pr-ready.sh <PR#>}"
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required" >&2; exit 1; }

BODY="$(gh pr view "$PR" --json body --jq .body 2>/dev/null)" \
    || { echo "ERROR: gh pr view $PR failed" >&2; exit 1; }

RISK="$(grep -oE '<!-- BLIND_MERGE_RISK: (low|medium|high) -->' <<<"$BODY" \
    | head -1 | sed -E 's/.*: (low|medium|high) -->/\1/' || true)"

HELD=0
# Matches the literal draft-as-hold banner (prompts/coordinator.md): a
# blockquote line starting with the banner, anchored to line-start so a
# PR body that merely QUOTES or discusses the banner in running prose
# (e.g. this PR's own appendix, or an inline code span) doesn't also
# match and self-hold — only the real banner, which the coordinator
# always prepends as its own leading "> " line, does.
grep -qE '^> ⛔ \*\*COORDINATOR HOLD\*\*' <<<"$BODY" && HELD=1

case "$RISK" in
    low)
        echo "pr-ready: risk=low — self-review not required (worker.md rubric); readying"
        ;;
    medium|high|"")
        if [ -z "$RISK" ]; then
            echo "pr-ready: WARN: no BLIND_MERGE_RISK marker found on PR #$PR's body — treating as medium (fail toward requiring review)" >&2
            RISK="medium"
        fi
        MAX_ROUNDS="${WORKER_SELF_REVIEW_MAX_ROUNDS:-3}"
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
        elif [ "$MAX_ROUNDS" = "0" ]; then
            echo "pr-ready: self-review disabled (WORKER_SELF_REVIEW_MAX_ROUNDS=0) — readying anyway. Flag this in your handoff."
        else
            # Round count is read from the PR itself (prior SWARM_SELF_REVIEW
            # marker comments), not from this process's own memory — each
            # pr-ready.sh invocation is a fresh call from a worker that may
            # have retried across many separate commands in the same
            # conversation. A lookup failure (gh hiccup, unparseable count)
            # fails OPEN here (treated as round 0): the cap is a cost/time
            # guard, not a correctness gate — that's CI-green and BLOCK
            # below, which fail closed.
            ROUNDS_DONE="$(gh pr view "$PR" --json comments \
                --jq '[.comments[].body // "" | select(contains("SWARM_SELF_REVIEW:"))] | length' \
                2>/dev/null || true)"
            case "$ROUNDS_DONE" in
                ''|*[!0-9]*) ROUNDS_DONE=0 ;;
            esac
            if [ "$ROUNDS_DONE" -ge "$MAX_ROUNDS" ]; then
                echo "pr-ready: self-review round cap reached ($ROUNDS_DONE/$MAX_ROUNDS rounds already posted on PR #$PR, WORKER_SELF_REVIEW_MAX_ROUNDS=$MAX_ROUNDS) — not running another round."
                echo "          Move any remaining findings into the PR body's ## Follow-up suggestions block instead of another commit."
                # Skipping the round must not also skip the gate: check the
                # LATEST posted verdict (same capture pattern as
                # review-scoreboard.sh) so a PR capped right after a BLOCK
                # round still refuses instead of readying unreviewed
                # (self-review finding on this script's first version).
                LATEST_VERDICT="$(gh pr view "$PR" --json comments \
                    --jq '[.comments[].body // "" | select(contains("SWARM_SELF_REVIEW:")) | capture("SWARM_SELF_REVIEW: (?<v>APPROVE_WITH_CAVEATS|APPROVE|BLOCK)").v] | last // empty' \
                    2>/dev/null || true)"
                if [ "$LATEST_VERDICT" = "BLOCK" ]; then
                    echo "pr-ready: REFUSED — PR #$PR's latest self-review verdict is BLOCK and the round cap means no further round will run to clear it." >&2
                    echo "          Fix the finding, then either raise WORKER_SELF_REVIEW_MAX_ROUNDS for one more round, or get a human to ready it." >&2
                    exit 2
                fi
            else
            echo "pr-ready: risk=$RISK — running self-review (round $((ROUNDS_DONE + 1))/$MAX_ROUNDS: $SELF_REVIEW $PR --post --force)..."
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
                    # this call, instead. So anything landing here is exit 1:
                    # per self-review-pr.sh's own header, that's EITHER a
                    # genuine gh/claude infra failure OR an unparseable
                    # verdict — a real BLOCK the review session failed to
                    # emit in the exact expected form. issue #446
                    # self-review: fails CLOSED here instead of WARNing and
                    # readying anyway — an unparseable verdict could be
                    # hiding a real BLOCK, and this gate exists precisely
                    # for the ambiguous cases.
                    echo "pr-ready: REFUSED — self-review-pr.sh exited $rc for PR #$PR (infra failure or an unparseable verdict — can't tell which from the exit code, so treating it as blocking)." >&2
                    echo "          Inspect the review output above, then fix the finding or re-run once the infra issue has cleared." >&2
                    exit 2
                    ;;
            esac
            fi
        fi
        ;;
esac

if [ "$HELD" = "1" ]; then
    echo "pr-ready: PR #$PR carries a COORDINATOR HOLD banner — staying draft."
    echo "          Self-review above is posted, but only the coordinator lifts the hold and readies this PR."
    exit 3
fi

# issue #473: a single `gh pr checks` snapshot, taken fresh right here, so
# readying never relies on a CI status the worker merely remembers or
# assumed from earlier in its own session (fand-etl PR #1063: readied with
# `lint-and-test` failing while the PR body claimed CI was green).
echo "pr-ready: confirming CI status for PR #$PR before readying..."
set +e
CHECKS_OUT="$(gh pr checks "$PR" 2>&1)"
CHECKS_RC=$?
set -e
case "$CHECKS_RC" in
    0)
        echo "pr-ready: CI checks green on PR #$PR."
        ;;
    8)
        echo "pr-ready: REFUSED — PR #$PR's CI checks are still pending (gh pr checks exit 8)." >&2
        echo "          Run 'scripts/ci-wait.sh $PR' to wait for a real result, then re-run pr-ready.sh." >&2
        exit 4
        ;;
    1)
        if ci_fallback_is_token_error "$CHECKS_OUT"; then
            # Fine-grained PAT: `gh pr checks` can't read Checks at all, so
            # its exit 1 here is a permission error, not a CI result. Route
            # to the same `gh run list --commit` fallback ci-wait.sh uses
            # (#513/#540) instead of reading this as failing CI (#560).
            echo "pr-ready: gh pr checks is not readable by this token (fine-grained PATs have no Checks permission) — falling back to the Actions-runs check for PR #$PR." >&2
            SHA="$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null)" || SHA=""
            if [ -z "$SHA" ]; then
                echo "pr-ready: REFUSED — can't read CI status for PR #$PR: gh pr view failed while resolving the head commit for the Actions-runs fallback." >&2
                exit 5
            fi
            if ci_fallback_run_state "$SHA"; then
                case "$CI_FALLBACK_STATE" in
                    pass)
                        echo "pr-ready: CI checks green on PR #$PR (via Actions-runs fallback)."
                        ;;
                    fail)
                        echo "pr-ready: REFUSED — PR #$PR has failing CI checks (via Actions-runs fallback):" >&2
                        echo "$CI_FALLBACK_DETAIL" >&2
                        exit 4
                        ;;
                    pending)
                        echo "pr-ready: REFUSED — PR #$PR's CI checks are still pending (via Actions-runs fallback)." >&2
                        echo "          Run 'scripts/ci-wait.sh $PR' to wait for a real result, then re-run pr-ready.sh." >&2
                        exit 4
                        ;;
                    *)
                        # Self-review finding: ci_fallback_run_state is called
                        # as an `if` condition, so `set -e` is suspended for
                        # everything it runs — an unrecognized CI_FALLBACK_STATE
                        # (should be unreachable; ci_fallback_run_state's own
                        # jq query only ever produces pass/fail/pending on its
                        # success path) must still fail closed here instead of
                        # silently falling through this case and reaching
                        # `gh pr ready` with no CI verdict at all.
                        echo "pr-ready: REFUSED — can't read CI status for PR #$PR: the Actions-runs fallback returned an unrecognized state ('$CI_FALLBACK_STATE')." >&2
                        exit 5
                        ;;
                esac
            else
                echo "pr-ready: REFUSED — can't read CI status for PR #$PR: this token can't read Checks, and the Actions-runs fallback also failed ($CI_FALLBACK_DETAIL)." >&2
                echo "          This means unknown, not failing — get a human (or a token with Checks or Actions read) to confirm CI before readying." >&2
                exit 5
            fi
        elif grep -qi "no checks reported" <<<"$CHECKS_OUT"; then
            # issue #473 round-2 self-review: "no checks reported" also
            # covers the ordinary post-push race where CI IS configured but
            # this commit's run hasn't registered yet (ci-wait.sh's own
            # issue #452 comment) — trusting the message alone would let a
            # worker ready within seconds of pushing, before CI even
            # started, reopening the #1063 failure the CI gate exists to
            # close. Disambiguate the same way ci-wait.sh does: a workflow
            # count of 0 means there is really nothing to wait for; any
            # other count (including an unreadable one) means treat it as
            # still pending.
            WORKFLOW_COUNT="$(gh api 'repos/{owner}/{repo}/actions/workflows' --jq '.total_count' 2>/dev/null || true)"
            if [ "$WORKFLOW_COUNT" = "0" ]; then
                echo "pr-ready: WARN: PR #$PR has no CI checks configured on this repo at all (0 workflows) — proceeding." >&2
            else
                echo "pr-ready: REFUSED — PR #$PR reports 'no checks reported' but this repo has CI configured — this commit's run likely hasn't registered yet." >&2
                echo "          Run 'scripts/ci-wait.sh $PR' to wait for a real result, then re-run pr-ready.sh." >&2
                exit 4
            fi
        else
            echo "pr-ready: REFUSED — PR #$PR has failing CI checks:" >&2
            echo "$CHECKS_OUT" >&2
            exit 4
        fi
        ;;
    *)
        echo "pr-ready: REFUSED — gh pr checks $PR exited $CHECKS_RC (unexpected):" >&2
        echo "$CHECKS_OUT" >&2
        exit 4
        ;;
esac

echo "pr-ready: gh pr ready $PR"
gh pr ready "$PR"
