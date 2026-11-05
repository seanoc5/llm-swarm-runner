#!/usr/bin/env bash
#
# ready-sweep.sh — re-run pr-ready.sh on drafts that were refused only
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
# The retry costs no extra self-review round: pr-ready.sh skips review when
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
# Output: one line per candidate: "#<N> <reason>: readied|still draft (exit <rc>)",
#   plus "#<P> stale-wait: waiting on #<N>, which merged at <ts>" per stale wait.
# Exit: 0 (per-PR refusals are normal); 1 if `gh pr list` itself fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_READY="${PR_READY_SCRIPT:-$SCRIPT_DIR/pr-ready.sh}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

DRAFTS="$(gh pr list --state open --draft --limit 100 --json number,body,headRefOid,headRefName,statusCheckRollup)" \
    || { echo "ready-sweep: ERROR: gh pr list failed" >&2; exit 1; }
CANDIDATES="$(jq -r '.[] | (.body // "" | capture("(?m)^<!-- SWARM_DRAFT_REASON: (?<r>ci-pending|ci-unknown) sha=").r) as $r | "\(.number) \($r)"' <<<"$DRAFTS")"

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
        rc=0; out="$(gh pr checks "$pr" 2>&1)" || rc=$?
        { [ "$rc" = "1" ] && grep -Eq '[[:space:]]fail[[:space:]]' <<<"$out"; } || continue
    fi
    echo "#$pr ci-failing: needs a fix push (sha=$sha)"
done <<<"$FAILING"

# issue #757: a worker that parks BEFORE ever calling pr-ready.sh leaves no
# banner, so the loop below never sees its draft (civicstrata #643 sat ~18h
# with green CI). Report open drafts with no SWARM_DRAFT_REASON banner, no
# COORDINATOR HOLD banner and green CI on the head (every newest-per-check
# run completed with SUCCESS/NEUTRAL/SKIPPED, at least one check). This is
# read-only: coordinator-watch.sh turns each line into one deduped inbox note
# per (PR, sha); nothing here or there readies the draft. The coordinator decides.
# Line: "#<N> parked-green: banner-less draft, green CI (risk=<r>, issue=<K>, sha=<S>)"
jq -r '.[]
  | select((.body // "") | (test("<!-- SWARM_DRAFT_REASON:") or test("(?m)^> ⛔ \\*\\*COORDINATOR HOLD\\*\\*")) | not)
  | (.statusCheckRollup // []
     | group_by((.workflowName // "") + "\u0000" + (.name // .context // ""))
     | map(max_by(.completedAt // .startedAt // .createdAt // ""))) as $r
  | select(($r | length) > 0 and all($r[]; ((.status // "COMPLETED") == "COMPLETED")
        and (((.conclusion // .state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$")))))
  | "#\(.number) parked-green: banner-less draft, green CI (risk=\((.body // "") | (capture("BLIND_MERGE_RISK: (?<r>low|medium|high)").r) // "unknown"), issue=\((.headRefName // "") | (capture("issue-(?<i>[0-9]+)").i) // "none"), sha=\(.headRefOid // "unknown"))"' <<<"$DRAFTS"

while read -r pr reason; do
    [ -n "$pr" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
        echo "#$pr $reason: would retry (dry run)"
        continue
    fi
    rc=0
    timeout "${READY_SWEEP_PR_READY_TIMEOUT:-300}" "$PR_READY" "$pr" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "0" ]; then
        echo "#$pr $reason: readied"
    else
        echo "#$pr $reason: still draft (exit $rc)"
    fi
done <<<"$CANDIDATES"

[ "${WATCH_STALE_WAIT_CHECK:-1}" = "0" ] && exit 0

# "<pr> <trigger>" for each Next line naming a same-repo merge trigger.
WAITS="$(jq -r '.[] | .number as $p | (.body // "") | [scan("(?m)^(?:> ?)?\\*\\*Next:\\*\\*[^\\n]*waiting on #(?<n>[0-9]+)(?: to)? merg")[0]] | unique[] | "\($p) \(.)"' <<<"$DRAFTS")"
while read -r pr trig; do
    [ -n "$pr" ] || continue
    # A failed lookup is silent: the next sweep retries it.
    merged_at="$(gh pr view "$trig" --json state,mergedAt --jq 'select(.state == "MERGED") | .mergedAt' 2>/dev/null || true)"
    if [ -n "$merged_at" ]; then
        echo "#$pr stale-wait: waiting on #$trig, which merged at $merged_at"
    fi
done <<<"$WAITS"
exit 0
