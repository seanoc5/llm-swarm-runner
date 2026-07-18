#!/usr/bin/env bash
#
# worker-listener.sh — Asynchronous queue watcher for worker agents.
#
# Runs inside a worktree sandbox. Watches the per-worktree task queue at
# `.swarm/tasks/inbox/`, claims one task at a time via atomic mv to
# `processing/`, dispatches to the configured LLM agent, then writes a
# structured outcome JSON to `done/`. Polls every 2 seconds.
#
# Queue protocol (v2 — recommended):
#   <wt>/.swarm/tasks/inbox/<id>.md       coordinator writes here (atomic
#                                         via mktemp+mv); listener reads
#   <wt>/.swarm/tasks/processing/<id>.md  listener mv on pickup (atomic claim)
#   <wt>/.swarm/tasks/done/<id>.md        listener mv when finished (audit trail)
#   <wt>/.swarm/tasks/done/<id>.{ok,err}.json
#                                         listener writes structured outcome
#                                         (started/finished/duration/exit_code/agent/model
#                                          + check_cmd/check_exit/check_output_tail)
#   <wt>/.swarm/tasks/done/<id>.check.log full acceptance-check output (audit)
#
# Coordinator polls done/*.json to know what happened (no need to scrape pane).
#
# Executed acceptance checks (v2 tasks only):
#   After the agent exits, the listener runs a per-issue acceptance check and
#   stamps the result into the outcome JSON. A task is only `outcome: ok` when
#   BOTH the agent exited 0 AND the check (if one resolved) exited 0 — an
#   agent declaring "done" is not proof; an executed check is.
#   Concept adopted from Nate B. Jones's ringer (see docs/ringer-adoptions.md
#   for attribution and pointers); implementation here is original.
#   Check command resolution order:
#     1. brief marker:  a `<!-- SWARM_CHECK: <cmd> -->` line in the task brief
#     2. worktree file: .swarm/check.sh (standing per-issue check)
#     3. env default:   WORKER_CHECK_CMD (listener-wide, e.g. project test suite)
#   No match → check skipped, check_* fields null (behavior identical to
#   pre-check versions). Kill switch: WORKER_CHECK=0. Timeout:
#   WORKER_CHECK_TIMEOUT seconds (default 600; timeout exit 124 = fail).
#   On check failure the agent is re-dispatched ONCE with the failure output
#   injected into the prompt, then the check re-runs (retry-once; disable
#   with WORKER_CHECK_RETRY=0). The first attempt's check output is kept at
#   done/<id>.check.attempt1.log and the outcome JSON records retried: true.
#
# Legacy single-file protocol (v1) — still supported for backward compat:
#   <wt>/.agent-task.md       drop a task brief here
#   <wt>/.agent-task-last.md  listener archives to here on pickup
#   (no structured outcome)
#
# Listener checks v2 queue first, falls back to v1 file. Both can be used.
#
# Mode (controlled by WORKER_HEADLESS env var):
#   default            — interactive. Agent runs the seeded prompt, then stays
#                        alive in REPL so an attached user can answer questions
#                        the agent asks. Exit with /quit (claude) or Ctrl-D.
#                        First run per worktree: claude prompts "Trust this
#                        folder? Y/n" — answer Y to proceed.
#   WORKER_HEADLESS=1  — agent runs with -p (claude) / -p (gemini) /
#                        codex exec, prints, and exits. Skips the trust
#                        dialog. Used by e2e tests and any automation where
#                        no human is attached.

AGENT="${1:-claude}"
MODEL="${WORKER_MODEL:-}"
HEADLESS="${WORKER_HEADLESS:-0}"
CHECK_ENABLED="${WORKER_CHECK:-1}"
CHECK_TIMEOUT="${WORKER_CHECK_TIMEOUT:-600}"
CHECK_RETRY="${WORKER_CHECK_RETRY:-1}"

# Queue v2 directories (per-worktree)
QUEUE_ROOT=".swarm/tasks"
INBOX="$QUEUE_ROOT/inbox"
PROCESSING="$QUEUE_ROOT/processing"
DONE="$QUEUE_ROOT/done"
mkdir -p "$INBOX" "$PROCESSING" "$DONE"

# Per-worktree label used in user-visible messages so it's obvious which
# worktree's inbox this listener is bound to (and that it does NOT serve
# briefs for other issues — those need their own provision-worker.sh /
# worktree). E.g. "wt-issue-215".
WT_LABEL="$(basename "$PWD")"

