#!/usr/bin/env bash
#
# coordinator-watch.sh — wake the coordinator on worker-finished events.
#
# Long-running daemon. Watches every worker's `.swarm/tasks/done/` dir
# under the given project. When a new outcome JSON appears there (i.e. a
# worker finished a task), wakes the coordinator via `llm-start.sh` so
# it can triage / re-dispatch / merge / etc.
#
# Pairs with the queued protocol from worker-listener.sh — proves the
# "event-driven coordinator" upgrade path described in the README.
#
# Usage:
#   coordinator-watch.sh [project-dir]
#
# Env vars:
#   DEBOUNCE_SECS=30        Window during which repeated events coalesce
#                           into a single coordinator wake. Prevents runaway
#                           when many workers finish near-simultaneously.
#   DRY_RUN=0               Set to 1 to log what would happen without
#                           actually invoking llm-start.sh.
#   ONCE=0                  Set to 1 to exit after first successful wake.
#                           Useful for smoke-testing.
#   LLM_START=<path>        Override path to llm-start.sh.
#   WAKE_PROMPT=<text>      Prompt sent to the coordinator on wake.
#   POLL_SECS=2             Polling interval (used only in polling-mode
#                           fallback when inotifywait is unavailable).
#   POST_OUTCOMES=0         Set to 1 to also run sweep-swarm-outcomes.sh
#                           on each detected outcome. Posting is naturally
#                           idempotent via .posted markers, so this fires
#                           outside the wake-debounce window — every
#                           outcome gets audit coverage even when wakes
#                           are coalesced. Honors $OUTCOME_HOOK; falls
#                           back to dry-run stub if unset.
#   SWEEP=<path>            Override path to sweep-swarm-outcomes.sh.
#   WATCHER_AUTOCLOSE=1     Set to 0 to disable automatic cleanup of
#                           finalized workers before each coord.wake. When
#                           enabled (default), invokes
#                             kill-finished-workers.sh --pr-finalized \
#                                 --with-worktree --yes
#                           so workers whose PRs are MERGED *or* CLOSED
#                           fully reap (window + worktree + local branch)
#                           and free their slot. OPEN PRs and "no PR yet"
#                           cases are left untouched. CLOSED PRs are
#                           treated as terminal — the user said no — but
#                           origin/fix/issue-N is preserved by
#                           kill-worktree.sh, so accidental closures are
#                           recoverable via `gh pr reopen N`.
#
# Watch backend (auto-detected):
#   - inotifywait (preferred): instant response. Install with:
#       sudo apt install inotify-tools
#     and bump inotify watches if you watch large repos:
#       sudo sysctl fs.inotify.max_user_watches=524288
#   - polling find (fallback): ~2s latency. No dependencies.

set -euo pipefail

# --- Help / usage ---
case "${1:-}" in
    -h|--help)
        cat <<EOF
coordinator-watch.sh — Wake the coordinator on worker-finished events

USAGE
    coordinator-watch.sh [project-dir]

ARGUMENTS
    project-dir     Path to project root (default: \$PWD)

DESCRIPTION
    Long-running daemon. Watches every worker's .swarm/tasks/done/ dir
    under the workspace (parent of project-dir). When a new outcome JSON
    appears, wakes the coordinator via llm-start.sh so it can triage,
    re-dispatch, and top up workers.

CONFIG  (precedence: shell env > <project>/.swarm/.env > <sandbox>/.env.example)
    DEBOUNCE_SECS       30        coalesce window for repeat events
    POLL_SECS           2         poll-mode latency (when inotify absent)
    DRY_RUN             0         log triggers, don't invoke llm-start.sh
    ONCE                0         exit after first wake (smoke-test)
    LLM_START           (auto)    override path to llm-start.sh
    WAKE_PROMPT         (top-up)  what the coordinator does on wake
    POST_OUTCOMES       0         run sweep-swarm-outcomes.sh per outcome
    OUTCOME_HOOK        (none)    path to per-outcome poster
    SWEEP               (auto)    override sweep-swarm-outcomes.sh path
    WATCHER_AUTOCLOSE   1         reap finalized workers (MERGED|CLOSED PR; window+worktree+branch) before wake
    WORKSPACE           (auto)    parent dir for wt-issue-* worktrees
    MAX_WORKERS         2         (referenced by default WAKE_PROMPT)
    MAX_TMUX_WINDOWS    10        (referenced by default WAKE_PROMPT)

