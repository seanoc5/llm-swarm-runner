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
# review-block and ci-failing need a fix first, so they are left alone.
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
# Usage: ready-sweep.sh [--dry-run]
# Output: one line per candidate: "#<N> <reason>: readied|still draft (exit <rc>)",
#   plus "#<P> stale-wait: waiting on #<N>, which merged at <ts>" per stale wait.
# Exit: 0 (per-PR refusals are normal); 1 if `gh pr list` itself fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_READY="${PR_READY_SCRIPT:-$SCRIPT_DIR/pr-ready.sh}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

DRAFTS="$(gh pr list --state open --draft --limit 100 --json number,body)" \
    || { echo "ready-sweep: ERROR: gh pr list failed" >&2; exit 1; }
CANDIDATES="$(jq -r '.[] | (.body // "" | capture("(?m)^<!-- SWARM_DRAFT_REASON: (?<r>ci-pending|ci-unknown) sha=").r) as $r | "\(.number) \($r)"' <<<"$DRAFTS")"

while read -r pr reason; do
    [ -n "$pr" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
        echo "#$pr $reason: would retry (dry run)"
        continue
    fi
    rc=0
    "$PR_READY" "$pr" >/dev/null 2>&1 || rc=$?
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
