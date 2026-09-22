#!/usr/bin/env bash
#
# task-done.sh — the ONE place a worker declares "this task is finished."
#
# Usage:
#   task-done.sh <task-id> <ok|err> [reason]
#
# issue #451 (α of #450): before this script existed, FIVE independent
# places could each decide a task was "done" and write their own
# .swarm/tasks/done/<id>.{ok,err}.json — worker-listener.sh's own
# exit-triggered write (only reachable once the dispatched agent process
# actually exits), plus coordinator-watch.sh's WATCH_SYNTH_OUTCOME
# synthesis, its PR-poll fallback (task_id="pr-issue-$issue"), and its
# status-file fast path. An interactive worker (this one, most of the
# time — dispatch_agent's non-headless claude invocation blocks in a live
# REPL until a human types /quit, which never happens on its own) never
# makes worker-listener.sh's own write fire, so the coordinator started
# fabricating a stand-in outcome the moment it saw OTHER done-ish signals
# (a ready-for-review status file, a PR appearing) — the same real
# completion then got recorded 2-3x under different task ids (see #450's
# corpusminder #708 case: four separate ok.json files over 15 minutes for
# one finish).
#
# Now: the worker calls THIS script itself, as the mandatory last step of
# every task (prompts/worker.md § "Task completion"). It is the single
# authoritative writer. worker-listener.sh's own exit-triggered write
# becomes a backstop for workers that forget (or a v1/pre-#451 worktree
# that predates this script — see MIGRATION below) and no-ops if this
# script already ran. coordinator-watch.sh no longer creates completion
# records at all — see coordinator-watch.sh's reconcile_missing_outcome().
#
# What it does, atomically:
#   1. mv .swarm/tasks/processing/<task-id>.md  ->  .swarm/tasks/done/
#   2. write .swarm/tasks/done/<task-id>.<ok|err>.json (mktemp+mv, so the
#      coordinator's inotify/poll backend only ever sees a finished file —
#      same technique every other writer in this queue protocol uses)
#
# Idempotent: if an outcome record for <task-id> already exists, this is a
# no-op (exit 0, one line to stderr) — safe to call more than once, and
# safe to call after worker-listener.sh's own fallback write already ran
# (e.g. a headless dispatch that finished before the worker got here).
#
# MIGRATION (v1/older worktrees without this script): a worktree
# provisioned before issue #451 landed has no scripts/task-done.sh of its
# own, but every worker invocation this project's swarm dispatches runs
# with $LLM_SWARM_DIR pointed at the swarm tooling checkout (see
# worker-listener.sh's WORKER_MD injection) — call it as
# "$LLM_SWARM_DIR/scripts/task-done.sh", never a bare relative path, and
# it works regardless of which project worktree you're standing in. There
# is no per-worktree copy to go stale. A worker running under a genuinely
# pre-#451 $LLM_SWARM_DIR (the swarm tooling itself not yet updated) has
# no such script to call at all; it falls back to the pre-#451 behavior
# (worker-listener.sh's exit-triggered write is the only completion
# record, and the coordinator's status/PR-poll signals just log
# watch.reconcile with no synthesized record and no wake) — degraded, not
# wedged: the task still finishes correctly, it just doesn't wake the
# coordinator until the agent process actually exits. Update
# $LLM_SWARM_DIR to pick up this script.
set -euo pipefail

usage() {
    echo "Usage: task-done.sh <task-id> <ok|err> [reason]" >&2
    exit 2
}

TASK_ID="${1:-}"
OUTCOME="${2:-}"
REASON="${3:-}"
[ -n "$TASK_ID" ] || usage
case "$OUTCOME" in
    ok|err) ;;
    *) usage ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "task-done.sh: not inside a git worktree (run this from your task's worktree)" >&2
    exit 1
}
QUEUE_ROOT="$REPO_ROOT/.swarm/tasks"
PROCESSING="$QUEUE_ROOT/processing"
DONE="$QUEUE_ROOT/done"
mkdir -p "$DONE"

OK_FILE="$DONE/${TASK_ID}.ok.json"
ERR_FILE="$DONE/${TASK_ID}.err.json"

# Duplicate suppression (issue #451 acceptance: "a reconciler — or a second
# call — seeing an existing done record does nothing"). Whichever outcome
# was recorded first wins; this script never overwrites one outcome with
# another for the same task_id.
if [ -e "$OK_FILE" ] || [ -e "$ERR_FILE" ]; then
    echo "task-done.sh: outcome already recorded for task_id=$TASK_ID — no-op" >&2
    exit 0
fi

# Move the claimed brief out of processing/ so a reap sees an empty
# processing/ dir (the false-alarm half of #450 finding 3: kill-worktree.sh
# salvages + posts SWARM_BRIEF_ORPHANED whenever processing/ is non-empty
# at reap time — which used to be EVERY interactive worker, since nothing
# ever emptied it before the agent process exited). Tolerate the brief
# already being gone (worker-listener.sh's own fallback path, or a legacy
# v1 task with no processing/<id>.md at all) — the outcome record below is
# what actually matters.
BRIEF="$PROCESSING/${TASK_ID}.md"
if [ -f "$BRIEF" ]; then
    mv "$BRIEF" "$DONE/${TASK_ID}.md"
fi

FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXIT_CODE=0
[ "$OUTCOME" = "err" ] && EXIT_CODE=1

REASON_JSON="null"
if [ -n "$REASON" ]; then
    if command -v jq >/dev/null 2>&1; then
        REASON_JSON="$(printf '%s' "$REASON" | jq -Rs .)"
    else
        REASON_JSON="\"$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    fi
fi

TMP="$(mktemp "$DONE/.tmp.task-done-XXXXXX")"
cat > "$TMP" <<EOF
{
  "task_id": "$TASK_ID",
  "started": null,
  "finished": "$FINISHED",
  "duration_seconds": null,
  "exit_code": $EXIT_CODE,
  "outcome": "$OUTCOME",
  "reason": $REASON_JSON,
  "agent": null,
  "model": null,
  "headless": false,
  "check_cmd": null,
  "check_exit": null,
  "check_output_tail": null,
  "retried": false,
  "source": "task-done.sh"
}
EOF
TARGET="$DONE/${TASK_ID}.${OUTCOME}.json"
mv "$TMP" "$TARGET"
echo "task-done.sh: wrote $TARGET"
