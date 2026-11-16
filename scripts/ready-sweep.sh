#!/usr/bin/env bash
#
# ready-sweep.sh — re-run pr-ready.sh on parked PRs (a draft, or a PR labelled
# swarm-hold:ci since #612) that were refused only
# because CI wasn't readable or finished yet (issue #602).
#
# pr-ready.sh writes a `<!-- SWARM_DRAFT_REASON: <reason> sha=<sha> -->`
# banner into the PR body when it refuses. Workers usually exit right after
# that refusal, so a draft whose CI goes green a minute later used to sit
# until a human noticed (fand-app #1533/#1534, 2026-10-10). This picks up
# the open drafts whose reason is ci-pending or ci-unknown and retries them.
# review-block and ci-failing need a fix first, so they are not retried
# (ci-failing is reported instead; see issue #729 below).
#
# The ci-pending/ci-unknown retry costs no extra self-review round: pr-ready.sh skips review when
# the banner's sha= still matches the head commit. Run from inside the
# target repo's checkout (gh resolves the repo from cwd).
#
# issue #635: also reports stale waits. A draft (held PRs are drafts too)
# whose `**Next:**` line says `waiting on #N merges` (or "to merge"; same
# repo only, a bare #N) gets #N looked up; if #N already merged, this prints
# a stale-wait line and coordinator-watch.sh turns it into one coord-inbox
# note. fand-etl #1477 sat 16h "waiting" on a PR that had merged 10h before
# the handoff was written. WATCH_STALE_WAIT_CHECK=0 turns this part off.
#
# issue #757: also reports banner-less green drafts ("parked-green" lines; see below).
#
# Usage: ready-sweep.sh [--dry-run]
# Output: one line per candidate: "#<N> <reason>: readied|still draft (exit <rc>)"
#   ("still draft" is historic wording, kept because parsers match it: it means "not readied"),
#   plus "#<P> stale-wait: waiting on #<N>, which merged at <ts>" per stale wait.
# Exit: 0 (per-PR refusals are normal); 1 if `gh pr list` itself fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_ci-fallback.sh
. "$SCRIPT_DIR/_ci-fallback.sh"
# shellcheck source=_hold-label.sh
. "$SCRIPT_DIR/_hold-label.sh"
PR_READY="${PR_READY_SCRIPT:-$SCRIPT_DIR/pr-ready.sh}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# issue #612: draft now means only "worker still writing"; a PR pr-ready.sh
# refused is un-drafted and carries a swarm-hold:* label plus its banner. So the
# sweep reads ALL open PRs (named DRAFTS for the old reason: it is still the
# set of parked PRs) and each check below picks drafts, labelled PRs or both:
# the banner-driven checks (retry, ci-failing, ci-cancelled) fit either state,
# which also keeps PRs parked as drafts before #612 working.
DRAFTS="$(gh pr list --state open --limit 100 --json number,body,headRefOid,headRefName,statusCheckRollup,isDraft,labels)" \
    || { echo "ready-sweep: ERROR: gh pr list failed" >&2; exit 1; }
CANDIDATES="$(jq -r '.[] | (.body // "" | capture("(?m)^<!-- SWARM_DRAFT_REASON: (?<r>ci-pending|ci-unknown) sha=").r) as $r | "\(.number) \($r)"' <<<"$DRAFTS")"

