#!/usr/bin/env bash
#
# demo-driver.sh — Drive a deterministic ~70-second demo recording
#
# Sets up a clean tmux session, launches the swarm-runner coordinator
# scoped to a fixed set of demo issues, then choreographs the visual
# story (window-switch → worker observation → event-log split → PR list)
# while you focus on the screen recorder.
#
# Usage:
#   cd /opt/work/sysadmin/llm-swarm-runner
#   ./scripts/demo-driver.sh             # full run
#   DRY_RUN=1 ./scripts/demo-driver.sh   # plan + pre-flight checks; no swarm
#
# Tunables (env vars):
#   MIN_DEMO_BACKLOG    Warn if fewer swarm-ready issues exist (default: 3).
#                       Below the threshold the coordinator is instructed
#                       to create more demo-friendly issues inline.
#   DEMO_PROMPT         Override the coordinator's demo-mode prompt entirely.
#   COORD_TIMEOUT       Seconds to wait for coordinator first output (default: 45)
#   WORKER_WATCH_SECS   Seconds to dwell on a worker pane (default: 15)
#   EVENT_LOG_SECS      Seconds to dwell on the event log (default: 10)
#   PR_LIST_SECS        Seconds to dwell on `gh pr list` (default: 10)
#   DRY_RUN=1           Skip the actual swarm; print what would run

set -uo pipefail

# ---- Config ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="$(dirname "$SCRIPT_DIR")"
SESSION_NAME="llm-$(basename "$PWD")"

MIN_DEMO_BACKLOG="${MIN_DEMO_BACKLOG:-3}"   # warn if fewer than this swarm-ready issues exist
COORD_TIMEOUT="${COORD_TIMEOUT:-45}"
WORKER_WATCH_SECS="${WORKER_WATCH_SECS:-15}"
EVENT_LOG_SECS="${EVENT_LOG_SECS:-10}"
PR_LIST_SECS="${PR_LIST_SECS:-10}"
DRY_RUN="${DRY_RUN:-0}"

# ---- Helpers ---------------------------------------------------------------

log()  { printf '\033[1;36m[demo-driver]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[demo-driver]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[demo-driver]\033[0m %s\n' "$*" >&2; }

