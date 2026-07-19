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
#   WATCH_PR_POLL_SECS=60   (issue #119) The outcome-driven trigger above
#                           only fires when a NEW outcome.json appears —
#                           but outcome.json is written once, usually
#                           right after the PR is opened. A PR that merges
#                           later (parked interactive worker, or the user
#                           batch-merging while away) never produces a
#                           second outcome.json, so the reap pass never
#                           re-runs for it. This knob starts an independent
#                           background timer that, every N seconds, runs a
#                           single `gh pr list --state all` call across all
#                           worker branches and re-fires the WATCHER_AUTOCLOSE
#                           reap pass if any tracked worktree's PR has gone
#                           MERGED/CLOSED. Set to 0 to disable (falls back to
#                           the original outcome-only behavior). Gated by
#                           WATCHER_AUTOCLOSE — if that's 0, detection still
#                           logs but no reap fires. Same poll also powers the
#                           check-on-done PR-open backstop (see
#                           WATCH_CHECK_ON_DONE).
#   WATCH_CHECK_ON_DONE=1   Set to 0 to disable check-on-done. When enabled,
#                           the watcher treats a worker as "done" via either
#                           signal: (a) a `.swarm/tasks/status/<id>.json`
#                           file with state "ready-for-review" (fast path,
#                           polled every 2s), or (b) a PR appearing on
#                           fix/issue-N with no status file (backstop, via
#                           the WATCH_PR_POLL_SECS poll). On first done
#                           signal per task (atomic claim via mkdir — losing
#                           path no-ops), resolves the same acceptance check
#                           worker-listener.sh would (brief marker ->
#                           .swarm/check.sh -> WORKER_CHECK_CMD) and runs it
#                           once in a visible tmux window `chk-N`, recording
#                           the result to `<id>.check.json` and events.log.
#   CHECK_RUNNER=<path>     Test-only override: when set, check-on-done runs
#                           `$CHECK_RUNNER <worktree> <check_cmd>` synchronously
#                           instead of spawning a real tmux window. Lets tests
#                           exercise the claim/resolve/record logic without a
#                           live tmux session.
#   SESSION_NAME=<name>     tmux session check-on-done spawns chk-N windows
#                           in. Default: llm-$(basename PROJECT_DIR), matching
#                           kill-finished-workers.sh / provision-worker.sh.
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
    WATCH_PR_POLL_SECS  60        periodic gh-poll backstop reap (0=off); see header comment
    WATCH_CHECK_ON_DONE 1         run acceptance check when a worker signals done; see header comment
    SESSION_NAME        (auto)    tmux session for chk-N windows (llm-<project-basename>)
    WORKSPACE           (auto)    parent dir for wt-issue-* worktrees
    MAX_WORKERS         5         (referenced by default WAKE_PROMPT)
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
      watch.autoclose      kill-finished-workers.sh invoked (trigger=outcome|pr_poll)
      watch.timer.start    background pr-poll/check-on-done timer loop started
      watch.pr_poll        terminal PR detected via periodic gh poll (reap backstop)
      watch.check_on_done  check-on-done result (issue, task_id, result=running|pass|fail|skipped)
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
# Self-locate so defaults follow the script wherever it lives. LLM_START and
# SWEEP env overrides still win for non-standard installs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"

# Apply <project>/.swarm/.env then sandbox .env.example before reading
# tunables, so caller env > project file > sandbox defaults. This script
# is normally inheriting from the tmux session env (set up by llm-start.sh),
# but the explicit load lets us run it standalone too. The sourced file
# also defines swarm_worktree_parent() which we use below to derive the
# scan directory in a way that honors SWARM_WORKTREE_GROUPING.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