DEFAULT WAKE_PROMPT (top-up mode)
    Coordinator triages outcomes, then refills workers toward MAX_WORKERS
    (capped by MAX_TMUX_WINDOWS) using the @me-or-unassigned filter.
    Set WAKE_PROMPT explicitly to revert to triage-only behavior.

EVENTS LOG
    Appends to <project>/.swarm/events.log:
      watch.start          boot banner with backend + caps
      worker.finish        outcome JSON detected (issue, ok|err) — fired only
                           for worktrees registered with this PROJECT_DIR
      worker.finish.skip   outcome JSON detected for a foreign worktree
                           (sibling repo sharing the same WORKSPACE parent)
      coord.wake           llm-start.sh invoked (or coord.wake.skip on debounce)
      sweep.run            sweep-swarm-outcomes.sh fired (when POST_OUTCOMES=1)
      watch.autoclose      kill-finished-workers.sh invoked (when WATCHER_AUTOCLOSE=1)
      cap.refused          provision-worker.sh hit MAX_WORKERS / MAX_TMUX_WINDOWS

BACKEND
    Auto-detects inotifywait (instant) or falls back to polling find
    (POLL_SECS latency). Install inotify-tools for instant wakes.

EXAMPLES
    coordinator-watch.sh                                # watch \$PWD
    DRY_RUN=1 coordinator-watch.sh                      # log only, no wakes
    POST_OUTCOMES=1 OUTCOME_HOOK=/path coordinator-watch.sh   # + auditing
EOF
        exit 0
        ;;
esac

PROJECT_DIR="$(realpath "${1:-$PWD}")"
# Worker worktrees are siblings of PROJECT_DIR (provision-worker.sh creates
# them at <parent>/wt-issue-N), so the watch must scan the parent — not
# PROJECT_DIR itself. Override with WORKSPACE=<dir> for non-standard layouts.
WORKSPACE="$(realpath "${WORKSPACE:-$(dirname "$PROJECT_DIR")}")"
# Self-locate so defaults follow the script wherever it lives. LLM_START and
# SWEEP env overrides still win for non-standard installs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"

# Apply <project>/.swarm/.env then sandbox .env.example before reading
# tunables, so caller env > project file > sandbox defaults. This script
# is normally inheriting from the tmux session env (set up by llm-start.sh),
# but the explicit load lets us run it standalone too.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

DEBOUNCE_SECS="${DEBOUNCE_SECS:-30}"
DRY_RUN="${DRY_RUN:-0}"
ONCE="${ONCE:-0}"
LLM_START="${LLM_START:-$LLM_SWARM_DIR/llm-start.sh}"
# Default wake prompt: top-up mode. The coordinator triages, then refills
# alive worker count toward MAX_WORKERS (subject to MAX_TMUX_WINDOWS) using
# the AVAILABLE filter defined in prompts/coordinator.md. To suppress
# auto-provisioning (old conservative default), set WAKE_PROMPT explicitly
# or invoke with INCLUDE_ASSIGNED_TO_OTHERS / triage-only language.
WAKE_PROMPT="${WAKE_PROMPT:-Worker(s) just finished. Triage their outcome JSONs in worktrees/.swarm/tasks/done/, then top up workers per the Initial Startup Checklist (compute AVAILABLE, count alive workers, fill open slots up to MAX_WORKERS subject to MAX_TMUX_WINDOWS). Use the @me-or-unassigned filter unless INCLUDE_ASSIGNED_TO_OTHERS=1.}"
POLL_SECS="${POLL_SECS:-2}"
POST_OUTCOMES="${POST_OUTCOMES:-0}"
SWEEP="${SWEEP:-$LLM_SWARM_DIR/scripts/sweep-swarm-outcomes.sh}"
WATCHER_AUTOCLOSE="${WATCHER_AUTOCLOSE:-1}"
KILL_FINISHED="${KILL_FINISHED:-$LLM_SWARM_DIR/scripts/kill-finished-workers.sh}"