# Legacy v1 file
LEGACY_TASK_FILE=".agent-task.md"

# Build per-agent model flag from WORKER_MODEL. When unset, claude workers
# default to Sonnet 5 (near-Opus coding quality at ~half the token price and
# quota burn — matters with MAX_WORKERS running in parallel; escalate a hard
# issue with WORKER_MODEL=claude-opus-4-8). gemini/codex workers keep their
# CLI's own default. claude uses --model, gemini/codex use -m.
if [ -z "$MODEL" ] && [ "$AGENT" = "claude" ]; then
    MODEL="claude-sonnet-5"
fi
MODEL_OPTS=()
if [ -n "$MODEL" ]; then
    case "$AGENT" in
        claude) MODEL_OPTS=(--model "$MODEL") ;;
        gemini|codex) MODEL_OPTS=(-m "$MODEL") ;;
    esac
fi

echo "--- Worker Listener Active ---"
echo "Worktree: $WT_LABEL  (this listener serves ONLY $WT_LABEL's inbox)"
echo "Agent:    $AGENT${MODEL:+ (model: $MODEL)}"
echo "Mode:     $([ "$HEADLESS" = "1" ] && echo headless || echo interactive)"
echo "Queue:    $INBOX/  →  $PROCESSING/  →  $DONE/"
echo "Legacy:   $LEGACY_TASK_FILE (v1, still supported)"
[ "$HEADLESS" = "1" ] || cat <<'NOTE'

  Interactive mode: agent will run the seeded prompt and then drop to
  its REPL. Attach with `tmux a -t <session>` and switch to this window
  to interact. On first run claude will ask "Trust this folder?" — say Y.
  When done, /quit (claude) or Ctrl-D (gemini) to release the listener
  for the next task. Set WORKER_HEADLESS=1 to disable.

NOTE
echo "------------------------------"

# Returns the path of the next task to process, or empty if none.
# Sets globals: TASK_PATH (where the brief now lives, after claim),
#               TASK_ID (identifier for this run),
#               IS_LEGACY (1 if v1, 0 if v2).
claim_next_task() {
    TASK_PATH=""
    TASK_ID=""
    IS_LEGACY=0

    # v2 queue: oldest non-tmp file in inbox
    local next_inbox
    next_inbox=$(find "$INBOX" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null \
                  | sort | head -1)
    if [ -n "$next_inbox" ]; then
        TASK_ID=$(basename "$next_inbox" .md)
        local target
        target="$PROCESSING/$(basename "$next_inbox")"
        # Atomic claim. If another process beat us to it, mv fails — try again.
        if mv "$next_inbox" "$target" 2>/dev/null; then
            TASK_PATH="$target"
            IS_LEGACY=0
            return 0
        fi
    fi

    # v1 legacy: single file in worktree root
    if [ -f "$LEGACY_TASK_FILE" ]; then
        # Atomic claim by renaming to a sentinel — we'll move to last.md after.
        local stash=".agent-task.md.processing.$$"
        if mv "$LEGACY_TASK_FILE" "$stash" 2>/dev/null; then
            TASK_PATH="$stash"
            TASK_ID="legacy-$(date +%s)-$$"
            IS_LEGACY=1
            return 0
        fi
    fi

    return 1
}

# Dispatch the configured agent on a task text. Sets DISPATCH_RC.
# Relies on globals set per-task in the main loop: MODEL_OPTS,
# WORKER_SYSTEM_PROMPT_OPTS, WORKER_SYSTEM_PROMPT_ENV, CODEX_PREFIX.
# Callable more than once per task (used by the check-failure retry).
dispatch_agent() {
    local task_text="$1"
    local codex_task="$task_text"
    [ -n "$CODEX_PREFIX" ] && codex_task="$CODEX_PREFIX"$'\n\n---\n\n'"$task_text"

    if [[ "$AGENT" == "claude" ]]; then
        if [ "$HEADLESS" = "1" ]; then
            claude "${MODEL_OPTS[@]}" "${WORKER_SYSTEM_PROMPT_OPTS[@]}" -p "$task_text" --dangerously-skip-permissions
        else
            claude "${MODEL_OPTS[@]}" "${WORKER_SYSTEM_PROMPT_OPTS[@]}" "$task_text" --dangerously-skip-permissions
        fi
    elif [[ "$AGENT" == "gemini" ]]; then
        if [ "$HEADLESS" = "1" ]; then
            "${WORKER_SYSTEM_PROMPT_ENV[@]}" gemini "${MODEL_OPTS[@]}" -p "$task_text" --yolo --skip-trust
        else
            "${WORKER_SYSTEM_PROMPT_ENV[@]}" gemini "${MODEL_OPTS[@]}" -i "$task_text" --yolo --skip-trust
        fi
    elif [[ "$AGENT" == "codex" ]]; then
        if [ "$HEADLESS" = "1" ]; then
            codex exec "${MODEL_OPTS[@]}" --dangerously-bypass-approvals-and-sandbox "$codex_task"
        else
            codex "${MODEL_OPTS[@]}" --dangerously-bypass-approvals-and-sandbox --no-alt-screen "$codex_task"
        fi
    else
        bash -c "$task_text"
    fi && DISPATCH_RC=0 || DISPATCH_RC=$?
}