wait_for_text() {
    local pane="$1" text="$2" timeout="${3:-30}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if tmux capture-pane -t "$pane" -p 2>/dev/null | grep -q -F -- "$text"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

wait_for_window() {
    local pattern="$1" timeout="${2:-30}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null \
            | grep -qE "$pattern"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# ---- Pre-flight ------------------------------------------------------------

log "=== llm-swarm-runner demo driver ==="
log "session name:      $SESSION_NAME"
log "min backlog:       $MIN_DEMO_BACKLOG (swarm-ready issues; coordinator will create more if short)"
log "dry run:           $DRY_RUN"
log ""

# Sanity checks
if [ ! -x "$LLM_SWARM_DIR/llm-start.sh" ]; then
    err "FATAL: $LLM_SWARM_DIR/llm-start.sh not found or not executable"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    err "FATAL: gh not in PATH"
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    err "FATAL: gh is not authenticated (run 'gh auth login')"
    exit 1
fi

# Count current swarm-ready backlog (informational — coordinator handles top-up)
log "[pre-flight] Counting swarm-ready backlog..."
SWARM_READY_COUNT=$(gh issue list --label swarm-ready --state open --json number --jq 'length')
log "  $SWARM_READY_COUNT open issues labeled swarm-ready."
if [ "$SWARM_READY_COUNT" -lt "$MIN_DEMO_BACKLOG" ]; then
    warn "  fewer than MIN_DEMO_BACKLOG=$MIN_DEMO_BACKLOG — coordinator will be instructed to create more inline."
fi

# Verify docker image exists
if ! docker image inspect llm-swarm-runner:latest >/dev/null 2>&1; then
    err "FATAL: docker image llm-swarm-runner:latest not found. Run 'docker build -t llm-swarm-runner:latest .'"
    exit 1
fi
log "  docker image llm-swarm-runner:latest found."

if [ "$DRY_RUN" = "1" ]; then
    log ""
    log "DRY_RUN=1 — pre-flight passed. Re-run without DRY_RUN to execute."
    exit 0
fi

# ---- State setup -----------------------------------------------------------

log "[setup] Killing any prior session, cleaning .swarm/..."
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
rm -rf .swarm/

# ---- Background driver ----------------------------------------------------

drive_beats() {
    # Beat 3/4: wait for the actual signal that dispatch happened — worker windows.
    # The previous "OPEN=" marker was tied to the formal Initial Startup Checklist
    # output, which the demo-mode prompt explicitly suppresses. Window existence is
    # the reliable signal.
    log "[bg] Waiting for worker windows to spawn (signals coordinator dispatched)..."
    if ! wait_for_window 'iss-' "$COORD_TIMEOUT"; then
        err "[bg] TIMEOUT: no worker windows spawned within ${COORD_TIMEOUT}s."
        err "[bg] Check session: tmux attach -t $SESSION_NAME"
        return 1
    fi
    log "[bg] Workers dispatched. Letting coordinator finish narrating for 8s..."
    sleep 8

    local first_worker_idx
    first_worker_idx=$(tmux list-windows -t "$SESSION_NAME" \
        -F '#{window_index}:#{window_name}' \
        | grep iss- | head -1 | cut -d: -f1)
    log "[bg] Switching to worker window $first_worker_idx..."
    tmux select-window -t "$SESSION_NAME:$first_worker_idx"
    sleep "$WORKER_WATCH_SECS"

    # Beat 6: back to coordinator window, split for event log
    log "[bg] Splitting coordinator pane for event log..."
    tmux select-window -t "$SESSION_NAME:0"
    tmux split-window -v -t "$SESSION_NAME:0" -l 12 \
        "echo '=== .swarm/events.log ==='; tail -F .swarm/events.log"
    sleep "$EVENT_LOG_SECS"

    # Beat 7: gh pr list in the upper pane
    log "[bg] Showing PR list..."
    tmux select-pane -t "$SESSION_NAME:0.0"
    tmux send-keys -t "$SESSION_NAME:0.0" "clear && echo '--- Open PRs ---' && gh pr list" Enter
    sleep "$PR_LIST_SECS"

    # Beat 8: end card text
    log "[bg] Demo sequence complete!"
    tmux send-keys -t "$SESSION_NAME:0.0" \
        "echo && echo '=== Demo complete — github.com/seanoc5/llm-swarm-runner (MIT) ==='" Enter
}

# ---- Launch ----------------------------------------------------------------

log "[launch] Starting coordinator in detached session..."
# DEMO-MODE prompt. Instead of hardcoding issue numbers, instruct the coordinator
# to bias toward simple/visible work — generating new tiny issues on-the-fly if
# the backlog is short, and avoiding meaty enhancement work that would stall.
DEFAULT_PROMPT='You are operating in DEMO MODE for a screen recording.

ISSUE-GENERATION POLICY (if AVAILABLE < 3 simple swarm-ready issues):
- Create new issues inline via `gh issue create --label swarm-ready`.
- Each one MUST be: docs-only or chore-only, single-file scope, completable
  in under 2 minutes of worker time, no logic/test/CI changes. Examples:
  typo fix, missing badge, doc TL;DR, missing config file, gitignore entry.
- Skip issue creation entirely if there are already 3+ such issues open.

DISPATCH POLICY:
- Only dispatch issues labeled `swarm-ready`.
- Strongly prefer the SIMPLEST issues: docs/* and chore/* over fix/*.
- AVOID anything that looks like real product work: titles starting with
  feat:, "Coordinator-side ...", "Integrate ...", or anything labeled
  `enhancement`. These exist as real backlog and are not demo material.
- Dispatch up to MAX_WORKERS workers in this wake; the watcher refills.

CADENCE:
- After dispatching, report it in ONE concise line and idle silently.
- Do NOT ask the user for confirmation about anything.
- Do NOT propose merging or reviewing PRs — the recording is in progress.
- When the watcher wakes you with refresh prompts, apply the same demo-mode
  discipline: triage outcomes briefly, top up if slots are free, idle.'
PROMPT="${DEMO_PROMPT:-$DEFAULT_PROMPT}"
log "[launch] coordinator prompt: (demo mode — see body)"
NON_INTERACTIVE=1 "$LLM_SWARM_DIR/llm-start.sh" -w --max-workers 2 "$PROMPT" &
LLM_START_PID=$!

# Wait for session to materialize
log "[launch] Waiting for tmux session to appear..."
elapsed=0
while [ "$elapsed" -lt 15 ]; do
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    err "FATAL: session $SESSION_NAME never appeared (llm-start.sh exit code: $?)"
    kill $LLM_START_PID 2>/dev/null || true
    exit 1
fi

log "[launch] Session is live. Starting background beat driver..."
drive_beats &
DRIVER_PID=$!

# Extend the trap to clean up child processes too
cleanup_processes() {
    kill $DRIVER_PID 2>/dev/null || true
    kill $LLM_START_PID 2>/dev/null || true
}
trap cleanup_processes EXIT

log ""
log "============================================================"
log "  ATTACHING TO SESSION — START YOUR SCREEN RECORDER NOW"
log "  Press the recorder hotkey, count 3-2-1, then proceed."
log "============================================================"
sleep 2
tmux attach -t "$SESSION_NAME"

log ""
log "[done] You detached. Demo session $SESSION_NAME is still alive."
log "To fully clean up:"
log "  tmux kill-session -t $SESSION_NAME"
log "  rm -rf .swarm/"
log "  gh pr list --json number --jq '.[].number' | xargs -I {} gh pr close {} --delete-branch"