# Append-only structured event log. Every observable event (start, outcome,
# wake, sweep, cap-refusal) gets a single line so `tail -F` gives live status.
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true

# log_event <category> <key=val>...
# Writes one line: "<utc-iso8601>  <category>  k=v k=v ..."
# Failures are non-fatal — log writes never break watcher work.
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

# Validation
[ -d "$PROJECT_DIR" ] || { echo "ERROR: not a directory: $PROJECT_DIR" >&2; exit 1; }
[ -d "$WORKSPACE" ]   || { echo "ERROR: workspace not a directory: $WORKSPACE" >&2; exit 1; }
[ -x "$LLM_START" ]   || { echo "ERROR: llm-start.sh not executable: $LLM_START" >&2; exit 1; }
if [ "$POST_OUTCOMES" = "1" ]; then
    [ -x "$SWEEP" ] || { echo "ERROR: sweep script not executable: $SWEEP" >&2; exit 1; }
fi
if [ "$WATCHER_AUTOCLOSE" = "1" ] && [ ! -x "$KILL_FINISHED" ]; then
    echo "WARN: WATCHER_AUTOCLOSE=1 but kill-finished-workers.sh not executable: $KILL_FINISHED" >&2
    echo "      Disabling autoclose; set WATCHER_AUTOCLOSE=0 to silence this." >&2
    WATCHER_AUTOCLOSE=0
fi

# Pick a backend
BACKEND="poll"
if command -v inotifywait >/dev/null 2>&1; then
    BACKEND="inotify"
fi

# Banner
cat <<EOF
=== coordinator-watch.sh ===
project:       $PROJECT_DIR
workspace:     $WORKSPACE (scanning $WORKSPACE/wt-issue-*/.swarm/tasks/done/)
backend:       $BACKEND$([ "$BACKEND" = "poll" ] && echo " (install inotify-tools for instant response)")
debounce:      ${DEBOUNCE_SECS}s
poll interval: ${POLL_SECS}s$([ "$BACKEND" = "inotify" ] && echo " (unused in inotify mode)")
llm-start.sh:  $LLM_START
post-outcomes: $POST_OUTCOMES$([ "$POST_OUTCOMES" = "1" ] && echo " (sweep: $SWEEP, hook: ${OUTCOME_HOOK:-default dry-run stub})")
autoclose:     $WATCHER_AUTOCLOSE$([ "$WATCHER_AUTOCLOSE" = "1" ] && echo " (script: $KILL_FINISHED)")
dry-run:       $DRY_RUN
once:          $ONCE

EOF
[ "$BACKEND" = "poll" ] && echo "Press Ctrl-C to stop. Polling every ${POLL_SECS}s for new outcome JSONs..." || \
    echo "Press Ctrl-C to stop. Listening for create/moved_to events..."
echo ""

log_event watch.start \
    "project=$PROJECT_DIR backend=$BACKEND debounce=${DEBOUNCE_SECS}s max_workers=${MAX_WORKERS:-?} max_tmux_windows=${MAX_TMUX_WINDOWS:-?}"

# Shared state
LAST_WAKE=0

# is_our_worktree <outcome-path>
#
# Filter cross-talk from sibling repos that share the same WORKSPACE parent
# (e.g., /opt/work/oconeco/ holds wt-issue-* worktrees for fand-guide,
# fand-etl, fand-app, fand-poc). Without this filter, a worker finishing in
# any sibling repo wakes EVERY coordinator running under the same parent.
#
# Returns 0 (caller treats as "ours, fire") if the outcome's containing
# worktree is registered with $PROJECT_DIR's git. Returns 1 otherwise.
#
# Fail-open policy: if `git worktree list` errors out (PROJECT_DIR isn't a
# git repo, git missing, etc.), we treat all events as ours. Preserves the
# pre-patch behavior for non-git or broken-install setups — the filter
# only adds scoping when it can verify scoping.
is_our_worktree() {
    local path="$1"
    local worktree_root
    # Strip "/.swarm/tasks/done/<file>.json" suffix to get the worktree root.
    worktree_root="$(echo "$path" | sed -E 's|/\.swarm/tasks/done/[^/]+$||')"

    local wt_list
    wt_list="$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')" || return 0
    [ -z "$wt_list" ] && return 0

    grep -Fxq "$worktree_root" <<< "$wt_list"
}