# Worker worktrees live at $(swarm_worktree_parent)/wt-issue-N — that's
# either <parent>/wt-issue-N (flat grouping, default) or
# <parent>/<project>-worktrees/wt-issue-N (project grouping; multi-swarm
# hosts). Calling the helper avoids drifting from provision-worker.sh.
# Override with WORKSPACE=<dir> for non-standard layouts.
WORKSPACE="$(realpath "${WORKSPACE:-$(swarm_worktree_parent "$PROJECT_DIR")}")"

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
WATCH_PR_POLL_SECS="${WATCH_PR_POLL_SECS:-60}"
WATCH_CHECK_ON_DONE="${WATCH_CHECK_ON_DONE:-1}"
CHECK_RUNNER="${CHECK_RUNNER:-}"
SESSION_NAME="${SESSION_NAME:-llm-$(basename "$PROJECT_DIR")}"

if ! [[ "$WATCH_PR_POLL_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WATCH_PR_POLL_SECS must be a non-negative integer (got: $WATCH_PR_POLL_SECS)" >&2
    exit 1
fi

# jq is optional throughout this codebase (see worker-listener.sh's
# append_eval_log). status_poll_pass/maybe_run_check parse status-file JSON
# with it; under `set -e`, an unguarded `var=$(jq ...)` with jq missing
# would silently kill the background timer loop's subshell. Guard instead
# of hard-requiring it — the PR-open backstop degrades gracefully to a
# synthetic per-issue claim key, and the status-file fast path just no-ops.
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

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
pr-poll:       ${WATCH_PR_POLL_SECS}s$([ "$WATCH_PR_POLL_SECS" = "0" ] && echo " (disabled)")
check-on-done: $WATCH_CHECK_ON_DONE$([ "$WATCH_CHECK_ON_DONE" = "1" ] && echo " (session: $SESSION_NAME)")
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
#
# trigger (default "outcome"): who called us, for the events.log line.
# "outcome" = fired from on_outcome (a new outcome.json arrived); "pr_poll"
# = fired from the WATCH_PR_POLL_SECS backstop (issue #119) — same cleanup,
# different reason it ran.
cleanup_eligible_workers() {
    local trigger="${1:-outcome}"
    local dry_arg=""
    [ "$DRY_RUN" = "1" ] && dry_arg="--dry-run"

    # We deliberately discard stdout/stderr — kill-finished-workers.sh has
    # its own verbose output; we only care about the side effect (windows
    # + worktrees + branches reaped). The autoclose event in our log
    # records that we ran.
    "$KILL_FINISHED" --idle-min 0 --pr-finalized --with-worktree --yes $dry_arg >/dev/null 2>&1 || true
    log_event watch.autoclose "trigger=$trigger mode=pr-finalized+worktree dry_run=$DRY_RUN"
}

# pr_poll_pass
#
# Behavior A backstop (issue #119): the outcome-driven reap above only
# fires when a NEW outcome.json appears, but outcome.json is written once
# — usually right after the PR opens, well before it merges. A worker
# that's parked (interactive REPL still open) or whose listener already
# exited never produces a second outcome.json, so a PR merging later never
# re-triggers the reap. This runs on its own timer (WATCH_PR_POLL_SECS),
# independent of the outcome-driven backend, so it fires even when that
# backend is blocked waiting on filesystem events that will never come.
#
# One `gh pr list --state all` call covers every worker branch in a single
# API round-trip (vs. kill-finished-workers.sh's N per-window `gh pr view`
# calls) — cheap enough to run every 60s indefinitely (~60 req/hr).
#
# Also drives the Behavior B (check-on-done) PR-open backstop: any branch
# with a PR at all (regardless of state) counts as "done" for a worker
# that never wrote a status file.
pr_poll_pass() {
    local prs
    prs="$(cd "$PROJECT_DIR" && gh pr list --state all --limit 500 \
            --json headRefName,state,number \
            --jq '.[] | "\(.headRefName)\t\(.state)\t\(.number)"' 2>/dev/null)" || {
        log_event pr_poll.error "reason=gh_pr_list_failed"
        return 0
    }
    [ -n "$prs" ] || return 0

    local reap_hit=0 branch state pr_number issue wt_dir
    while IFS=$'\t' read -r branch state pr_number; do
        [ -z "$branch" ] && continue
        case "$branch" in
            fix/issue-*) : ;;
            *) continue ;;
        esac
        issue="${branch#fix/issue-}"
        [[ "$issue" =~ ^[0-9]+$ ]] || continue
        wt_dir="$WORKSPACE/wt-issue-$issue"
        [ -d "$wt_dir" ] || continue   # already reaped, or never provisioned here

        if [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]; then
            reap_hit=1
        fi

        if [ "$WATCH_CHECK_ON_DONE" = "1" ]; then
            maybe_run_check "$wt_dir" "$issue"
        fi
    done <<< "$prs"

    if [ "$reap_hit" = "1" ]; then
        log_event watch.pr_poll "reason=terminal_pr_detected"
        if [ "$WATCHER_AUTOCLOSE" = "1" ]; then
            echo "[$(date +%T)] pr-poll: terminal PR(s) detected on unreaped worktree(s) — running autoclose"
            cleanup_eligible_workers pr_poll
        else
            echo "[$(date +%T)] pr-poll: terminal PR(s) detected but WATCHER_AUTOCLOSE=0 — not reaping"
        fi
    fi
}

