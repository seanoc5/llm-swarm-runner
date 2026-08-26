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
#   <wt>/.swarm/tasks/status/<id>.json    worker-written state declaration
#                                         (not this script — see worker.md)
#   <wt>/.swarm/tasks/outbox/<ts>-<slug>.md
#                                         worker-written message to the
#                                         coordinator (not this script —
#                                         coordinator-watch.sh wakes on it,
#                                         issue #129)
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
# Minimum-interaction floor (issue #287, claude agent only):
#   An agent exit code of 0 is not proof the agent ever ran the task — an
#   interactive startup dialog (corrupt config, trust prompt, login screen;
#   see #286) can idle, get dismissed, and exit 0 having done nothing. When
#   a task would otherwise be recorded "ok" with NO executed check, NO new
#   commits ahead of the default branch, and NO worker-authored status file
#   (worker.md requires one for every terminal state, so its absence means
#   the worker never got that far), the listener falls back to checking
#   whether the claude CLI's own session transcript under
#   ~/.claude/projects/<worktree-slug>/*.jsonl actually grew during this
#   dispatch. No transcript activity (or only a sliver of it — smaller than
#   a real task turn) downgrades the outcome to "err" with a
#   `reason: "agent-startup-failure: ..."` field. A passed check or a
#   worker-written status file is independent proof of real work and is
#   never second-guessed. Kill switch: WORKER_NOOP_DETECT=0. Threshold:
#   WORKER_MIN_TRANSCRIPT_BYTES (default 200).
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
#                        Once the agent exits and no other task is queued,
#                        the pane drops to a normal interactive `bash -i`
#                        prompt (issue #43) instead of blocking silently.
#                        A background subshell keeps polling inbox/; when a
#                        new brief lands it's picked up the next time the
#                        shell returns to an idle prompt (never mid-command),
#                        and the agent is relaunched automatically. See
#                        run_idle_shell() below for the mechanism.
#   WORKER_HEADLESS=1  — agent runs with -p (claude) / -p (gemini) /
#                        codex exec, prints, and exits. Skips the trust
#                        dialog. Used by e2e tests and any automation where
#                        no human is attached. Idle time uses the original
#                        silent `sleep 2` poll — no interactive shell is
#                        spawned (there's no operator to hand it to, and
#                        `bash -i` needs a real tty).

AGENT="${1:-claude}"
MODEL="${WORKER_MODEL:-}"
HEADLESS="${WORKER_HEADLESS:-0}"
CHECK_ENABLED="${WORKER_CHECK:-1}"
CHECK_TIMEOUT="${WORKER_CHECK_TIMEOUT:-600}"
CHECK_RETRY="${WORKER_CHECK_RETRY:-1}"
NOOP_DETECT_ENABLED="${WORKER_NOOP_DETECT:-1}"
MIN_TRANSCRIPT_BYTES="${WORKER_MIN_TRANSCRIPT_BYTES:-200}"

# Queue v2 directories (per-worktree)
QUEUE_ROOT=".swarm/tasks"
INBOX="$QUEUE_ROOT/inbox"
PROCESSING="$QUEUE_ROOT/processing"
DONE="$QUEUE_ROOT/done"
STATUS="$QUEUE_ROOT/status"
mkdir -p "$INBOX" "$PROCESSING" "$DONE" "$STATUS"

# Sentinel used by run_idle_shell()'s background poller to signal the
# interactive shell that a brief has arrived. Not inside INBOX itself so it
# can never be mistaken for a queued task.
IDLE_SENTINEL="$QUEUE_ROOT/.brief-pending"

# Sentinel touched by the idle shell's `close-worker` command to tell the
# listener the operator wants this listener ended and the window closed.
# Needed because a plain `exit` from the idle shell deliberately respawns it
# (the slot must survive stray exits / Ctrl-D — see run_idle_shell), which
# left no in-pane way to close a worker at all: the watcher's autoclose
# never touches no-PR workers (their worktrees may hold unpushed or
# untracked work), so a worker that finishes without opening a PR would
# otherwise sit parked forever unless reaped host-side. Swept at startup so
# a leftover sentinel from a killed container can't instantly close a fresh
# listener.
CLOSE_SENTINEL="$QUEUE_ROOT/.close-requested"
rm -f "$CLOSE_SENTINEL"

