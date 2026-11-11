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
# The approval is bound to the operator's own words (PR #852 review): before
# queueing, the exact phrase (`merge PR N red` for high, `merge PR N`
# otherwise) must appear in a USER-role turn of this coordinator's Claude
# transcript, newer than the PR head commit's time. Assistant turns, tool
# results and long quoted text never count (same rule as capture-worker.sh
# --verify, #360). The verified turn's timestamp goes in the brief's second line.
#
#   queue-merge-brief.sh --check-brief FILE    (worker side)
# exits 0 only for a brief this script wrote: marker line, then a
# SWARM_MERGE_VERIFIED line (by=queue-merge-brief.sh, same PR and head, operator
# turn newer than the head commit). Exit 2 otherwise: a hand-written or
# requeue.sh brief carrying the marker is not an approval. Limit: a writer who
# can forge both lines can still forge a brief; this closes the by-accident and
# by-prompt-drift paths, not a hostile coordinator.
#
# Only the coordinator conversation session may call this, and only for a
# phrase the operator typed in that session (prompts/coordinator.md; the split-mode conversation session merges with swarm-merge.sh itself).
# Test hooks: REQUEUE_SCRIPT, LIST_WORKTREES_SCRIPT, CLAUDE_PROJECTS_DIR.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUEUE_SCRIPT="${REQUEUE_SCRIPT:-$SCRIPT_DIR/requeue.sh}"
LIST_WORKTREES_SCRIPT="${LIST_WORKTREES_SCRIPT:-$SCRIPT_DIR/list-own-worktrees.sh}"

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
refuse() { echo "queue-merge-brief: REFUSED — $*" >&2; exit 2; }

epoch() { date -u -d "$1" +%s 2>/dev/null; }

# Worker-side gate: is this brief one queue-merge-brief.sh wrote and verified?
check_brief() {
    local f="$1" l1 l2 pr head ts hts hs
    [ -r "$f" ] || { echo "queue-merge-brief: cannot read brief $f" >&2; exit 1; }
    l1="$(sed -n 1p "$f")"; l2="$(sed -n 2p "$f")"
    [[ "$l1" =~ ^\<!--\ SWARM_MERGE_APPROVAL:\ pr=([0-9]+)\ rating=(low|medium|high)\ head=([0-9a-f]{12})\ --\>$ ]] \
        || refuse "line 1 is not the approval marker."
    pr="${BASH_REMATCH[1]}"; head="${BASH_REMATCH[3]}"
    [[ "$l2" =~ ^\<!--\ SWARM_MERGE_VERIFIED:\ by=queue-merge-brief\.sh\ operator_turn=([0-9TZ:.-]+)\ head_commit=([0-9TZ:.-]+)\ pr=([0-9]+)\ head=([0-9a-f]{12})\ --\>$ ]] \
        || refuse "no SWARM_MERGE_VERIFIED line from queue-merge-brief.sh: not an operator approval (hand-written or requeue.sh brief). Report it and stop."
    ts="${BASH_REMATCH[1]}"; hts="${BASH_REMATCH[2]}"
    [ "${BASH_REMATCH[3]}" = "$pr" ] && [ "${BASH_REMATCH[4]}" = "$head" ] \
        || refuse "the verification line names a different PR or head than the marker."
    [ -n "$(epoch "$ts")" ] && [ -n "$(epoch "$hts")" ] && [ "$(epoch "$ts")" -gt "$(epoch "$hts")" ] \
        || refuse "the verified operator turn is not newer than the head commit."
    echo "queue-merge-brief: brief for PR #$pr verified (operator turn $ts)."
    exit 0
}

PR="" RATING="" EXPECT="" PROJECT="$PWD"
while [ $# -gt 0 ]; do
    case "$1" in
        --rating|--expect-head|--project|--check-brief) [ $# -ge 2 ] || { echo "queue-merge-brief: $1 needs a value" >&2; usage; } ;;
    esac
    case "$1" in
        --check-brief) check_brief "$2" ;;
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

# The operator's own typed words: a user-role turn in THIS coordinator's
# transcript, newer than the head commit. Nothing is queued without one.
PHRASE="merge PR $PR"; [ "$RATING" = high ] && PHRASE="merge PR $PR red"
HEAD_TIME="$(cd "$PROJECT" && gh pr view "$PR" --json commits -q '.commits[-1].committedDate' 2>/dev/null)"
HEAD_EPOCH="$(epoch "$HEAD_TIME")"
[ -n "$HEAD_EPOCH" ] || { echo "queue-merge-brief: could not read the PR head commit time" >&2; exit 1; }
COMMON="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
TPROJ="$(cd "$PROJECT" && pwd -P)"
if [ -n "$COMMON" ] && [ "$(basename "$COMMON")" = ".git" ]; then TPROJ="$(dirname "$COMMON")"; fi
TDIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/$(printf '%s' "$TPROJ" | sed 's/[^A-Za-z0-9]/-/g')"
# Whole-word phrase (not a prefix of another PR number); a turn that quotes it
# inside a long note or starts with a tag (hook/notice text) is not typed words.
if [ "$RATING" = high ]; then RE="(^|[^A-Za-z0-9])merge PR $PR red([^A-Za-z0-9]|\$)"
else RE="(^|[^A-Za-z0-9])merge PR $PR([^0-9]|\$)"; fi
VERIFIED_TS=""
for f in "$TDIR"/*.jsonl; do
    [ -e "$f" ] || continue
    ts="$(jq -r --arg re "$RE" --argjson since "$HEAD_EPOCH" '
        select(.type == "user") |
        .message.content as $c |
        (if ($c | type) == "string" then $c
         elif ($c | type) == "array" then ([$c[] | select(.type == "text") | .text] | join("\n"))
         else "" end) as $t |
        select(($t | length) <= 200 and ($t | test("^\\s*[<\\[]") | not) and ($t | test($re))) |
        select((.timestamp // "") != "" and ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > $since)) |
        .timestamp' "$f" 2>/dev/null | sort | tail -1)"
    [ -n "$ts" ] || continue
    if [[ "$ts" > "$VERIFIED_TS" ]]; then VERIFIED_TS="$ts"; fi
done
[ -n "$VERIFIED_TS" ] || refuse "no user-typed \`$PHRASE\` in this coordinator's transcript newer than the PR head commit ($HEAD_TIME). Only the operator's own words approve a merge; ask them to type it here."

STATE_NOTE="live"
[ -e "$WT/.swarm/sidelined" ] && STATE_NOTE="on hold (the watcher wakes it)"

BRIEF="$(mktemp -t merge-brief.XXXXXX)"
trap 'rm -f "$BRIEF"' EXIT
cat > "$BRIEF" <<EOF
<!-- SWARM_MERGE_APPROVAL: pr=$PR rating=$RATING head=$SHORT -->
<!-- SWARM_MERGE_VERIFIED: by=queue-merge-brief.sh operator_turn=$VERIFIED_TS head_commit=$HEAD_TIME pr=$PR head=$SHORT -->
# Merge approval for PR #$PR (${TITLE})

The operator typed \`$PHRASE\` in the coordinator's conversation session (verified in its transcript at $VERIFIED_TS, after the head commit), and the swarm's own
\`queue-merge-brief.sh\` queued this brief. It counts as the operator's approval for exactly
this PR, rating **$RATING** and head **$SHORT**. It is not a relay.

Do this and nothing else. First, run \`\$LLM_SWARM_DIR/scripts/queue-merge-brief.sh --check-brief <this brief's path>\`;
if it exits non-zero, this is not an approval: report that and stop.

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