# status_poll_pass
#
# Behavior B fast path (issue #119): scan every worktree's
# .swarm/tasks/status/ dir (worker->coordinator "done" declaration, see
# issue #129) for a state of "ready-for-review" and fire the acceptance
# check. Cheap (local filesystem only), so this runs every 2s from the
# timer loop regardless of WATCH_PR_POLL_SECS.
status_poll_pass() {
    [ "$HAVE_JQ" = "1" ] || return 0
    shopt -s nullglob
    local f wt_dir issue state
    for f in "$WORKSPACE"/wt-issue-*/.swarm/tasks/status/*.json; do
        case "$f" in *.check.json) continue ;; esac
        wt_dir="${f%/.swarm/tasks/status/*}"
        issue="$(basename "$wt_dir")"; issue="${issue#wt-issue-}"
        state=$(jq -r '.state // empty' "$f" 2>/dev/null) || continue
        if [ "$state" = "ready-for-review" ]; then
            maybe_run_check "$wt_dir" "$issue"
        fi
    done
    shopt -u nullglob
}

# maybe_run_check <worktree-dir> <issue>
#
# Resolve + claim + run the acceptance check for a worker that has
# signaled done (either status-poll_pass or pr_poll_pass called us). Both
# callers converge here so a task that fires both signals in the same
# window only runs its check once — the claim is an atomic `mkdir`
# (kernel-level single-writer), and both callers derive the SAME claim key
# by re-reading the worktree's own status file (if one exists) rather than
# trusting whatever the caller happened to pass in.
maybe_run_check() {
    local wt_dir="$1" issue="$2"
    local status_dir="$wt_dir/.swarm/tasks/status"
    mkdir -p "$status_dir" 2>/dev/null || return 0

    # Prefer the task_id from the worker's own status file (mirrors what
    # status_poll_pass just read) so the PR-open backstop and the fast
    # status-file path land on the same claim key when both fire close
    # together. No status file yet (worker never wrote one, or #129 isn't
    # deployed here) → synthesize a per-issue key so the backstop still
    # works standalone.
    local task_id="" latest
    latest=$(find "$status_dir" -maxdepth 1 -name '*.json' -not -name '*.check.json' 2>/dev/null | sort | tail -1)
    if [ -n "$latest" ] && [ "$HAVE_JQ" = "1" ]; then
        task_id=$(jq -r '.task_id // empty' "$latest" 2>/dev/null) || task_id=""
    fi
    [ -n "$task_id" ] || task_id="pr-issue-$issue"

    local claim_dir="$status_dir/${task_id}.check-claim"
    mkdir "$claim_dir" 2>/dev/null || return 0   # already claimed — nothing to do

    local check_json="$status_dir/${task_id}.check.json"
    printf '{"task_id":"%s","state":"checking","check_exit":null,"ts":"%s"}\n' \
        "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true

    # Resolve the check command the same order worker-listener.sh does:
    #   1. brief marker in the task file (processing/ if still parked,
    #      done/ if the listener already archived it)
    #   2. standing per-issue check in the worktree
    #   3. listener-wide env default
    local check_cmd="" brief
    brief=$(find "$wt_dir/.swarm/tasks/processing" "$wt_dir/.swarm/tasks/done" \
                -maxdepth 1 -name "${task_id}*.md" 2>/dev/null | head -1)
    if [ -n "$brief" ]; then
        check_cmd=$(sed -n 's/.*<!-- SWARM_CHECK: \(.*\) -->.*/\1/p' "$brief" | head -1)
    fi
    if [ -z "$check_cmd" ] && [ -r "$wt_dir/.swarm/check.sh" ]; then
        check_cmd="bash .swarm/check.sh"
    fi
    [ -z "$check_cmd" ] && check_cmd="${WORKER_CHECK_CMD:-}"

    if [ -z "$check_cmd" ]; then
        printf '{"task_id":"%s","state":"skipped","check_exit":null,"ts":"%s"}\n' \
            "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
        log_event watch.check_on_done "issue=$issue task_id=$task_id result=skipped reason=no_check_resolved"
        return 0
    fi

    log_event watch.check_on_done "issue=$issue task_id=$task_id result=running"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[$(date +%T)] [DRY] check-on-done issue #$issue (task $task_id): $check_cmd"
        printf '{"task_id":"%s","state":"skipped","check_exit":null,"ts":"%s"}\n' \
            "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
        return 0
    fi

    execute_check "$wt_dir" "$issue" "$task_id" "$check_cmd" "$check_json"
}

