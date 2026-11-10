#!/usr/bin/env bash
#
# queue-merge-brief.sh — carry the operator's `merge PR N <rating>` to the
# worker that owns the PR, waking it if it is on hold (issue #841).
#
# Why: worker-merge.sh runs inside the worker sandbox, so a 🔴 PR was merged by
# typing the phrase in the worker's own window. A worker on hold
# (sideline-worker.sh, #622) has no window, so the PR was stranded. Here the
# operator types the phrase in the coordinator's conversation session, which
# runs this script. It queues a merge brief in the worker's inbox; for a
# sidelined worker coordinator-watch.sh wakes it through
# `provision-worker.sh --wake` (caps and host admission apply), and the worker
# runs worker-merge.sh with every gate as before.
#
# Usage:
#   queue-merge-brief.sh <PR#> --rating low|medium|high [--expect-head <sha>]
#                        [--project DIR]
#
# The approval is bound to a head SHA. Without --expect-head the head is read
# NOW, when the operator's phrase arrives, so a push after this point voids the
# approval (worker-merge.sh refuses on a moved head; it never re-reads it).
# With --expect-head the sha must already be the PR's head, else nothing is
# queued.
#
# Refuses (exit 2, nothing queued) when: the PR is not OPEN or is a draft; its
# body lacks <!-- BLIND_MERGE_RISK: <rating> --> for the rating typed; no
# worktree of this project owns the PR's branch. Exit 1: usage / gh error.
# Exit 5 or 7 are requeue.sh's (identical brief already pending / lock timeout).
#
# Only the coordinator conversation session may call this, and only for a
# phrase the operator typed in that session (prompts/coordinator-chat.md).
# Test hooks: REQUEUE_SCRIPT, LIST_WORKTREES_SCRIPT.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUEUE_SCRIPT="${REQUEUE_SCRIPT:-$SCRIPT_DIR/requeue.sh}"
LIST_WORKTREES_SCRIPT="${LIST_WORKTREES_SCRIPT:-$SCRIPT_DIR/list-own-worktrees.sh}"

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
refuse() { echo "queue-merge-brief: REFUSED — $*" >&2; exit 2; }

PR="" RATING="" EXPECT="" PROJECT="$PWD"
while [ $# -gt 0 ]; do
    case "$1" in
        --rating) RATING="${2:-}"; shift 2 ;;
        --rating=*) RATING="${1#*=}"; shift ;;
        --expect-head) EXPECT="${2:-}"; shift 2 ;;
        --expect-head=*) EXPECT="${1#*=}"; shift ;;
        --project) PROJECT="${2:-}"; shift 2 ;;
        --project=*) PROJECT="${1#*=}"; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "queue-merge-brief: unknown option $1" >&2; usage ;;
        *) [ -z "$PR" ] || usage; PR="$1"; shift ;;
    esac
done
[[ "$PR" =~ ^[0-9]+$ ]] || usage
case "$RATING" in low|medium|high) ;; *) echo "queue-merge-brief: --rating must be low, medium or high" >&2; usage ;; esac
[ -z "$EXPECT" ] || [[ "$EXPECT" =~ ^[0-9a-fA-F]{7,40}$ ]] || { echo "queue-merge-brief: --expect-head needs >=7 hex chars" >&2; usage; }
[ -d "$PROJECT" ] || { echo "queue-merge-brief: no such project dir $PROJECT" >&2; exit 1; }
PROJECT="$(cd "$PROJECT" && pwd)"
command -v gh >/dev/null 2>&1 || { echo "queue-merge-brief: gh required" >&2; exit 1; }

INFO="$(cd "$PROJECT" && gh pr view "$PR" --json state,isDraft,headRefName,headRefOid,body,title)" \
    || { echo "queue-merge-brief: gh pr view $PR failed" >&2; exit 1; }
jqv() { printf '%s' "$INFO" | jq -r "$1"; }
[ "$(jqv .state)" = "OPEN" ] || refuse "PR #$PR is $(jqv .state), not OPEN."
[ "$(jqv .isDraft)" = "false" ] || refuse "PR #$PR is a draft."
jqv .body | grep -F "<!-- BLIND_MERGE_RISK: $RATING -->" >/dev/null \
    || refuse "PR #$PR is not rated $RATING (<!-- BLIND_MERGE_RISK: $RATING --> missing). Re-read the rating and ask the operator again."
HEAD="$(jqv .headRefOid)"
BRANCH="$(jqv .headRefName)"
TITLE="$(jqv .title)"
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo "queue-merge-brief: could not read the PR head" >&2; exit 1; }
if [ -n "$EXPECT" ]; then
    case "$HEAD" in
        "$(printf '%s' "$EXPECT" | tr 'A-F' 'a-f')"*) ;;
        *) refuse "PR #$PR head is ${HEAD:0:12}, not $EXPECT. New commits since the approval; ask again." ;;
    esac
fi
SHORT="${HEAD:0:12}"

# The worktree whose checked-out branch is the PR's head branch.
WT=""
while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$(git -C "$d" branch --show-current 2>/dev/null)" = "$BRANCH" ]; then WT="$d"; break; fi
done < <("$LIST_WORKTREES_SCRIPT" "$PROJECT" 2>/dev/null)
[ -n "$WT" ] || refuse "no worker worktree of this project is on branch '$BRANCH' (PR #$PR). Nothing to carry the approval to; the operator merges from a shell with swarm-merge.sh."

STATE_NOTE="live"
[ -e "$WT/.swarm/sidelined" ] && STATE_NOTE="on hold (the watcher wakes it)"

BRIEF="$(mktemp -t merge-brief.XXXXXX)"
trap 'rm -f "$BRIEF"' EXIT
cat > "$BRIEF" <<EOF
<!-- SWARM_MERGE_APPROVAL: pr=$PR rating=$RATING head=$SHORT -->
# Merge approval for PR #$PR (${TITLE})

The operator typed \`merge PR $PR$([ "$RATING" = high ] && echo " red")\` in the coordinator's conversation session, and the swarm's own
\`queue-merge-brief.sh\` queued this brief. It counts as the operator's approval for exactly
this PR, rating **$RATING** and head **$SHORT**. It is not a relay.

Do this and nothing else:

\`\`\`bash
\$LLM_SWARM_DIR/scripts/worker-merge.sh $PR --expect-head $SHORT --rating $RATING
\`\`\`

- Skip the usual start-of-task rebase and push nothing: a push would void this approval.
- Do not re-read the head and retry with a newer SHA. If the script refuses (moved head, wrong rating,
  BLOCK, migration collision, red CI), report the gate in your handoff and stop: the operator re-approves.
- Write your status file and run task-done.sh as usual; the handoff names the merge result.
EOF

OUT="$("$REQUEUE_SCRIPT" "$WT" "$BRIEF" 2>&1)"; rc=$?
printf '%s\n' "$OUT"
[ "$rc" -eq 0 ] || exit "$rc"
printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" merge.queued \
    "pr=$PR rating=$RATING head=$SHORT worker=$STATE_NOTE" >> "$PROJECT/.swarm/events.log" 2>/dev/null || true
echo "queue-merge-brief: queued merge approval for PR #$PR ($RATING, head $SHORT); worker is $STATE_NOTE."
