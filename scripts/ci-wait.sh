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
#   ci-wait.sh <PR#> [timeout-seconds] [--repo <owner/repo>]
#
#   --repo   target a PR in a different repo than the current directory's
#            (passed straight through to every `gh` call below; issue #473
#            "also noticed" — a worker's first call on fand-etl PR #1063
#            used --repo and hit "line 67: repo: unbound variable" because
#            the flag didn't exist yet).
#
# issue #596: a job whose `if:`/`needs:` makes it conditional on an earlier
# job in the SAME workflow run (e.g. a "detect changes" job gating a
# downstream "Integration" job) can take real wall-clock MINUTES — not
# seconds — to even become eligible to run, if the runner it needs is busy
# (corpusminder-spring's self-hosted runner serves five repos). A poll that
# lands anywhere in that window sees only the already-finished, already-
# green jobs — "all CURRENTLY KNOWN checks are green" is indistinguishable
# from "every check that will ever exist for this commit is green" from a
# single `gh pr checks` snapshot. corpusminder-spring PR #1126 (run
# 37944084110) is exactly this race: Fast finished 14:27:50, `--auto-low`
# merged at 14:32:02 with only Fast's check visible, Detect didn't even
# START until 14:39:16, and Integration (which `needs: [detect]`) ran
# 14:43:14-14:53:54 and failed. A time-based "wait N seconds and then trust
# it" guard was considered and rejected: the real gap here was over 11
# minutes, so any fixed settle short enough to not slow down every ordinary
# merge would have been too short to have caught this actual incident.
#
# What actually distinguishes "really done" from "looks done so far" is the
# workflow RUN's own top-level status, which GitHub does not flip to
# "completed" until every job in that run's DAG — however many there turn
# out to be, however late a conditional one registers — has reached a
# terminal state. That signal is already computed by
# ci_fallback_run_state() (the same helper this script already uses when
# `gh pr checks` is unreadable at all) from `gh run list --commit`, which
# needs only Actions:read — permission this script already requires for
# its fallback path, so cross-checking with it costs nothing new. So a
# `gh pr checks` exit 0 is now a candidate, not a verdict: it's confirmed
# against ci_fallback_run_state before ci-wait.sh will actually exit 0, and
# an unconfirmed (still-running, or uncheckable) run is treated as pending,
# same as any other in-progress check — it keeps polling, and times out
# (refuses) rather than merging on it. At 14:32:02 in the real incident,
# `gh run list` for this commit shows exactly this: one run, status
# "in_progress" (it stayed that way until 14:53:55) — the cross-check
# would have kept Gate 2 waiting right through it.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ci-fallback.sh
. "$SCRIPT_DIR/_ci-fallback.sh"

USAGE="Usage: $0 <PR#> [timeout-seconds] [--repo <owner/repo>]"

PR=""
TIMEOUT_ARG=""
REPO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            shift
            REPO="${1:-}"
            [ -n "$REPO" ] || { echo "$USAGE" >&2; exit 4; }
            ;;
        --repo=*) REPO="${1#--repo=}" ;;
        -h|--help) echo "$USAGE"; exit 0 ;;
        -*) echo "ci-wait: ERROR: unknown flag '$1'" >&2; echo "$USAGE" >&2; exit 4 ;;
        *)
            if [ -z "$PR" ]; then
                PR="$1"
            elif [ -z "$TIMEOUT_ARG" ]; then
                TIMEOUT_ARG="$1"
            else
                echo "ci-wait: ERROR: too many arguments" >&2; echo "$USAGE" >&2; exit 4
            fi
            ;;
    esac
    shift
done

[ -n "$PR" ] || { echo "$USAGE" >&2; exit 4; }
TIMEOUT="${TIMEOUT_ARG:-${CI_WAIT_TIMEOUT_SECONDS:-900}}"
POLL="${CI_WAIT_POLL_SECONDS:-15}"

REPO_ARGS=()
API_REPO_PATH="repos/{owner}/{repo}"
if [ -n "$REPO" ]; then
    REPO_ARGS=(--repo "$REPO")
    API_REPO_PATH="repos/$REPO"
fi

MERGE_JSON="$(gh pr view "$PR" "${REPO_ARGS[@]}" --json mergeable,mergeStateStatus,headRefOid 2>&1)" \
    || { echo "ci-wait: gh pr view $PR failed: $MERGE_JSON" >&2; exit 4; }