# record_check_result <task_id> <issue> <check_json> <exit-code>
#
# Single place that writes the watcher-owned <task_id>.check.json + the
# events.log line, so both the synchronous CHECK_RUNNER (test) path and
# the real tmux path record results identically.
record_check_result() {
    local task_id="$1" issue="$2" check_json="$3" rc="$4"
    local state="pass"
    [ "$rc" -eq 0 ] || state="fail"
    printf '{"task_id":"%s","state":"%s","check_exit":%d,"ts":"%s"}\n' \
        "$task_id" "$state" "$rc" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
    log_event watch.check_on_done "issue=$issue task_id=$task_id result=$state check_exit=$rc"
}

# execute_check <worktree-dir> <issue> <task_id> <check-cmd> <check-json>
#
# Runs the resolved check exactly once (claim already taken by the caller)
# and records the result. Two backends:
#   - CHECK_RUNNER set (tests): synchronous — run "$CHECK_RUNNER <worktree>
#     <check_cmd>", record the result immediately via record_check_result.
#     No tmux dependency.
#   - default: spawn a visible tmux window `chk-N` (mirrors provision-worker.sh's
#     `iss-N` windows) so the operator can watch/scroll back the run. The
#     window's own shell writes the result files directly (it's a separate
#     process — it can't call back into this script's bash functions), using
#     the identical two-line shape record_check_result writes, kept in sync
#     by comment cross-reference rather than by sharing code across processes.
execute_check() {
    local wt_dir="$1" issue="$2" task_id="$3" check_cmd="$4" check_json="$5"

    if [ -n "$CHECK_RUNNER" ]; then
        local rc=0
        "$CHECK_RUNNER" "$wt_dir" "$check_cmd" || rc=$?
        record_check_result "$task_id" "$issue" "$check_json" "$rc"
        return 0
    fi

    if ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log_event watch.check_on_done "issue=$issue task_id=$task_id result=skipped reason=no_tmux_session"
        printf '{"task_id":"%s","state":"skipped","check_exit":null,"ts":"%s"}\n' \
            "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
        return 0
    fi

    local win="chk-$issue"
    local timeout_secs="${WORKER_CHECK_TIMEOUT:-600}"
    # Mirrors record_check_result's output shape exactly — see that
    # function if this drifts.
    tmux new-window -d -t "$SESSION_NAME" -n "$win" -c "$wt_dir" bash -c "
        echo '--- check-on-done: issue #$issue (task $task_id) ---'
        echo 'check: $check_cmd'
        timeout $timeout_secs bash -c '$check_cmd'
        rc=\$?
        state=pass; [ \$rc -eq 0 ] || state=fail
        ts=\$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        printf '{\"task_id\":\"%s\",\"state\":\"%s\",\"check_exit\":%d,\"ts\":\"%s\"}\n' '$task_id' \"\$state\" \$rc \"\$ts\" > '$check_json'
        printf '%s  %-15s %s\n' \"\$ts\" 'watch.check_on_done' \"issue=$issue task_id=$task_id result=\$state check_exit=\$rc\" >> '$EVENTS_LOG'
        echo \"--- check \$state (exit \$rc) — this window stays open for review ---\"
        exec bash
    " 2>/dev/null || log_event watch.check_on_done.error "issue=$issue task_id=$task_id reason=tmux_new_window_failed"
}