# Double-Ctrl-D close: a respawned idle shell (IDLE_RESPAWNS >= 2, i.e. not
# the first shell of this parked stretch) that exits again within this many
# seconds is read as the operator hammering "get me out" — the pre-#43
# muscle memory. Guarded by an inbox-empty check so a brief-arrival relaunch
# (which also exits the shell quickly) can never be mistaken for it.
# IDLE_RESPAWNS resets on every task dispatch, so the first shell after a
# task completes never quick-closes on a single Ctrl-D.
IDLE_QUICK_EXIT_SECS="${WORKER_IDLE_QUICK_EXIT_SECS:-3}"
IDLE_RESPAWNS=0

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

  Between tasks, once the queue is empty, this pane drops to a normal
  bash prompt in this worktree — poke around freely (git status, logs,
  etc). Polling continues in the background; a new brief relaunches the
  agent automatically once you're back at an idle prompt.

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

# Guard against a stale $LLM_SWARM_DIR (issue #251). $LLM_SWARM_DIR is the
# runner sandbox's own checkout — the source of prompts/worker.md, injected
# as a system prompt into every dispatched agent below. Worktrees always
# fetch fresh from origin/<default> in provision-worker.sh, so if the runner
# checkout itself falls behind (e.g. only the coordinator's checkout got
# pulled), the staleness is invisible from the worktree side and workers
# silently get outdated conventions. Fast-forward when it's safe to; warn
# only when the checkout is dirty, diverged, or the remote is unreachable —
# never mutate in those cases. Cheap: one fetch + rev-list per task dispatch.
refresh_stale_runner_checkout() {
    local dir="${LLM_SWARM_DIR:-}"
    [ -n "$dir" ] && [ -d "$dir/.git" ] || return 0

    if ! git -C "$dir" fetch --quiet origin 2>/dev/null; then
        echo "WARN stale-prompts: git fetch failed in \$LLM_SWARM_DIR ($dir) — remote unreachable, proceeding with local prompts as-is." >&2
        return 0
    fi

    local default_ref
    default_ref="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -z "$default_ref" ]; then
        local cand
        for cand in main master; do
            if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$cand"; then
                default_ref="origin/$cand"
                break
            fi
        done
    fi
    [ -n "$default_ref" ] || return 0

    local behind ahead
    behind="$(git -C "$dir" rev-list --count "HEAD..$default_ref" 2>/dev/null || echo 0)"
    ahead="$(git -C "$dir" rev-list --count "$default_ref..HEAD" 2>/dev/null || echo 0)"
    [ "${behind:-0}" -gt 0 ] || return 0

    if [ "${ahead:-0}" -gt 0 ]; then
        echo "WARN stale-prompts: \$LLM_SWARM_DIR ($dir) has diverged from $default_ref ($behind behind, $ahead ahead) — not auto-mutating a diverged checkout; pull manually." >&2
        return 0
    fi

    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        echo "WARN stale-prompts: \$LLM_SWARM_DIR ($dir) is $behind commit(s) behind $default_ref but has uncommitted changes — not auto-mutating a dirty checkout; pull manually." >&2
        return 0
    fi

    if git -C "$dir" merge --ff-only --quiet "$default_ref" 2>/dev/null; then
        echo "[$(date +%T)] Fast-forwarded \$LLM_SWARM_DIR ($dir) $behind commit(s) to $default_ref before prompt injection."
    else
        echo "WARN stale-prompts: \$LLM_SWARM_DIR ($dir) is $behind commit(s) behind $default_ref and fast-forward failed — proceeding with stale prompts." >&2
    fi
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

# Resolve the current worktree's default-branch ref (e.g. "origin/master"),
# same resolution order used by refresh_stale_runner_checkout() above but
# against the worktree itself (cwd) rather than $LLM_SWARM_DIR. Empty output
# means it couldn't be resolved (no origin, detached checkout, etc.) — callers
# treat that as "unknown" rather than erroring.
worktree_default_ref() {
    local ref
    ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -z "$ref" ]; then
        local cand
        for cand in main master; do
            if git show-ref --verify --quiet "refs/remotes/origin/$cand" 2>/dev/null; then
                ref="origin/$cand"
                break
            fi
        done
    fi
    printf '%s' "$ref"
}