# ── Executed acceptance checks ──────────────────────────────────────────────
# Concept adopted from Nate B. Jones's ringer (PolyForm Shield license):
# a task only truly passes when an *executed* check exits 0 — not when the
# agent merely declares done. No ringer code is copied; this is an original
# bash implementation against our queue-v2 outcome schema. Attribution and
# concept pointers: docs/ringer-adoptions.md.

# Resolve the check command for the current task into $CHECK_CMD (may be
# empty = no check). See header for the resolution order.
resolve_check_cmd() {
    CHECK_CMD=""
    [ "$CHECK_ENABLED" = "1" ] || return 0
    # 1. per-task marker in the brief (mirrors ringer's per-task `check` field)
    CHECK_CMD=$(printf '%s\n' "$TASK" \
                | sed -n 's/.*<!-- SWARM_CHECK: \(.*\) -->.*/\1/p' | head -1)
    [ -n "$CHECK_CMD" ] && return 0
    # 2. standing per-issue check in the worktree
    if [ -r ".swarm/check.sh" ]; then
        CHECK_CMD="bash .swarm/check.sh"
        return 0
    fi
    # 3. listener-wide env default
    CHECK_CMD="${WORKER_CHECK_CMD:-}"
}

# Run $CHECK_CMD (if any). Sets CHECK_EXIT ("" = check not run) and
# CHECK_TAIL (last 20 lines of combined output). Full output is kept at
# done/<id>.check.log as the audit artifact.
run_check() {
    CHECK_EXIT=""
    CHECK_TAIL=""
    [ -n "$CHECK_CMD" ] || return 0
    echo "[$(date +%T)] Running acceptance check: $CHECK_CMD"
    local check_log="$DONE/${TASK_ID}.check.log"
    timeout "$CHECK_TIMEOUT" bash -c "$CHECK_CMD" > "$check_log" 2>&1 \
        && CHECK_EXIT=0 || CHECK_EXIT=$?
    CHECK_TAIL=$(tail -n 20 "$check_log" 2>/dev/null)
    if [ "$CHECK_EXIT" -eq 0 ]; then
        echo "[$(date +%T)] Acceptance check PASS (exit 0)."
    else
        echo "[$(date +%T)] Acceptance check FAIL (exit $CHECK_EXIT; 124 = timed out after ${CHECK_TIMEOUT}s). Output tail:"
        printf '%s\n' "$CHECK_TAIL" | sed 's/^/    /'
    fi
}

# Append one JSONL eval row per completed v2 task — the durable record the
# scoreboard (scripts/swarm-scoreboard.sh) aggregates per (agent, model).
# Eval-loop concept adopted from ringer (docs/ringer-adoptions.md #3).
# Default location is per-worktree (.swarm/eval-log.jsonl); point
# SWARM_EVAL_LOG at a path outside the worktree to survive worktree reaping
# and to pool rows across workers. Requires jq (skipped silently without it —
# the outcome JSON in done/ is unaffected).
append_eval_log() {
    local outcome="$1" finished="$2" duration="$3" rc="$4"
    command -v jq >/dev/null 2>&1 || return 0
    local log="${SWARM_EVAL_LOG:-.swarm/eval-log.jsonl}"
    local issue=""
    case "$WT_LABEL" in wt-issue-*) issue="${WT_LABEL#wt-issue-}" ;; esac
    jq -cn \
        --arg ts "$finished" --arg task_id "$TASK_ID" --arg issue "$issue" \
        --arg agent "$AGENT" --arg model "$MODEL" \
        --arg check_cmd "${CHECK_CMD:-}" --arg check_exit "${CHECK_EXIT:-}" \
        --argjson duration "$duration" --argjson exit_code "$rc" \
        --argjson retried "${RETRIED:-false}" --arg outcome "$outcome" \
        '{ts: $ts, task_id: $task_id,
          issue: (if $issue == "" then null else ($issue | tonumber? // $issue) end),
          agent: $agent,
          model: (if $model == "" then null else $model end),
          duration_seconds: $duration, exit_code: $exit_code,
          check_cmd: (if $check_cmd == "" then null else $check_cmd end),
          check_exit: (if $check_exit == "" then null else ($check_exit | tonumber) end),
          retried: $retried, outcome: $outcome}' >> "$log" 2>/dev/null \
        || echo "WARN: could not append eval row to $log" >&2
}