# dispatch_outcome <outcome-path>
#
# Wrapper around on_outcome that applies the is_our_worktree filter.
# Used by both inotify and poll backends so the scoping logic lives in
# exactly one place.
dispatch_outcome() {
    local path="$1"
    if is_our_worktree "$path"; then
        on_outcome "$path"
    else
        local issue
        issue=$(basename "$path" | sed -E 's/.*-([0-9]+)\.(ok|err)\.json$/\1/')
        log_event worker.finish.skip "issue=$issue reason=foreign_worktree path=$path"
    fi
}

# cleanup_eligible_workers
#
# Full reap of workers whose PR has reached a terminal GitHub state —
# either MERGED (work landed) or CLOSED (work rejected/superseded). Kills
# the tmux window, removes the worktree, deletes the local branch. Called
# inside on_outcome (after debounce passes, before coord.wake) so freed
# slots show up in the coordinator's window/alive count on its next wake.
#
# Uses --pr-finalized + --with-worktree. CLOSED-without-merge is treated
# as terminal because the human explicitly said "not this work" — keeping
# the listener parked just burns a slot. Recovery is cheap if the closure
# was accidental: kill-worktree.sh only deletes the LOCAL branch (never
# pushes a delete), so origin/fix/issue-N survives and `gh pr reopen N`
# restores the PR.
#
# OPEN PRs and "no PR yet" cases are left untouched — those represent
# work the user may still want to land or babysit.
#
# This is the smooth-flow contract: PR reaches a terminal state -> watcher
# reaps everything -> slot fully free for the next dispatch. No manual
# scripts.
#
# Failures are non-fatal — the watcher's job is wake the coordinator, and
# the coordinator can still JIT-reap and/or report cap-reached if cleanup
# didn't fire.
cleanup_eligible_workers() {
    local dry_arg=""
    [ "$DRY_RUN" = "1" ] && dry_arg="--dry-run"

    # We deliberately discard stdout/stderr — kill-finished-workers.sh has
    # its own verbose output; we only care about the side effect (windows
    # + worktrees + branches reaped). The autoclose event in our log
    # records that we ran.
    "$KILL_FINISHED" --idle-min 0 --pr-finalized --with-worktree --yes $dry_arg >/dev/null 2>&1 || true
    log_event watch.autoclose "trigger=outcome mode=pr-finalized+worktree dry_run=$DRY_RUN"
}