# ── Minimum-interaction floor (issue #287) ──────────────────────────────────
# A claude agent that never got past an interactive startup dialog (corrupt
# config, trust prompt, login screen — see #286) can still exit 0 once the
# dialog is dismissed or times out, producing a false "outcome: ok" with zero
# actual work performed (#287's incident: 19 idle minutes, no commits, no PR,
# recorded as ok). Exit code alone can't tell that apart from a real run. The
# claude CLI's own session transcript JSONL under
# ~/.claude/projects/<worktree-slug>/ is a liveness signal exit code isn't: a
# session that never wrote there during this dispatch (or wrote only a
# sliver — smaller than a real task turn, since worker.md alone is appended
# as a multi-KB system prompt) did not actually engage with the task. Only
# implemented for the claude agent — gemini/codex have no equivalent
# transcript convention here yet. Sets NOOP_REASON (empty = looks like the
# agent actually ran).
check_min_interaction() {
    NOOP_REASON=""
    [ "$NOOP_DETECT_ENABLED" = "1" ] || return 0
    [ "$AGENT" = "claude" ] || return 0
    [ -n "${HOME:-}" ] || return 0

    local slug transcript_dir f m size newest_mtime=0 newest_file=""
    slug="$(printf '%s' "$PWD" | tr '/' '-')"
    transcript_dir="$HOME/.claude/projects/$slug"
    if [ ! -d "$transcript_dir" ]; then
        NOOP_REASON="no transcript dir for this worktree ($transcript_dir)"
        return 0
    fi

    for f in "$transcript_dir"/*.jsonl; do
        [ -e "$f" ] || continue
        m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        if [ "$m" -ge "$newest_mtime" ]; then
            newest_mtime=$m
            newest_file="$f"
        fi
    done

    if [ -z "$newest_file" ] || [ "$newest_mtime" -lt "$((STARTED_EPOCH - 2))" ]; then
        NOOP_REASON="no session transcript written during this dispatch"
        return 0
    fi

    size=$(stat -c %s "$newest_file" 2>/dev/null || echo 0)
    if [ "$size" -lt "$MIN_TRANSCRIPT_BYTES" ]; then
        NOOP_REASON="session transcript is only ${size}b (< ${MIN_TRANSCRIPT_BYTES}b) — looks like the agent never got past startup"
    fi
}

# Write a structured outcome record for v2 tasks. No-op for v1 (no contract).
# Sets global TASK_OUTCOME ("ok"/"err") so the caller can build the
# post-task status block without recomputing the check-gating logic.
write_outcome() {
    local rc="$1" started="$2" finished="$3" duration="$4"
    [ "$IS_LEGACY" = "1" ] && return 0

    # An executed check gates the pass: agent exit 0 alone is not "ok" if
    # the acceptance check ran and failed.
    TASK_OUTCOME="ok"
    [ "$rc" -ne 0 ] && TASK_OUTCOME="err"
    [ -n "${CHECK_EXIT:-}" ] && [ "$CHECK_EXIT" -ne 0 ] && TASK_OUTCOME="err"

    # Minimum-interaction floor (#287): an apparent "ok" backed by no
    # executed check is only trustworthy if the agent actually engaged with
    # the task. A passed check or a worker-written status file is
    # independent proof of real work and is never second-guessed below —
    # only reached when neither exists, on top of zero new commits.
    local reason=""
    if [ "$TASK_OUTCOME" = "ok" ] && [ -z "${CHECK_EXIT:-}" ]; then
        local default_ref ahead=0 has_status=0
        default_ref="$(worktree_default_ref)"
        [ -n "$default_ref" ] && ahead="$(git rev-list --count "${default_ref}..HEAD" 2>/dev/null || echo 0)"
        [ -r "$STATUS/${TASK_ID}.json" ] && has_status=1
        if [ "${ahead:-0}" -eq 0 ] && [ "$has_status" -eq 0 ]; then
            check_min_interaction
            if [ -n "$NOOP_REASON" ]; then
                TASK_OUTCOME="err"
                reason="agent-startup-failure: $NOOP_REASON"
            fi
        fi
    fi

    local outcome="$TASK_OUTCOME"
    local outcome_file="$DONE/${TASK_ID}.${outcome}.json"

    # JSON-escape the model field (may be empty)
    local model_json="null"
    [ -n "$MODEL" ] && model_json="\"$MODEL\""

    # JSON-escape the reason field (set only when the noop tripwire fired)
    local reason_json="null"
    if [ -n "$reason" ]; then
        if command -v jq >/dev/null 2>&1; then
            reason_json=$(printf '%s' "$reason" | jq -Rs .)
        else
            reason_json="\"agent-startup-failure\""
        fi
    fi

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
  "reason": $reason_json,
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

# Print a structured, actionable status block once per completed task —
# replaces the old one-line "Task complete... Waiting for next brief"
# message, which was indistinguishable from a hang at a glance (issue #42).
#
# The literal marker "[polling for next brief" on its own line at the end
# is load-bearing: it's what check-stuck-workers.sh and
# kill-finished-workers.sh grep for to detect an idle/parked listener.
# Keep that exact substring if you touch this function.
print_completion_block() {
    local rc="$1" duration="$2" outcome="$3" is_legacy="$4" brief_ref="$5"
    local bar="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local issue_num="${WT_LABEL#wt-issue-}"

    # Pull PR/blocked/done-no-pr status from the worker's own status file
    # (queue-v2 protocol: .swarm/tasks/status/<task_id>.json), when present.
    local pr="" pr_state="" pr_note="" outcome_reason=""
    if [ "$is_legacy" != "1" ] && command -v jq >/dev/null 2>&1; then
        local status_file="$STATUS/${TASK_ID}.json"
        if [ -r "$status_file" ]; then
            pr=$(jq -r 'if (.pr // null) == null then "" else (.pr|tostring) end' "$status_file" 2>/dev/null)
            pr_state=$(jq -r '.state // empty' "$status_file" 2>/dev/null)
            pr_note=$(jq -r '.note // empty' "$status_file" 2>/dev/null)
        fi
        local outcome_file="$DONE/${TASK_ID}.${outcome}.json"
        [ -r "$outcome_file" ] && outcome_reason=$(jq -r '.reason // empty' "$outcome_file" 2>/dev/null)
    fi

    echo ""
    echo "$bar"
    if [ "$outcome" = "ok" ]; then
        printf '  TASK COMPLETE    exit=%s    duration=%ss\n' "$rc" "$duration"
    else
        printf '  TASK FAILED       exit=%s    duration=%ss\n' "$rc" "$duration"
        [ -n "$outcome_reason" ] && echo "  Reason: $outcome_reason"
    fi
    if [ -n "$pr" ]; then
        echo "  PR #$pr opened — gh pr view $pr"
    elif [ "$pr_state" = "blocked" ]; then
        echo "  Blocked${pr_note:+: $pr_note}"
    elif [ "$pr_state" = "done-no-pr" ]; then
        echo "  No PR — task delivered without one${pr_note:+: $pr_note}"
    fi
    echo "$bar"
    echo ""
    echo "What to do next:"
    if [ -n "$pr" ]; then
        echo "  • Accept & merge:   gh pr merge $pr --squash"
        echo "  • Reject:           gh pr close $pr"
    elif [ "$outcome" != "ok" ]; then
        echo "  • Investigate:      gh pr view, scrollback above, brief at $brief_ref"
    fi
    echo "  • Follow up here:   requeue.sh $issue_num \"<follow-up brief>\""
    echo "  • Leave it          this listener will pick up the next brief on inbox/"
    echo "                      (different issues need their own worktree via provision-worker.sh)"
    echo "  • Close it:         Ctrl-D twice, Ctrl-C twice, or type close-worker at the shell prompt below"
    echo "                      (plain 'exit' only respawns the shell; worktree stays for kill-worktree.sh)"
    echo ""
    if [ -n "$pr" ]; then
        echo "(Watcher detects PR-state changes; this slot frees automatically — see #32)"
    else
        echo "(No PR — the watcher will NOT autoclose this slot; use close-worker when done here)"
    fi
    echo "$bar"
    echo ""
    echo "[$(date +%T)] [polling for next brief in $WT_LABEL/$INBOX/ ...]"
}

# ── Interactive idle shell (issue #43) ──────────────────────────────────────
# Between agent invocations, hand the pane to the operator as a normal bash
# shell instead of blocking the pane on a silent `sleep 2` poll. Two pieces:
#
#   poll_for_brief  — background subshell; sleeps 2s at a time watching
#                      inbox/ (same emptiness check claim_next_task uses) and
#                      touches IDLE_SENTINEL the moment a brief shows up,
#                      then exits. It never claims the task itself — that
#                      stays claim_next_task's job once control returns here.
#
#   run_idle_shell  — starts poll_for_brief, then execs an interactive
#                      `bash -i` whose PROMPT_COMMAND checks IDLE_SENTINEL
#                      right before each new prompt is drawn. PROMPT_COMMAND
#                      only runs between commands, so this can never fire
#                      mid-keystroke or kill a command the operator has
#                      running — the trade-off is that a genuinely idle,
#                      untouched prompt won't pick up a brief until the
#                      operator hits Enter again. Given the alternative is
#                      forcibly killing whatever's running in the shell,
#                      that trade-off is the right default (see issue #43's
#                      "race handling" discussion for the other options
#                      considered).
poll_for_brief() {
    while true; do
        sleep 2
        [ -d "$INBOX" ] && [ -d "$PWD" ] || return 0
        local next
        next=$(find "$INBOX" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | head -1)
        if [ -n "$next" ]; then
            touch "$IDLE_SENTINEL" 2>/dev/null
            return 0
        fi
    done
}

run_idle_shell() {
    rm -f "$IDLE_SENTINEL"
    poll_for_brief &
    local poll_pid=$!

    local rcfile
    rcfile=$(mktemp)
    # Unquoted heredoc: $IDLE_SENTINEL is baked in as a literal path below.
    # PROMPT_COMMAND is chained (not overwritten) so anything ~/.bashrc set
    # still runs — our check runs LAST so its INT-trap re-assert wins (see
    # __swarm_check_brief's comment).
    cat > "$rcfile" <<EOF
[ -r ~/.bashrc ] && source ~/.bashrc

__swarm_check_brief() {
    # Re-assert the double-Ctrl-C trap every prompt: some ~/.bashrc hook
    # stacks (observed with a bash-preexec/atuin setup, exact culprit
    # rc-dependent) clear user INT traps before the first prompt draws.
    # This hook runs LAST in the PROMPT_COMMAND chain, so it wins over
    # whatever earlier hooks did to the trap this cycle.
    trap __swarm_on_int INT
    if [ -f "$IDLE_SENTINEL" ]; then
        rm -f "$IDLE_SENTINEL"
        echo
        echo "[new brief detected — launching claude]"
        sleep 1
        exit 0
    fi
}
PROMPT_COMMAND="\${PROMPT_COMMAND:+\$PROMPT_COMMAND; }__swarm_check_brief"

# Operator-facing close affordance: plain \`exit\` deliberately respawns the
# idle shell (the slot must survive stray exits), so this is the one way to
# end the listener from inside the pane. Touches CLOSE_SENTINEL, which
# run_idle_shell checks the moment this shell exits.
close-worker() {
    touch "$CLOSE_SENTINEL"
    echo "[close requested — ending listener]"
    exit 0
}

# Double-Ctrl-C close (pre-#43 muscle memory): interactive bash runs INT
# traps at the readline prompt, so two Ctrl-C within 2s close the worker
# via the same sentinel as close-worker. A lone Ctrl-C just prints the
# hint. While a foreground command is running, Ctrl-C still goes to that
# command as usual — this only fires once bash is back in control.
__swarm_int_last=-10
__swarm_on_int() {
    if [ \$((SECONDS - __swarm_int_last)) -le 2 ]; then
        touch "$CLOSE_SENTINEL"
        echo
        echo "[double ctrl-c — ending listener]"
        exit 0
    fi
    __swarm_int_last=\$SECONDS
    echo
    echo "(ctrl-c again within 2s to close this worker window)"
}
trap __swarm_on_int INT
EOF

    IDLE_RESPAWNS=$((IDLE_RESPAWNS + 1))
    local spawned=$SECONDS

    echo ""
    echo "[$(date +%T)] Queue empty — dropping to interactive shell in $WT_LABEL/. Polling continues in the background."
    echo "               (a plain 'exit' respawns this shell — close the worker with Ctrl-D twice, Ctrl-C twice, or 'close-worker')"
    bash --rcfile "$rcfile" -i
    local lifetime=$((SECONDS - spawned))

    rm -f "$rcfile"
    kill "$poll_pid" 2>/dev/null
    wait "$poll_pid" 2>/dev/null

    # `close-worker` or the double-Ctrl-C trap ran in the idle shell: end
    # the listener process itself, which closes the tmux window (same
    # clean-exit contract as the reaped-worktree guard in the main loop).
    # The worktree is deliberately left in place — it may hold unpushed or
    # untracked material; clean it up host-side with kill-worktree.sh when
    # genuinely done with it.
    if [ -f "$CLOSE_SENTINEL" ]; then
        rm -f "$CLOSE_SENTINEL"
        echo "[$(date +%T)] close requested: listener exiting — window will close. Worktree $WT_LABEL/ is left intact (remove later with kill-worktree.sh)."
        exit 0
    fi

    # Double-Ctrl-D close: this was already a respawned shell (not the first
    # of this parked stretch) and it exited again almost immediately —
    # operator is hammering exit/Ctrl-D to get out. The inbox guard keeps a
    # brief-arrival relaunch (which also exits the shell quickly) from ever
    # matching; with a brief pending, the main loop dispatches as normal.
    if [ "$IDLE_RESPAWNS" -ge 2 ] && [ "$lifetime" -le "$IDLE_QUICK_EXIT_SECS" ]; then
        local pending
        pending=$(find "$INBOX" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | head -1)
        if [ -z "$pending" ]; then
            echo "[$(date +%T)] double exit: listener exiting — window will close. Worktree $WT_LABEL/ is left intact (remove later with kill-worktree.sh)."
            exit 0
        fi
    fi
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
        IDLE_RESPAWNS=0   # new parked stretch after this task — see IDLE_QUICK_EXIT_SECS

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
        refresh_stale_runner_checkout
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
        BRIEF_REF=""
        if [ "$IS_LEGACY" = "1" ]; then
            mv "$TASK_PATH" ".agent-task-last.md"
            TASK_OUTCOME="ok"
            [ "$RC" -ne 0 ] && TASK_OUTCOME="err"
            BRIEF_REF=".agent-task-last.md"
        else
            mv "$TASK_PATH" "$DONE/$(basename "$TASK_PATH")"
            write_outcome "$RC" "$STARTED" "$FINISHED" "$DURATION"
            BRIEF_REF="$DONE/$(basename "$TASK_PATH")"
        fi

        print_completion_block "$RC" "$DURATION" "$TASK_OUTCOME" "$IS_LEGACY" "$BRIEF_REF"

        # Loop straight back to claim_next_task rather than falling through
        # to the idle branch below — if more briefs are already queued,
        # drain them in order before handing the pane to the operator.
        continue
    fi

    # Queue empty. Headless (automation, e2e tests) keeps the original
    # silent poll — no operator to hand the pane to, and `bash -i` needs a
    # real tty. Interactive mode drops to a real shell (see run_idle_shell).
    if [ "$HEADLESS" = "1" ]; then
        sleep 2
    else
        run_idle_shell
    fi
done