# Write a structured outcome record for v2 tasks. No-op for v1 (no contract).
write_outcome() {
    local rc="$1" started="$2" finished="$3" duration="$4"
    [ "$IS_LEGACY" = "1" ] && return 0

    # An executed check gates the pass: agent exit 0 alone is not "ok" if
    # the acceptance check ran and failed.
    local outcome="ok"
    [ "$rc" -ne 0 ] && outcome="err"
    [ -n "${CHECK_EXIT:-}" ] && [ "$CHECK_EXIT" -ne 0 ] && outcome="err"
    local outcome_file="$DONE/${TASK_ID}.${outcome}.json"

    # JSON-escape the model field (may be empty)
    local model_json="null"
    [ -n "$MODEL" ] && model_json="\"$MODEL\""

    # Check fields: null when no check resolved/ran. check_cmd and the output
    # tail need real JSON escaping (arbitrary shell text) — jq does it; if jq
    # is absent, record exit code only and null the strings.
    local check_cmd_json="null" check_exit_json="null" check_tail_json="null"
    if [ -n "${CHECK_EXIT:-}" ]; then
        check_exit_json="$CHECK_EXIT"
        if command -v jq >/dev/null 2>&1; then
            check_cmd_json=$(printf '%s' "$CHECK_CMD" | jq -Rs .)
            check_tail_json=$(printf '%s' "$CHECK_TAIL" | jq -Rs .)
        fi
    fi

    cat > "$outcome_file" <<EOF
{
  "task_id": "$TASK_ID",
  "started":  "$started",
  "finished": "$finished",
  "duration_seconds": $duration,
  "exit_code": $rc,
  "outcome": "$outcome",
  "agent": "$AGENT",
  "model": $model_json,
  "headless": $([ "$HEADLESS" = "1" ] && echo true || echo false),
  "check_cmd": $check_cmd_json,
  "check_exit": $check_exit_json,
  "check_output_tail": $check_tail_json,
  "retried": ${RETRIED:-false}
}
EOF
    echo "[$(date +%T)] Wrote outcome: $outcome_file"
    append_eval_log "$outcome" "$finished" "$duration" "$rc"
}

