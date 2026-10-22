# shellcheck shell=bash
#
# _conflict-brief.sh — the one resolve-conflicts brief, shared by
# swarm-merge.sh (merge attempt on a conflicting PR, #649) and
# coordinator-watch.sh (a ready PR turned conflicting, #656).
#
# queue_conflict_brief <wt_dir> <pr> <base> <detail> <found_by>
#   <found_by> is the sentence's subject: what noticed the conflict, e.g.
#   "`swarm-merge.sh` refused PR #12" or "The watcher saw PR #12 turn
#   conflicting".
# Returns 0 when it queued a brief, 2 when one is already queued or claimed
# (marker match in inbox/ or processing/), 1 when requeue.sh failed.
# Prints the existing brief's path on rc 2.

CONFLICT_BRIEF_MARKER="swarm-merge:conflict-brief"

conflict_brief_pending() {  # <wt_dir> <pr>
    grep -l "$CONFLICT_BRIEF_MARKER pr=$2 " \
        "$1"/.swarm/tasks/inbox/*.md "$1"/.swarm/tasks/processing/*.md 2>/dev/null | head -1
}

queue_conflict_brief() {
    local wt="$1" pr="$2" base="$3" detail="$4" found_by="$5" existing
    existing="$(conflict_brief_pending "$wt" "$pr" || true)"
    if [ -n "$existing" ]; then
        printf '%s\n' "$existing"
        return 2
    fi
    "$(dirname "${BASH_SOURCE[0]}")/requeue.sh" "$wt" - <<EOF || return 1
<!-- $CONFLICT_BRIEF_MARKER pr=$pr -->
# Resolve merge conflicts on PR #$pr

$found_by: it conflicts with \`origin/$base\` ($detail).

1. \`git fetch origin\` and rebase this branch onto \`origin/$base\`.
2. Resolve each conflict, keeping both sides' intent. A conflict you can't
   resolve mechanically: stop and raise a \`## Decision\`.
3. Run the fast tier, then \`git push --force-with-lease\`.
4. Post a short PR comment headed \`## Conflict notes\`, written so the
   operator can learn to read conflicts: per file, what \`$base\` changed
   and what this branch changed (plain words, one line each), what you
   kept, and why. Five to ten lines total. End it with "— drafted by claude".
5. \`ci-wait.sh $pr\` until green. Don't merge — the operator re-runs
   \`swarm-merge.sh $pr\`.
EOF
}
