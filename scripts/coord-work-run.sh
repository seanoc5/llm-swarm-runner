#!/usr/bin/env bash
#
# coord-work-run.sh — run ONE short, non-interactive coordinator work run
# (issue #765, ADR 0006 sections 3 and 5).
#
# Why: with COORD_MODE=split the watcher wakes the coordinator by starting a
# process, not by typing into a chat. This wrapper is that process's launcher:
# it makes sure only one run is going, keeps the output, bounds time and
# spend, and leaves one usage line per run.
#
# Usage: coord-work-run.sh <project-dir> <prompt-text>
#
# Exit codes:
#   75  another run holds the lock; nothing was started (EX_TEMPFAIL)
#   else the run's own status: 0 ok, 124 timed out, 143 killed by TERM
#
# What it does, in order:
#   1. flock -n on <project>/.swarm/work-run.lock (single-flight). The lock fd
#      is closed for the child, and the kernel drops the lock when this
#      process dies for any reason, so a killed run cannot leave it held.
#   2. Stamps <project>/.swarm/work-run/last-start (epoch of the start, minus
#      one second so an item written in the same second is still "newer").
#      The watcher reads it as the "last ring" for batching.
#   3. Runs the command under `timeout`, output teed to
#      <project>/.swarm/work-run/<UTC-ts>.log.
#   2b. Writes <project>/.swarm/work-run/retry-from ("<epoch> <runs in a row not
#      yet ok>") before the run; an "ok" run removes it. A run that dies any
#      other way leaves it, and the watcher retries the inbox items from that
#      epoch after a back-off, up to a cap.
#   4. Appends one line to <project>/.swarm/work-run/runs.log:
#      <end-ts> start=<ts> secs=<n> exit=<rc> status=<ok|timeout|killed|error>
#      cost_usd=<x> in=<n> out=<n> cache_read=<n> log=<file>
#      (the cost and token fields are read from the stream-json result line
#      and are "-" when the command printed none).
#
# Env (caller-set values win; project .swarm/.env is loaded):
#   COORD_WORK_RUN_CMD          command line to run INSTEAD of claude (tests,
#                               other backends); runs via `bash -c` in the
#                               project dir with the prompt as "$1"
#   COORD_WORK_RUN_TIMEOUT_SECS hard limit per run (default 1800)
#   COORD_WORK_RUN_BUDGET_USD   claude --max-budget-usd (default 5)
#   COORD_WORK_PROMPT_FILE      single system prompt file used INSTEAD of the
#                               default (default: render-coordinator-prompt.sh
#                               work = coordinator-work.md + coordinator-shared.md);
#                               {{LLM_SWARM_DIR}} is substituted
#   COORD_MODEL                 model id or alias (default opus)
#   COORDINATOR_USE_API_KEY=1   keep ANTHROPIC_API_KEY (default: stripped so
#                               Max OAuth is used, as coordinator-claude.sh)

set -uo pipefail

PROJECT_DIR="${1:?usage: coord-work-run.sh <project-dir> <prompt-text>}"
PROMPT="${2:?usage: coord-work-run.sh <project-dir> <prompt-text>}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

TIMEOUT_SECS="${COORD_WORK_RUN_TIMEOUT_SECS:-1800}"
BUDGET_USD="${COORD_WORK_RUN_BUDGET_USD:-5}"
[[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]] && [ "$TIMEOUT_SECS" -gt 0 ] || TIMEOUT_SECS=1800

SWARM="$PROJECT_DIR/.swarm"
RUN_DIR="$SWARM/work-run"
LOCK="$SWARM/work-run.lock"
mkdir -p "$RUN_DIR" || exit 1

exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
    echo "coord-work-run: another work run holds $LOCK" >&2
    exit 75
fi

START_EPOCH="$(date +%s)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$RUN_DIR/$TS.log"
# A second run in the same second must not share a log file.
[ -e "$LOG" ] && LOG="$RUN_DIR/$TS-$$.log"
: > "$LOG"
PREV_LAST=0
read -r PREV_LAST _ 2>/dev/null < "$RUN_DIR/last-start" || PREV_LAST=0
[[ "$PREV_LAST" =~ ^[0-9]+$ ]] || PREV_LAST=0
printf '%s\n' "$((START_EPOCH - 1))" > "$RUN_DIR/last-start"
# last-start now says the inbox up to here is announced. Record the unfinished
# window BEFORE the run, so a run that never reaches finish() (SIGKILL, host
# restart, the watcher's group kill) is still retried: retry-from is "<epoch the
# window starts> <consecutive runs not yet known to be ok>", kept across
# failures at its oldest start, and removed by an ok run.
RF_FROM=$PREV_LAST RF_N=0
read -r RF_FROM RF_N _ 2>/dev/null < "$RUN_DIR/retry-from" || { RF_FROM=$PREV_LAST; RF_N=0; }
[[ "$RF_FROM" =~ ^[0-9]+$ ]] || RF_FROM=$PREV_LAST
[[ "$RF_N" =~ ^[0-9]+$ ]] || RF_N=0
printf '%s %s\n' "$RF_FROM" "$((RF_N + 1))" > "$RUN_DIR/retry-from"

SYS_FILE=""
CHILD_PID=""
STATUS_OVERRIDE=""
RC=0