while true; do
    # If the worktree was reaped out from under us (e.g., the worker
    # self-deregistered after filing successor issues and deleted its
    # own worktree), the inbox dir disappears. Without this guard the
    # listener would spin forever on `find` returning nothing, leaving
    # a zombie tmux window. Exit cleanly so the window closes.
    if [ ! -d "$INBOX" ] || [ ! -d "$PWD" ]; then
        echo "[$(date +%T)] Worktree $WT_LABEL appears reaped (inbox or cwd missing). Listener exiting cleanly."
        exit 0
    fi

    if claim_next_task; then
        echo "[$(date +%T)] Task received! id=$TASK_ID$([ "$IS_LEGACY" = "1" ] && echo " (v1 legacy)")"

        TASK=$(cat "$TASK_PATH")

        # Echo the task brief so anyone attached can see what the worker is
        # actually working on. Truncate at 40 lines; full text always lives
        # in the processing/done file regardless.
        echo "--- Task brief (first 40 lines) ---"
        printf '%s\n' "$TASK" | head -40
        TASK_LINES=$(printf '%s\n' "$TASK" | wc -l)
        if [ "$TASK_LINES" -gt 40 ]; then
            echo "... [truncated; $TASK_LINES total lines] ..."
        fi
        echo "------------------------------------"

        echo "[$(date +%T)] Executing task..."
        STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        STARTED_EPOCH=$(date +%s)

        # Worker system prompt: prompts/worker.md (the universal worker
        # conventions — summary block, decision framing, NBA hint, PR risk
        # rating, refresh-from-master, tiered self-merge). Delivered as a
        # system prompt to both agents for stronger adherence than when it
        # was concatenated into the user message in earlier versions:
        #   - claude: --append-system-prompt "$(cat worker.md)"
        #   - gemini: GEMINI_SYSTEM_MD=<path> env var (per gemini-cli docs)
        #   - codex: prepend worker.md to the task prompt (codex CLI does not
        #     expose an append-system-prompt flag)
        WORKER_MD="${LLM_SWARM_DIR:-}/prompts/worker.md"
        WORKER_SYSTEM_PROMPT_OPTS=()
        WORKER_SYSTEM_PROMPT_ENV=()
        CODEX_PREFIX=""
        if [ -n "${LLM_SWARM_DIR:-}" ] && [ -r "$WORKER_MD" ]; then
            case "$AGENT" in
                claude) WORKER_SYSTEM_PROMPT_OPTS=(--append-system-prompt "$(cat "$WORKER_MD")") ;;
                gemini) WORKER_SYSTEM_PROMPT_ENV=(env "GEMINI_SYSTEM_MD=$WORKER_MD") ;;
                codex) CODEX_PREFIX="$(cat "$WORKER_MD")" ;;
            esac
        else
            case "$AGENT" in
                claude|gemini|codex)
                    echo "WARN: prompts/worker.md not found at $WORKER_MD — worker conventions will NOT be injected as system prompt." >&2
                    echo "      Expected LLM_SWARM_DIR to be set and the file readable. Briefs will lack the universal conventions." >&2
                    ;;
            esac
        fi

        # Dispatch agent
        # Default: interactive — agent runs the seeded prompt, prints tool
        # calls + final answer, then drops to its REPL so an attached user
        # can answer follow-up questions. The listener loop is blocked here
        # until the agent exits (/quit or Ctrl-D).
        #
        # WORKER_HEADLESS=1: revert to print-and-exit semantics. Used by the
        # e2e test path (which has no human attached) and any automation.
        # `-p` also skips claude's "Trust this folder?" dialog by design.
        dispatch_agent "$TASK"
        RC=$DISPATCH_RC

        # Acceptance check + retry-once-with-failure-context (v2 only).
        # On check failure, re-dispatch the agent ONCE with the check's
        # failure output injected into the prompt, then re-run the check —
        # ringer's retry concept (see docs/ringer-adoptions.md #5). Kill
        # switch: WORKER_CHECK_RETRY=0. Failure context goes BEFORE the
        # original brief so the final instruction the agent reads is the
        # task itself.
        RETRIED=false
        if [ "$IS_LEGACY" != "1" ]; then
            resolve_check_cmd
            run_check
            if [ -n "$CHECK_EXIT" ] && [ "$CHECK_EXIT" -ne 0 ] && [ "$CHECK_RETRY" = "1" ]; then
                echo "[$(date +%T)] Check failed — retrying once with failure output injected."
                mv "$DONE/${TASK_ID}.check.log" "$DONE/${TASK_ID}.check.attempt1.log" 2>/dev/null || true
                RETRY_TASK="## Retry — previous attempt failed the acceptance check

A previous attempt at the task below did not pass its acceptance check.
The check command \`$CHECK_CMD\` exited $CHECK_EXIT. Last lines of its
output:

\`\`\`
$CHECK_TAIL
\`\`\`

Diagnose what is wrong, fix it, and make sure the check passes this time.
The original task follows.

---

$TASK"
                RETRIED=true
                dispatch_agent "$RETRY_TASK"
                RC=$DISPATCH_RC
                run_check
            fi
        fi

        FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        DURATION=$(( $(date +%s) - STARTED_EPOCH ))

        # Move brief into the appropriate archive location, then write outcome.
        if [ "$IS_LEGACY" = "1" ]; then
            mv "$TASK_PATH" ".agent-task-last.md"
        else
            mv "$TASK_PATH" "$DONE/$(basename "$TASK_PATH")"
            write_outcome "$RC" "$STARTED" "$FINISHED" "$DURATION"
        fi

        echo "------------------------------"
        echo "[$(date +%T)] Task complete (exit $RC, ${DURATION}s). Waiting for next brief in $WT_LABEL/$INBOX/ — use 'requeue.sh ${WT_LABEL#wt-issue-} <brief>' to send a follow-up on this issue. (Different issues need their own worktree via provision-worker.sh.)"
    fi
    sleep 2
done
