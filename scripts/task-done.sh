#!/usr/bin/env bash
#
# task-done.sh — the worker's own "this task is finished" declaration.
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
# every task (prompts/worker.md § "Task completion"). coordinator-watch.sh
# no longer creates completion records at all — see its
# reconcile_missing_outcome(), which only logs (watch.reconcile).
#
# This record is PROVISIONAL, not final, whenever a check is coming:
# worker-listener.sh's write_outcome() — called unconditionally after the
# dispatched process exits and the project's acceptance check (if any) has
# run — is still the sole authority on ok vs err, and RECONCILES whatever
# this script already wrote (removing it first if the real outcome differs
# — see write_outcome's own stale-record cleanup) rather than leaving it
# as final. This script's job is narrower than "decide the outcome": (a)
# empty processing/ immediately, so a reap never mistakes your
# already-finished task for an abandoned brief (the false-alarm half of
# #450 finding 3), and (b) unblock the coordinator's wake right away for a
# dispatch that may not exit for a long time — not to override an executed
# check. Pass the outcome you actually believe right now; if a check later
# disagrees, worker-listener.sh corrects the record for you.
#
# What it does, atomically:
#   1. mv .swarm/tasks/processing/<task-id>.md  ->  .swarm/tasks/done/
#   2. write .swarm/tasks/done/<task-id>.<ok|err>.json (mktemp+mv, so the
#      coordinator's inotify/poll backend only ever sees a finished file —
#      same technique every other writer in this queue protocol uses)
#
# Idempotent: if an outcome record for <task-id> already exists, this is a
# no-op (exit 0, one line to stderr) — safe to call more than once.
#
# Self-correcting against a wrong <task-id>: if it doesn't match anything
# in processing/ but exactly one real brief is sitting there, that one is
# used instead (with a warning) rather than silently producing a second,
# wrong-id completion record — see the self-review-finding comment below.
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

# issue #451 self-review finding: prefer worker-listener.sh's own exported
# worktree path over `git rev-parse --show-toplevel` — the latter is
# cwd-dependent, so calling this from a scratch clone made mid-task
# (without cd'ing back to the actual worktree first) would silently write
# the completion record into the WRONG repo, with no error and no
# indication anything went wrong. $SWARM_WORKTREE_DIR is always the
# worktree this task was actually dispatched into, regardless of what the
# current shell's cwd happens to be right now. Only falls back to
# `git rev-parse` when that env var isn't set at all (a caller not
# dispatched by worker-listener.sh, e.g. manual testing) — never silently
# ignored just because it doesn't look like a valid worktree right now, so
# a stale/wrong value still surfaces as a clear error rather than quietly
# resolving to some OTHER directory's git root instead.
if [ -n "${SWARM_WORKTREE_DIR:-}" ]; then
    REPO_ROOT="$SWARM_WORKTREE_DIR"
    [ -d "$REPO_ROOT/.git" ] || [ -f "$REPO_ROOT/.git" ] || {
        echo "task-done.sh: \$SWARM_WORKTREE_DIR ($REPO_ROOT) is not a git worktree" >&2
        exit 1
    }
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "task-done.sh: not inside a git worktree (run this from your task's worktree)" >&2
        exit 1
    }
fi
QUEUE_ROOT="$REPO_ROOT/.swarm/tasks"
PROCESSING="$QUEUE_ROOT/processing"
DONE="$QUEUE_ROOT/done"
mkdir -p "$DONE"

BRIEF="$PROCESSING/${TASK_ID}.md"

# issue #451 self-review finding: a worker that mis-derives its own
# task_id (the same #370 drift coordinator-watch.sh's
# worker_current_task_terminal() already documents seeing in the wild —
# a status file written under one name next to a processing/ brief
# actually claimed under another) would otherwise write its completion
# record under a name nothing else recognizes: the real brief never
# leaves processing/ (the SWARM_BRIEF_ORPHANED false alarm this PR exists
# to fix would persist for it), and worker-listener.sh's own later write
# — which always knows the CORRECT task_id, derived from
# claim_next_task()'s own inbox filename, independent of whatever gets
# passed here — produces a SECOND record under a DIFFERENT id. Exactly
# the duplicate-record problem this whole issue removes, just relocated
# from the coordinator side to here.
#
# When the given task_id doesn't match anything in processing/ but
# EXACTLY ONE real (non-tmp) file is actually sitting there, trust THAT
# file over the possibly-wrong argument — same "the filesystem is more
# trustworthy than a self-report" principle worker_current_task_terminal's
# own #370 fallback already applies. Ambiguous cases (processing/ empty,
# or more than one file — shouldn't normally happen, since a worktree
# only ever has one task claimed at a time) are left alone: proceed with
# the given task_id as before, tolerating a missing brief (see below).
if [ ! -f "$BRIEF" ]; then
    REAL_BRIEFS="$(find "$PROCESSING" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null || true)"
    if [ -n "$REAL_BRIEFS" ] && [ "$(printf '%s\n' "$REAL_BRIEFS" | wc -l)" -eq 1 ]; then
        REAL_TASK_ID="$(basename "$REAL_BRIEFS" .md)"
        echo "task-done.sh: WARNING: processing/${TASK_ID}.md not found, but processing/$(basename "$REAL_BRIEFS") is — using task_id=$REAL_TASK_ID instead (you passed the wrong task_id; use the exact inbox filename, per prompts/worker.md)" >&2
        TASK_ID="$REAL_TASK_ID"
        BRIEF="$REAL_BRIEFS"
    fi
fi

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
# still being gone (worker-listener.sh's own fallback path, or a legacy
# v1 task with no processing/<id>.md at all) — the outcome record below is
# what actually matters.
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