finish() {
    local end_epoch secs status cost in_t out_t cache_t line
    end_epoch="$(date +%s)"
    secs=$((end_epoch - START_EPOCH))
    case "${STATUS_OVERRIDE:-}" in
        "") case "$RC" in
                0) status=ok ;;
                124) status=timeout ;;
                *) status=error ;;
            esac ;;
        *) status="$STATUS_OVERRIDE" ;;
    esac
    cost="-" in_t="-" out_t="-" cache_t="-"
    if command -v jq >/dev/null 2>&1; then
        line="$(grep -F '"type":"result"' "$LOG" 2>/dev/null | tail -n 1)"
        if [ -n "$line" ]; then
            # claude -p can report a failed run (budget, API error) in the
            # result line and still exit 0: that is not an ok run.
            if [ "$status" = ok ] && [ "$(printf '%s' "$line" | jq -r '.is_error // false' 2>/dev/null)" = true ]; then
                status=error
            fi
            cost="$(printf '%s' "$line" | jq -r '.total_cost_usd // "-"' 2>/dev/null || echo -)"
            in_t="$(printf '%s' "$line" | jq -r '.usage.input_tokens // "-"' 2>/dev/null || echo -)"
            out_t="$(printf '%s' "$line" | jq -r '.usage.output_tokens // "-"' 2>/dev/null || echo -)"
            cache_t="$(printf '%s' "$line" | jq -r '.usage.cache_read_input_tokens // "-"' 2>/dev/null || echo -)"
        fi
    fi
    printf '%s start=%s secs=%s exit=%s status=%s cost_usd=%s in=%s out=%s cache_read=%s log=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TS" "$secs" "$RC" "$status" \
        "$cost" "$in_t" "$out_t" "$cache_t" "$(basename "$LOG")" >> "$RUN_DIR/runs.log"
    # An ok run clears the retry marker written at the start; anything else
    # leaves it for the watcher's back-off retry.
    [ "$status" = ok ] && rm -f "$RUN_DIR/retry-from"
    [ -n "$SYS_FILE" ] && rm -f "$SYS_FILE"
    [ -n "${FIFO_DIR:-}" ] && rm -rf "$FIFO_DIR"
    return 0
}

# TERM/INT on the wrapper: stop the child, log the run as killed, release the
# lock by exiting. (SIGKILL cannot be trapped; the kernel still drops the lock
# and the run simply has no usage line.)
on_signal() {
    STATUS_OVERRIDE=killed
    RC=143
    if [ -n "$CHILD_PID" ]; then
        # `timeout` forwards a TERM to its own process group (the command and
        # everything it started); escalate to KILL on that group if it lingers.
        kill -TERM "$CHILD_PID" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$CHILD_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL -- "-$CHILD_PID" 2>/dev/null
        wait "$CHILD_PID" 2>/dev/null
    fi
    finish
    exit 143
}
trap on_signal TERM INT HUP

cd "$PROJECT_DIR" || exit 1

if [ -n "${COORD_WORK_RUN_CMD:-}" ]; then
    CMD=(bash -c "$COORD_WORK_RUN_CMD" coord-work-run "$PROMPT")
else
    SYS_FILE="$(mktemp -t coord-work-prompt-XXXXXX.md)" || exit 1
    if [ -n "${COORD_WORK_PROMPT_FILE:-}" ]; then
        sed "s|{{LLM_SWARM_DIR}}|$LLM_SWARM_DIR|g" "$COORD_WORK_PROMPT_FILE" > "$SYS_FILE" || exit 1
    else
        # work prompt + the shared rules (no send-keys, report grammar, verdicts)
        LLM_SWARM_DIR="$LLM_SWARM_DIR" "$SCRIPT_DIR/render-coordinator-prompt.sh" work > "$SYS_FILE" || exit 1
    fi
    if [ "${COORDINATOR_USE_API_KEY:-0}" != "1" ]; then
        unset ANTHROPIC_API_KEY
    fi
    # Foreground-only, as for the resident coordinator (#301/#383): a run that
    # detaches a shell would outlive the lock's meaning.
    [ "${COORDINATOR_ALLOW_BACKGROUND_TASKS:-0}" = "1" ] || export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
    CMD=(claude -p --model "${COORD_MODEL:-opus}"
         --append-system-prompt-file "$SYS_FILE"
         --dangerously-skip-permissions
         --output-format stream-json --verbose
         --max-budget-usd "$BUDGET_USD"
         "$PROMPT")
fi

# The child must not inherit the lock fd (9): a stray grandchild would
# otherwise keep the lock after the run is over. `timeout` moves itself into a
# process group of its own (pgid == its pid) and forwards a TERM it receives to
# that whole group, so on_signal only needs to signal `timeout` itself;
# --kill-after reaps a child that ignores the TERM. Output goes through a
# fifo so CHILD_PID is timeout's own pid (a pipeline would hide it).
FIFO_DIR="$(mktemp -d -t coord-work-fifo-XXXXXX)" || exit 1
mkfifo "$FIFO_DIR/out" || exit 1
tee -a "$LOG" < "$FIFO_DIR/out" 9>&- &
TEE_PID=$!
timeout --kill-after=30 "$TIMEOUT_SECS" "${CMD[@]}" 9>&- > "$FIFO_DIR/out" 2>&1 &
CHILD_PID=$!
wait "$CHILD_PID"
RC=$?
# Let tee drain what the command printed before the usage line is read, but do
# not wait on an orphan that still holds the pipe open.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$TEE_PID" 2>/dev/null || break
    sleep 0.3
done
CHILD_PID=""
rm -rf "$FIFO_DIR"
finish
exit "$RC"