# Trigger logic — called when a NEW outcome JSON path is observed
on_outcome() {
    local path="$1"
    local now issue outcome
    now=$(date +%s)

    # Parse outcome filename: <task-id>-<issue>.<ok|err>.json
    issue=$(basename "$path" | sed -E 's/.*-([0-9]+)\.(ok|err)\.json$/\1/')
    case "$path" in
        *.ok.json)  outcome=ok ;;
        *.err.json) outcome=err ;;
        *)          outcome=unknown ;;
    esac
    log_event worker.finish "issue=$issue outcome=$outcome path=$path"

    # Audit posting fires for EVERY outcome (not gated by wake-debounce).
    # The sweep is idempotent via .posted markers, so repeated calls are
    # cheap, and we don't want auditing to be coalesced — every finished
    # task should get its comment posted.
    if [ "$POST_OUTCOMES" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date +%T)] [DRY] would: $SWEEP $PROJECT_DIR"
            log_event sweep.dry "issue=$issue"
        else
            echo "[$(date +%T)] sweep: posting outcomes…"
            log_event sweep.run "issue=$issue"
            "$SWEEP" "$PROJECT_DIR" || {
                echo "[$(date +%T)] WARN: sweep returned non-zero (continuing watch)"
                log_event sweep.error "issue=$issue"
            }
        fi
    fi

    if [ $((now - LAST_WAKE)) -lt "$DEBOUNCE_SECS" ]; then
        echo "[$(date +%T)] outcome: $path — within debounce window (${DEBOUNCE_SECS}s), skipping wake"
        log_event coord.wake.skip "issue=$issue reason=debounce window=${DEBOUNCE_SECS}s"
        return
    fi

    # Free slots from parked + PR-safe workers (PRs merged/closed) before
    # the coordinator wakes — otherwise its slot computation sees stale
    # alive-worker counts and reports cap-reached when wave 2 should fire.
    if [ "$WATCHER_AUTOCLOSE" = "1" ]; then
        echo "[$(date +%T)] running autoclose pass before wake..."
        cleanup_eligible_workers
    fi

    echo "[$(date +%T)] outcome: $path"
    echo "[$(date +%T)] waking coordinator..."
    log_event coord.wake "issue=$issue trigger=$(basename "$path")"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START \"$WAKE_PROMPT\""
    else
        # Run llm-start.sh in a subshell so its `set -e` doesn't kill us.
        # NON_INTERACTIVE=1 prevents auto-attach; coordinator runs detached
        # in its tmux session.
        ( cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$WAKE_PROMPT" ) || {
            echo "[$(date +%T)] WARN: coordinator wake exited non-zero (continuing watch)"
            log_event coord.wake.error "issue=$issue"
        }
    fi
    LAST_WAKE=$now

    if [ "$ONCE" = "1" ]; then
        echo "[$(date +%T)] ONCE=1 — exiting after first wake."
        log_event watch.exit "reason=once"
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Backend: inotify
# ---------------------------------------------------------------------------
run_inotify() {
    # Watch the workspace (parent of project) recursively, filtering events
    # to only outcomes inside wt-issue-*/.swarm/tasks/done/. The listener
    # does `mv processing/X.md done/X.md` followed by writing done/X.json —
    # both surface as create/moved_to events.
    #
    # --exclude noisy dirs to keep watch count low.
    inotifywait -m -r \
        --exclude '/(\.git|node_modules|build|target|\.gradle|dist|out|\.next|\.venv|venv)(/|$)' \
        -e create -e moved_to \
        --format '%w%f' \
        "$WORKSPACE" 2>/dev/null \
    | while IFS= read -r path; do
        case "$path" in
            */wt-issue-*/.swarm/tasks/done/*.ok.json|*/wt-issue-*/.swarm/tasks/done/*.err.json)
                dispatch_outcome "$path"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Backend: polling (find)
# ---------------------------------------------------------------------------
run_poll() {
    # Build a baseline of currently-known outcome JSONs so we don't fire
    # for anything that existed before the watcher started.
    # NOTE: seen_file is intentionally script-global (no `local`) so the
    # EXIT/INT/TERM trap can reach it even if a signal arrives outside of
    # run_poll's stack frame. The :- guard handles the early-shutdown case
    # where the signal fires before mktemp ran.
    seen_file=$(mktemp -t coord-watch-seen-XXXXXX)
    trap '[ -n "${seen_file:-}" ] && rm -f -- "$seen_file"' EXIT INT TERM

    # Scan only wt-issue-*/.swarm/tasks/done dirs under WORKSPACE. The glob
    # may expand to nothing if no worker worktrees exist yet — handle that
    # gracefully via nullglob so the find call gets an empty arg list.
    scan_outcomes() {
        local done_dirs=()
        shopt -s nullglob
        done_dirs=("$WORKSPACE"/wt-issue-*/.swarm/tasks/done)
        shopt -u nullglob
        if [ "${#done_dirs[@]}" -eq 0 ]; then
            return 0   # no worker worktrees — emit empty
        fi
        find "${done_dirs[@]}" -maxdepth 1 \
            \( -name '*.ok.json' -o -name '*.err.json' \) -print 2>/dev/null \
            | sort -u
    }

    scan_outcomes > "$seen_file"

    while true; do
        local current diff_new
        current=$(scan_outcomes)

        # New paths = in current, not in seen. Guard against the shutdown
        # race where the EXIT trap removes seen_file mid-iteration.
        [ -f "$seen_file" ] || break
        diff_new=$(comm -23 <(echo "$current") "$seen_file" 2>/dev/null || true)
        if [ -n "$diff_new" ]; then
            while IFS= read -r path; do
                [ -z "$path" ] && continue
                dispatch_outcome "$path"
            done <<< "$diff_new"
            echo "$current" > "$seen_file"
        fi

        sleep "$POLL_SECS"
    done
}

case "$BACKEND" in
    inotify) run_inotify ;;
    poll)    run_poll ;;
esac