MERGEABLE="$(jq -r '.mergeable' <<<"$MERGE_JSON")"
MERGE_STATE="$(jq -r '.mergeStateStatus' <<<"$MERGE_JSON")"
SHA="$(jq -r '.headRefOid' <<<"$MERGE_JSON")"

# GitHub computes mergeability asynchronously — a fresh push can read back
# UNKNOWN for a few seconds. One short retry before trusting it.
if [ "$MERGEABLE" = "UNKNOWN" ]; then
    sleep 3
    MERGE_JSON="$(gh pr view "$PR" "${REPO_ARGS[@]}" --json mergeable,mergeStateStatus,headRefOid 2>&1)" \
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
    PASS_NOW=0
    PASS_MSG=""

    if [ "$FALLBACK" != "1" ]; then
        set +e
        CHECKS_OUT="$(gh pr checks "$PR" "${REPO_ARGS[@]}" 2>&1)"
        CHECKS_RC=$?
        set -e

        if ci_fallback_is_token_error "$CHECKS_OUT"; then
            FALLBACK=1
            echo "ci-wait: gh pr checks is not readable by this token (fine-grained PATs have no Checks permission) — falling back to polling gh run list --commit ${SHA:0:12} for PR #$PR." >&2
        fi
    fi

    if [ "$FALLBACK" = "1" ]; then
        # --limit 100: gh run list defaults to 20, which on a commit with
        # many re-runs could drop a workflow's newest run before
        # ci_fallback_run_state's own dedup ever sees it. The dedup-by-
        # workflow, stdout/stderr-separation and conclusion-mapping logic
        # all live in _ci-fallback.sh now (shared with pr-ready.sh, #560),
        # not duplicated here.
        if ! ci_fallback_run_state "$SHA" "${REPO_ARGS[@]}"; then
            echo "ci-wait: $CI_FALLBACK_DETAIL" >&2
            exit 4
        fi
        case "$CI_FALLBACK_STATE" in
            pass) PASS_NOW=1; PASS_MSG="PR #$PR checks green (via Actions-runs fallback)." ;;
            fail)
                echo "ci-wait: PR #$PR has failing checks (via Actions-runs fallback):" >&2
                echo "$CI_FALLBACK_DETAIL" >&2
                exit 1 ;;
            pending) : ;; # fall through to deadline/sleep below
        esac
    else
        case "$CHECKS_RC" in
            0)
                # issue #596: don't trust "every check gh pr checks currently
                # knows about is green" as "this commit's CI is really done" —
                # cross-check against the run-level signal (ci_fallback_run_state,
                # the same helper used on the fallback path below), which GitHub
                # only reports non-pending once every job in the run's DAG has
                # reached a terminal state, however late a conditional one
                # registers.
                if ci_fallback_run_state "$SHA" "${REPO_ARGS[@]}"; then
                    case "$CI_FALLBACK_STATE" in
                        pass) PASS_NOW=1; PASS_MSG="PR #$PR checks green." ;;
                        pending)
                            echo "ci-wait: gh pr checks shows every currently-known check on PR #$PR green, but the workflow run itself is still in progress (a later job — e.g. one gated on an earlier job's output — hasn't registered its check yet). Treating as pending." >&2
                            ;;
                        fail)
                            echo "ci-wait: PR #$PR's workflow run concluded with a failure gh pr checks' per-check view hadn't caught up to (via Actions-runs cross-check):" >&2
                            echo "$CI_FALLBACK_DETAIL" >&2
                            exit 1
                            ;;
                    esac
                else
                    echo "ci-wait: gh pr checks shows PR #$PR green, but the run-level cross-check failed ($CI_FALLBACK_DETAIL) — not trusting a bare green reading without it. Treating as pending." >&2
                fi
                ;;
            1)
                if grep -qi "no checks reported" <<<"$CHECKS_OUT"; then
                    if [ -z "$WORKFLOW_COUNT" ]; then
                        WORKFLOW_COUNT="$(gh api "$API_REPO_PATH/actions/workflows" --jq '.total_count' 2>/dev/null || true)"
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

    if [ "$PASS_NOW" = "1" ]; then
        echo "ci-wait: $PASS_MSG"
        exit 0
    fi

    NOW=$(date -u +%s)
    [ "$NOW" -lt "$DEADLINE" ] || {
        echo "ci-wait: timed out after ${TIMEOUT}s waiting on PR #$PR (still pending)." >&2
        exit 2
    }
    sleep "$POLL"
done