# run_watch_timer_loop
#
# Single background process driving both Behavior A (WATCH_PR_POLL_SECS)
# and Behavior B fast-path (2s status-file poll). One process (not two)
# to keep trap-based cleanup simple — see the trap wired up near the
# bottom of the script.
run_watch_timer_loop() {
    local last_pr_poll=0 now
    while true; do
        sleep 2
        [ "$WATCH_CHECK_ON_DONE" = "1" ] && { status_poll_pass || true; }
        if [ "$WATCH_PR_POLL_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_pr_poll)) -ge "$WATCH_PR_POLL_SECS" ]; then
                pr_poll_pass || true
                last_pr_poll=$now
            fi
        fi
    done
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
        cleanup_eligible_workers outcome
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
    # shared EXIT/INT/TERM trap (set once, near the bottom of the script —
    # see cleanup_on_exit) can reach it even if a signal arrives outside of
    # run_poll's stack frame. Deliberately NOT setting a trap here: bash
    # traps are process-wide, so a second `trap ... EXIT` here would
    # silently replace the one that also kills the background timer loop.
    seen_file=$(mktemp -t coord-watch-seen-XXXXXX)

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

# ---------------------------------------------------------------------------
# Timer loop startup (issue #119) — independent of the outcome-driven
# backend selected above. Started here (after every function it calls is
# defined, and after the backend case below so shutdown ordering doesn't
# matter) so it's live before we block in run_inotify/run_poll.
# ---------------------------------------------------------------------------
WATCH_TIMER_PID=""
if [ "$WATCH_PR_POLL_SECS" -gt 0 ] || [ "$WATCH_CHECK_ON_DONE" = "1" ]; then
    run_watch_timer_loop &
    WATCH_TIMER_PID=$!
    log_event watch.timer.start "pr_poll_secs=$WATCH_PR_POLL_SECS check_on_done=$WATCH_CHECK_ON_DONE"
fi

# Single shared trap for both the background timer loop and run_poll's
# seen_file (script-global — see the NOTE at its mktemp above). Set once,
# here, so nothing downstream can silently clobber it with a second
# `trap ... EXIT` and drop the timer-loop kill.
cleanup_on_exit() {
    [ -n "$WATCH_TIMER_PID" ] && kill "$WATCH_TIMER_PID" 2>/dev/null || true
    [ -n "${seen_file:-}" ] && rm -f -- "$seen_file"
}
trap cleanup_on_exit EXIT INT TERM

case "$BACKEND" in
    inotify) run_inotify ;;
    poll)    run_poll ;;
esac