# issue #984: a PR left carrying ONLY swarm-hold:ci with no banner and CI green
# on the live head. Typical path: a fix push re-added the label (CI pending),
# the CI-green retry hit pr-ready.sh's exit 3 because a coordinator hold was on,
# and the hold-lift (comment, banner, label removal) never re-ran pr-ready.sh,
# so swarm-merge.sh refused until someone removed the label by hand. Retry it.
# Guards: the label set is exactly {swarm-hold:ci} (any coordinator / operator /
# review / bare hold label means someone else owns the PR), no COORDINATOR HOLD
# banner and no SWARM_DRAFT_REASON banner (those have their own paths above), and
# every newest-per-check run is SUCCESS/NEUTRAL/SKIPPED with at least one check,
# so the label is never touched while CI is pending or red. pr-ready.sh stays the
# only thing that removes it (it re-checks CI and the hold itself).
CI_HOLD_GREEN="$(jq -r "$CI_ROLLUP_DROP_LIVENESS_JQ"'.[]
  | select([(.labels // [])[] | (.name // "") | select(test("^swarm-hold(:.*)?$"))] == ["swarm-hold:ci"])
  | select((.body // "") | (test("<!-- SWARM_DRAFT_REASON:") or test("(?m)^> ⛔ \\*\\*COORDINATOR HOLD\\*\\*")) | not)
  | (.statusCheckRollup // []
     | ci_real
     | group_by((.workflowName // "") + "\u0000" + (.name // .context // ""))
     | map(max_by(.completedAt // .startedAt // .createdAt // ""))) as $r
  | select(($r | length) > 0 and all($r[]; ((.status // "COMPLETED") == "COMPLETED")
        and (((.conclusion // .state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$")))))
  | "\(.number) ci-hold-green \(.headRefOid // "nohead")"' <<<"$DRAFTS")"
if [ -n "$CI_HOLD_GREEN" ]; then
    CANDIDATES="$(printf '%s\n%s' "$CANDIDATES" "$CI_HOLD_GREEN" | sed '/^$/d')"
fi

# issue #729: a parked PR whose CI went red has no live owner (its worker ended
# after writing an fyi note), so report it; coordinator-watch.sh turns the line
# into one inbox note per (PR, sha). The banner proves only ITS OWN sha failed:
#  - head == banner sha: report ci-failing with that sha.
#  - head moved (a fix push): the banner says nothing about the new head, so do
#    a read-only `gh pr checks` of the live head. Red: report with the LIVE sha.
#    Pending, green or unknown: say nothing. pr-ready.sh is never called for
#    these PRs: it would run a full self-review per sweep (no timeout, spends
#    worker rounds) and never rewrites a held draft's banner. Cost: a green fix
#    push on a parked draft waits until someone re-runs pr-ready.sh.
# A missing headRefOid counts as "head unchanged". Reporting is read-only, so
# --dry-run reports it too.
FAILING="$(jq -r '.[] | (.body // "" | capture("(?m)^<!-- SWARM_DRAFT_REASON: ci-failing sha=(?<s>[0-9a-fA-F]+)").s // empty) as $s | (.headRefOid // $s) as $h | if $h == $s then "\(.number) \($s) report" else "\(.number) \($h) check" end' <<<"$DRAFTS")"
while read -r pr sha action; do
    [ -n "$pr" ] || continue
    if [ "$action" = "check" ]; then
        # exit 1 = a check failed, but a token that cannot read Checks also
        # exits 1; require an actual `fail` row (tab-separated off a TTY).
        # ci_pr_checks drops the swarm/worker liveness status (a dead worker's
        # failure is not red CI, #536) and sets CHECKS_OUT / CHECKS_RC.
        ci_pr_checks "$pr"; rc="$CHECKS_RC"; out="$CHECKS_OUT"
        if ! { [ "$rc" = "1" ] && grep -Eq '[[:space:]]fail[[:space:]]' <<<"$out"; }; then
            # issue #739: say the head was not (verifiably) red, so the watcher keeps its
            # one-note-per-sha key across a failed read or a CI re-run instead of pruning it.
            echo "#$pr ci-failing-unconfirmed: live head not verifiably red (sha=$sha)"
            continue
        fi
    fi
    echo "#$pr ci-failing: needs a fix push (sha=$sha)"
done <<<"$FAILING"

# issue #808: a draft parked as ci-cancelled (runner offline, queued runs
# cancelled after 24h; #793) needs a CI re-run, not a fix push, so it gets its
# own line. Only while head == banner sha: a moved head means the banner says
# nothing about the new commit. Read-only, so --dry-run reports it too.
jq -r '.[] | (.body // "" | capture("(?m)^<!-- SWARM_DRAFT_REASON: ci-cancelled sha=(?<s>[0-9a-fA-F]+)").s // empty) as $s | select((.headRefOid // $s) == $s) | "#\(.number) ci-cancelled: CI was cancelled, re-run it (`gh run rerun <run-id>`), not a fix push (sha=\($s))"' <<<"$DRAFTS"

# issue #757: a worker that parks BEFORE ever calling pr-ready.sh leaves no
# banner, so the loop below never sees its draft (civicstrata #643 sat ~18h
# with green CI). Report open drafts with no SWARM_DRAFT_REASON banner, no
# COORDINATOR HOLD banner and green CI on the head (every newest-per-check
# run completed with SUCCESS/NEUTRAL/SKIPPED, at least one check). This is
# read-only: coordinator-watch.sh turns each line into one deduped inbox note
# per (PR, sha); nothing here or there readies the draft. The coordinator decides.
# Line: "#<N> parked-green: banner-less draft, green CI (risk=<r>, issue=<K>, sha=<S>)"
jq -r "$CI_ROLLUP_DROP_LIVENESS_JQ"'.[]
  | select(.isDraft == true)
  | select(('"$HOLD_LABEL_JQ_PRED"') | not)
  | select((.body // "") | (test("<!-- SWARM_DRAFT_REASON:") or test("(?m)^> ⛔ \\*\\*COORDINATOR HOLD\\*\\*")) | not)
  | (.statusCheckRollup // []
     | ci_real  # the swarm/worker liveness status is not CI (#536)
     | group_by((.workflowName // "") + "\u0000" + (.name // .context // ""))
     | map(max_by(.completedAt // .startedAt // .createdAt // ""))) as $r
  | select(($r | length) > 0 and all($r[]; ((.status // "COMPLETED") == "COMPLETED")
        and (((.conclusion // .state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$")))))
  | "#\(.number) parked-green: banner-less draft, green CI (risk=\((.body // "") | (capture("BLIND_MERGE_RISK: (?<r>low|medium|high)").r) // "unknown"), issue=\((.headRefName // "") | (capture("issue-(?<i>[0-9]+)").i) // "none"), sha=\(.headRefOid // "unknown"))"' <<<"$DRAFTS"

while read -r pr reason sha; do
    [ -n "$pr" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
        echo "#$pr $reason: would retry (dry run)"
        continue
    fi
    reuse=0
    if [ "$reason" = "ci-hold-green" ]; then
        # issue #984 cost guard: bannerless, so pr-ready.sh cannot tell a retry from a
        # first run. One attempt per (PR, head sha), recorded BEFORE the call: a review
        # that outlives the timeout below posts nothing and would otherwise be restarted
        # (paid) every sweep. A new push (new sha) earns a new attempt.
        state_dir="${READY_SWEEP_STATE_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.swarm/ready-sweep-state}"
        mark="$state_dir/retry-$pr-${sha:-nohead}"
        if [ -e "$mark" ]; then
            echo "#$pr $reason: still draft (retry already spent on ${sha:0:7}; push or remove the label by hand)"
            continue
        fi
        mkdir -p "$state_dir" 2>/dev/null || true
        : > "$mark" 2>/dev/null || true
        reuse=1
    fi
    rc=0
    PR_READY_REUSE_REVIEW="$reuse" timeout "${READY_SWEEP_PR_READY_TIMEOUT:-300}" "$PR_READY" "$pr" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "0" ]; then
        echo "#$pr $reason: readied"
    else
        echo "#$pr $reason: still draft (exit $rc)"
    fi
done <<<"$CANDIDATES"

[ "${WATCH_STALE_WAIT_CHECK:-1}" = "0" ] && exit 0

# "<pr> <trigger>" for each Next line naming a same-repo merge trigger.
WAITS="$(jq -r '.[] | select(.isDraft == true or ('"$HOLD_LABEL_JQ_PRED"')) | .number as $p | (.body // "") | [scan("(?m)^(?:> ?)?\\*\\*Next:\\*\\*[^\\n]*waiting on #(?<n>[0-9]+)(?: to)? merg")[0]] | unique[] | "\($p) \(.)"' <<<"$DRAFTS")"
while read -r pr trig; do
    [ -n "$pr" ] || continue
    # A failed lookup is silent: the next sweep retries it.
    merged_at="$(gh pr view "$trig" --json state,mergedAt --jq 'select(.state == "MERGED") | .mergedAt' 2>/dev/null || true)"
    if [ -n "$merged_at" ]; then
        echo "#$pr stale-wait: waiting on #$trig, which merged at $merged_at"
    fi
done <<<"$WAITS"
exit 0
