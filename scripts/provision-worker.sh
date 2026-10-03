#!/usr/bin/env bash
#
# provision-worker.sh — coordinator helper to provision a worker for an issue.
#
# Usage:   provision-worker.sh <issue-number> [project-dir]
# Example: provision-worker.sh 142
#          provision-worker.sh 142 /opt/work/oconeco/fand-api
#
# Wraps the multi-step "create worktree, init queue, build brief with
# .swarm-policy.md guardrails embedded, atomic write, spawn worker tmux
# window" workflow into a single command call. The coordinator (gemini or
# claude) invokes this once per dispatch — no $(...) substitution at the
# coordinator's tool layer, so gemini's run_shell_command guardrails are
# satisfied.
#
# Re-running for the same issue is idempotent: a pre-existing worktree
# is reused (no re-create), and the new task is queued via a fresh task
# id so the listener processes it as a follow-up.
set -euo pipefail

# --- Help / usage ---
case "${1:-}" in
    -h|--help)
        cat <<EOF
provision-worker.sh — Provision a worker for one GitHub issue

USAGE
    provision-worker.sh <issue-number> [project-dir]

ARGUMENTS
    issue-number    GitHub issue number to dispatch (required)
    project-dir     Path to project root (default: \$PWD)

DESCRIPTION
    One-call helper for the coordinator. Creates worktree at
    <worktree-parent>/wt-issue-N on branch fix/issue-N (idempotent), initializes
    -- where <worktree-parent> is either <project-parent> (the default 'flat'
    -- layout) or <project-parent>/<project>-worktrees (when
    -- SWARM_WORKTREE_GROUPING=project; recommended for multi-swarm hosts).
    the v2 queue, embeds the worker communication conventions (via
    system prompt at launch time) plus
    any project .swarm-policy.md guardrails into the brief, atomic-writes
    the task into inbox/, and spawns a worker tmux window 'iss-N' running
    the sandbox listener.

CAP ENFORCEMENT (exit 3 on any)
    MAX_WORKERS         alive iss-* windows < cap         (default 5)
    MAX_TMUX_WINDOWS    total session windows < cap       (default 10)
    HOST_MAX_WORKERS    running swarm-* containers + spawns in flight across
                        ALL swarms on this host < cap     (default 8)
    HOST_MAX_LOAD1      1-min load average <= cap         (default 1.5 x nproc)
    HOST_MIN_MEM_AVAIL_MB  MemAvailable >= floor          (default 16384)
    HOST_SPAWN_STAGGER_SECS  seconds since the last spawn on this host
                        >= gap                            (default 60)
    The four HOST_* checks run under one host-wide flock (HOST_STATE_DIR,
    default $TMPDIR/llm-swarm-host-<uid>) so concurrent coordinators can't
    each admit "one more". HOST_* keys are host facts: _load-env.sh ignores
    them in <project>/.swarm/.env; set them in <sandbox>/.env.
    All are checked BEFORE the task brief is written into inbox/ and before
    the new tmux window would be created, so a refusal leaves no brief
    behind (issue #464 — a refused-then-retried provision used to queue the
    same brief twice). The worktree itself (step 1) is still created even
    on refusal: it's harmless, and a retry reuses it instead of recreating
    it. The host cap exists because per-swarm caps don't add up: 2026-09-02
    saw 16 workers x 8 GB sandbox limit = all 128 GB of minti9's RAM.
    Re-running for an existing iss-N window does NOT count against caps —
    that path queues a follow-up task without adding capacity.

STALE BRANCH (exit 2)
    If fix/issue-N already exists as a branch but no worktree at
    <worktree-parent>/wt-issue-N is attached to it (deleted manually, left
    behind by branch sweep, or orphaned by a worktree-grouping change), the
    script decides instead of letting 'git worktree add -b' fail blind:
      - no commits beyond the default branch  -> reused automatically
      - unique commits present                -> refuses, exits 2 with a
                                                   remedy hint (never exit 0)

STALE WORKER STATE (issue #493)
    A dead-paned iss-N window (remain-on-exit=failed keeps a crashed
    window's corpse around for forensic scrollback) is reclaimed
    automatically: killed, logged (worker.dead_pane_reclaimed), then
    re-provisioned as a fresh spawn.
    A leftover container under this issue's exact name (outlived its
    window — a parked/window-only reap, a session restart, or the reclaim
    above) is stopped and removed before the new `docker run`, with a wait
    for `docker ps -a` to actually clear the name (avoids racing --rm's own
    async auto-removal). If that container's window is instead found
    genuinely alive, provisioning refuses (exit 5 — a dedicated code, since
    plain exit 2 already means "refused, nothing running" elsewhere in this
    script and this is the opposite) rather than stopping a possibly-live
    worker's container — route the brief through requeue.sh instead.
    Exits 2 if the stale container doesn't clear within
    PROVISION_STALE_CONTAINER_WAIT_SECS (default 15s).

STARTUP FAILURE (exit 4, issue #493)
    After spawning, the new pane is checked once (after
    PROVISION_SPAWN_CHECK_SECS, default 5s): a dead pane or a container
    that never came up means the spawn failed (e.g. sandbox.sh's
    `docker run` exiting immediately) even though `tmux new-window` itself
    reported success. Exits 4 with the pane's last lines printed, kills the
    window, and removes the brief step 3 already wrote to inbox/ — nothing
    claimed it, and leaving either behind would let a late-arriving pane
    park with an empty inbox, or a retry queue a duplicate brief onto the
    window — instead of the pre-#493 behavior of exiting 0 with the window
    left running and the brief silently stranded there (fand-etl
    2026-09-27: undiscovered for ~7 hours).
    PROVISION_SPAWN_CHECK_SECS=0 disables this check (for test harnesses
    that stub tmux/docker without simulating a live pane or container).
    Caveat: a cold host without the llm-swarm-runner image yet runs
    `docker build` before `docker run` (sandbox.sh), which routinely takes
    far longer than the default 5s. The check skips itself entirely in
    that case (logging a notice) rather than risk killing a build that's
    actually still in progress — so a first-ever (or post-Dockerfile-
    change) spawn on such a host gets no post-spawn verification at all
    until the image exists. Pre-build it once with
    `scripts/build-image.sh` before provisioning to get the check back on
    a cold host — not a bare `docker build`, which skips the
    dockerfile_sha label sandbox.sh checks and triggers its Dockerfile-
    drift warning (#517) on every subsequent spawn.

CONFIG  (precedence: shell env > <project>/.swarm/.env > <sandbox>/.env
         > <sandbox>/.env.example)
    MAX_WORKERS         5         worker tmux window cap
    MAX_TMUX_WINDOWS    10        total session window cap
    HOST_MAX_WORKERS    8         host-wide running worker container cap
    HOST_MAX_LOAD1      auto      host load1 ceiling (auto = 1.5 x nproc; 0 off)
    HOST_MIN_MEM_AVAIL_MB 16384   host MemAvailable floor in MB (0 off)
    HOST_SPAWN_STAGGER_SECS 60    min seconds between spawns host-wide (0 off)
    HOST_STATE_DIR      (auto)    lock + pending-spawn markers, host-wide
    SANDBOX_SH          (auto)    path to sandbox.sh used by the listener
    LLM_SWARM_DIR     (auto)    sandbox install dir
    PROVISION_SPAWN_CHECK_SECS            5   delay before the post-spawn pane health check (0 disables it)
    PROVISION_STALE_CONTAINER_WAIT_SECS   15  max wait for a stale container's name to clear

EVENTS LOG
    Appends to <project>/.swarm/events.log:
      worker.start                new iss-N window created (alive=A/MAX, total=W/MAX).
                                   Logged at spawn time, not confirmed-healthy time
                                   (coordinator-watch.sh's activity-poll anchors a
                                   paste-grace window to this timestamp, issue #497)
                                   — a worker.start.failed a few seconds later for
                                   the same issue means THIS spawn didn't survive.
      worker.requeue               existing iss-N window reused for follow-up task
      cap.refused                  MAX_WORKERS, MAX_TMUX_WINDOWS, HOST_MAX_WORKERS, host load,
                                    host memory or the spawn stagger refused the spawn (reason=)
      worker.dead_pane_reclaimed   iss-N window existed but its pane was dead; killed before re-provisioning (#493)
      provision.stale_container    pre-spawn stale-container check outcome: state=cleared/window_alive/removal_timeout (#493)
      worker.start.failed          new window's pane died (or its container never came up) right after spawn (#493).
                                   Always preceded by a worker.start for the same
                                   issue/task_id — a consumer counting successful
                                   spawns must subtract these, not just count
                                   worker.start lines. brief_removed=1 means the
                                   unclaimed brief was deleted from inbox/ to
                                   keep a retry from duplicating it.

EXAMPLES
    provision-worker.sh 142                          # dispatch issue #142 from \$PWD
    provision-worker.sh 142 /path/to/proj            # explicit project dir
EOF
        exit 0
        ;;
esac

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --) shift; break ;;
        *) echo "ERROR: unknown flag '$1' (try --help)" >&2; exit 2 ;;
    esac
done

ISSUE="${1:?usage: provision-worker.sh <issue-number> [project-dir]   (try --help)}"
PROJECT_DIR="${2:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
BRANCH="fix/issue-$ISSUE"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"
# Self-locate so SANDBOX_SH default follows the script. Override with
# SANDBOX_SH=<path> when running a non-standard install.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"
SANDBOX_SH="${SANDBOX_SH:-$LLM_SWARM_DIR/sandbox.sh}"

# Apply <project>/.swarm/.env then sandbox .env.example before reading caps,
# so caller env > project file > sandbox defaults. Normally the tmux session
# already has these exported (set by llm-start.sh), but the explicit load
# lets the script run correctly when invoked standalone. This also defines
# swarm_worktree_dir() so we can compute WT honoring SWARM_WORKTREE_GROUPING.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

# Derive worktree path AFTER env load so SWARM_WORKTREE_GROUPING is honored.
WT="$(swarm_worktree_dir "$PROJECT_DIR" "$ISSUE")"
# Ensure parent dir exists in 'project' grouping mode (the flat layout's
# parent already exists; project-grouping creates <project>-worktrees/).
mkdir -p "$(dirname "$WT")"

MAX_WORKERS="${MAX_WORKERS:-5}"
MAX_TMUX_WINDOWS="${MAX_TMUX_WINDOWS:-10}"
HOST_MAX_WORKERS="${HOST_MAX_WORKERS:-8}"

# Worker conventions (`prompts/worker.md`) are delivered as a system prompt
# by the listener at claude/gemini launch time — see scripts/worker-listener.sh.
# Briefs no longer carry them verbatim; this script only assembles the
# per-task payload (refs index + project policy + task content).

# Reference-docs index. Cat'd into every brief so workers know what
# authoritative docs are available under $LLM_SWARM_DOCS/ inside their
# container. The docs themselves are reachable via the sandbox-dir bind
# mount in sandbox.sh. Kept in the brief (not the system prompt) because
# refs.md is contextual ("consult when triggered") rather than a behavior
# rule — and projects may append refs via .swarm-policy.md.
WORKER_REFS_MD="$LLM_SWARM_DIR/prompts/refs.md"

# Append-only structured event log. Same format as coordinator-watch.sh.
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

# --- Host-wide admission ------------------------------------------------------
# Config (host tiers only; _load-env.sh ignores these in <project>/.swarm/.env):
#   HOST_MAX_WORKERS         8        running + pending worker containers, all swarms
#   HOST_MAX_LOAD1           auto     refuse when 1-min load > this (auto = 1.5 x nproc)
#   HOST_MIN_MEM_AVAIL_MB    16384    refuse when MemAvailable is below this
#   HOST_SPAWN_STAGGER_SECS  60       minimum seconds between spawns host-wide
#   HOST_STATE_DIR           $TMPDIR/llm-swarm-host-<uid>   lock + pending markers
# Test hooks: HOST_LOADAVG_FILE / HOST_MEMINFO_FILE replace /proc/{loadavg,meminfo}.
HOST_MAX_LOAD1="${HOST_MAX_LOAD1:-auto}"
HOST_MIN_MEM_AVAIL_MB="${HOST_MIN_MEM_AVAIL_MB:-16384}"
HOST_SPAWN_STAGGER_SECS="${HOST_SPAWN_STAGGER_SECS:-60}"
HOST_STATE_DIR="${HOST_STATE_DIR:-${TMPDIR:-/tmp}/llm-swarm-host-$(id -u)}"
HOST_PENDING_TTL_SECS=120

host_refuse() {
    # $1 reason tag, $2 human line, $3 hint line, rest = event k=v pairs
    local reason="$1" msg="$2" hint="$3"; shift 3
    echo "ERROR: $msg" >&2
    [ -n "$hint" ] && echo "       $hint" >&2
    log_event cap.refused "issue=$ISSUE reason=$reason $*"
    exit 3
}

host_admission_check() {
    local container_name="swarm-${SESSION_NAME}-iss-${ISSUE}"
    mkdir -p "$HOST_STATE_DIR"
    exec 9>"$HOST_STATE_DIR/cap.lock"
    flock -w 30 9 || echo "warn: host cap lock busy for 30 s; proceeding unlocked" >&2

    # a) container count: running + pending spawns not yet visible to docker ps
    if [ "$HOST_MAX_WORKERS" != "0" ]; then
        local running pending=0 m name age now
        running="$(docker ps --filter 'name=^swarm-' --format '{{.Names}}' 2>/dev/null || true)"
        now=$(date +%s)
        for m in "$HOST_STATE_DIR"/pending-*; do
            [ -e "$m" ] || continue
            name="${m##*/pending-}"
            age=$(( now - $(stat -c %Y "$m" 2>/dev/null || echo "$now") ))
            if grep -qx -- "$name" <<< "$running" || [ "$age" -gt "$HOST_PENDING_TTL_SECS" ]; then
                rm -f -- "$m"
            else
                pending=$((pending + 1))
            fi
        done
        local host_workers running_n=0
        [ -n "$running" ] && running_n=$(wc -l <<< "$running")
        host_workers=$(( running_n + pending ))
        if [ "$host_workers" -ge "$HOST_MAX_WORKERS" ]; then
            host_refuse host_max_workers \
                "HOST_MAX_WORKERS cap reached (running swarm-* containers + pending spawns=$host_workers, max=$HOST_MAX_WORKERS, all swarms)" \
                "Reap finished workers in every swarm (kill-finished-workers.sh), or raise HOST_MAX_WORKERS in <sandbox>/.env." \
                "running=$host_workers pending=$pending max=$HOST_MAX_WORKERS"
        fi
    fi

    # b) load average
    if [ "$HOST_MAX_LOAD1" != "0" ]; then
        local max_load load1 nproc_n
        nproc_n=$(nproc 2>/dev/null || echo 4)
        if [ "$HOST_MAX_LOAD1" = "auto" ]; then
            max_load=$(( nproc_n * 3 / 2 ))
        else
            max_load="${HOST_MAX_LOAD1%%.*}"
        fi
        load1="$(cut -d' ' -f1 "${HOST_LOADAVG_FILE:-/proc/loadavg}" 2>/dev/null || echo 0)"
        if [ "${load1%%.*}" -gt "$max_load" ]; then
            host_refuse host_load \
                "host load too high for a new worker (load1=$load1, max=$max_load, nproc=$nproc_n)" \
                "Wait for the running workers' compile/test peaks to pass, or set HOST_MAX_LOAD1 in <sandbox>/.env (0 disables)." \
                "load1=$load1 max=$max_load"
        fi
    fi

    # c) available memory
    if [ "$HOST_MIN_MEM_AVAIL_MB" != "0" ]; then
        local avail_kb avail_mb
        avail_kb="$(awk '/^MemAvailable:/ {print $2}' "${HOST_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null || echo 0)"
        avail_mb=$(( ${avail_kb:-0} / 1024 ))
        if [ "$avail_mb" -lt "$HOST_MIN_MEM_AVAIL_MB" ]; then
            host_refuse host_mem \
                "host memory too low for a new worker (MemAvailable=${avail_mb} MB, min=${HOST_MIN_MEM_AVAIL_MB} MB)" \
                "Reap finished workers, or lower HOST_MIN_MEM_AVAIL_MB in <sandbox>/.env (0 disables)." \
                "avail_mb=$avail_mb min_mb=$HOST_MIN_MEM_AVAIL_MB"
        fi
    fi

    # d) spawn stagger
    if [ "$HOST_SPAWN_STAGGER_SECS" != "0" ] && [ -e "$HOST_STATE_DIR/last-spawn" ]; then
        local since
        since=$(( $(date +%s) - $(stat -c %Y "$HOST_STATE_DIR/last-spawn") ))
        if [ "$since" -lt "$HOST_SPAWN_STAGGER_SECS" ]; then
            host_refuse spawn_stagger \
                "a worker was spawned ${since}s ago on this host; minimum gap is ${HOST_SPAWN_STAGGER_SECS}s (HOST_SPAWN_STAGGER_SECS)" \
                "Retry after $((HOST_SPAWN_STAGGER_SECS - since))s; the coordinator does this on its own." \
                "since=$since min=$HOST_SPAWN_STAGGER_SECS"
        fi
    fi

    # Admitted: record the in-flight spawn and the stagger clock, then
    # release the lock (flock releases with fd 9 at exit anyway).
    touch "$HOST_STATE_DIR/pending-$container_name" "$HOST_STATE_DIR/last-spawn"
    exec 9>&-
}

# check_stale_container <issue> <container>
#
# issue #493: a container can outlive the tmux window that spawned it — a
# parked/window-only reap (kill-finished-workers.sh with no
# --with-worktree), a session restart, or this script's own dead-pane
# reclaim just above can each leave a container running (or mid --rm
# teardown) under the exact name the next `docker run` for this issue will
# ask for. `docker run --name` refuses to start over either state, and the
# fand-etl incident (seanoc5/fand-etl#1092, 2026-09-27) shows what that
# failure costs with no further checks: sandbox.sh's `exec docker run`
# exited 125 ("name ... already in use"), the new tmux pane died
# immediately, and — because nothing checked — provision-worker.sh still
# exited 0. The brief sat in inbox/ for ~7 hours before anyone noticed.
#
# Only ever called with WINDOW_EXISTS=0 (about to spawn): if a live tmux
# window for this issue existed, the caller's queue-follow-up path takes
# over before this runs. The re-check below is defense in depth, not the
# primary gate.
check_stale_container() {
    local issue="$1" container="$2"
    docker ps -a --filter "name=^${container}\$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "$container" || return 0

    # A container surviving under this exact name while a genuinely live
    # (non-dead-pane) window still tracks it means a real worker may still
    # be running — never stop it out from under itself.
    if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$issue"; then
        # `|| true` + empty-means-dead: same `set -e` abort risk as
        # post_spawn_health_check's pane_dead query (self-review finding) —
        # the window can vanish between the list-windows check above and
        # here (e.g. its pane just exited 0, which remain-on-exit doesn't
        # keep around), and a vanished window is not a "genuinely alive" one.
        local pd
        pd="$(tmux list-panes -t "$SESSION_NAME:iss-$issue" -F '#{pane_dead}' 2>/dev/null | head -1)" || true
        [ -z "$pd" ] && pd=1
        if [ "$pd" != "1" ]; then
            echo "ERROR: container '$container' exists and its tmux window iss-$issue is alive." >&2
            echo "       The worker is running — route this brief through requeue.sh instead." >&2
            log_event provision.stale_container "issue=$issue container=$container state=window_alive"
            # self-review (7th pass): host_admission_check already wrote a
            # pending-$container marker for this attempt; left in place it
            # would double-count a container docker ps can already see
            # directly, inflating HOST_MAX_WORKERS until HOST_PENDING_TTL_SECS
            # (120s) expires it on its own.
            rm -f "$HOST_STATE_DIR/pending-$container"
            # self-review (10th pass): exit 2 is already this script's
            # generic "setup refused, nothing running, read stderr" code
            # (bad flag, orphan worktree, stale branch with unique commits,
            # missing tmux session) — all cases where there's no window to
            # route a follow-up brief to. This is the only exit-2-shaped
            # case that means the opposite (a worker IS running) and needs
            # requeue.sh, not a retry; a coordinator rule keyed on exit 2
            # would misroute the five other, far more common causes
            # straight into requeue.sh with nothing there to drain the
            # brief. A dedicated code keeps the two kinds of refusal
            # distinguishable without parsing stderr.
            exit 5
        fi
    fi

    local running=0
    if docker ps --filter "name=^${container}\$" --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
        running=1
    fi
    echo "[*] stale container '$container' found (running=$running, no live tracking window) — clearing before spawn" >&2
    docker stop "$container" >/dev/null 2>&1 || true
    docker rm -f "$container" >/dev/null 2>&1 || true

    # `docker rm -f` returning isn't proof the name is free yet — the
    # fand-etl incident's first recovery retry raced --rm's own async
    # auto-removal and hit the same "already in use" failure. Poll until
    # `docker ps -a` genuinely stops listing it.
    local wait_secs="${PROVISION_STALE_CONTAINER_WAIT_SECS:-15}"
    local deadline=$(( $(date +%s) + wait_secs ))
    while docker ps -a --filter "name=^${container}\$" --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "ERROR: container '$container' still present after stop+rm and a ${wait_secs}s wait." >&2
            echo "       Remove it manually:  docker rm -f '$container'" >&2
            log_event provision.stale_container "issue=$issue container=$container state=removal_timeout"
            # self-review (7th pass): see the window_alive branch above —
            # this attempt's pending marker would otherwise outlive the
            # failed spawn by up to HOST_PENDING_TTL_SECS.
            rm -f "$HOST_STATE_DIR/pending-$container"
            exit 2
        fi
        sleep 0.5
    done
    log_event provision.stale_container "issue=$issue container=$container state=cleared running_was=$running"
}

# post_spawn_health_check <issue> <window> <container> <brief_path>
#
# issue #493: verifies the just-spawned worker actually came up, instead of
# trusting `tmux new-window`'s exit status — it only reports that tmux
# accepted the request to create a window, not that the shell command
# inside it survived past its first line. That gap is exactly how the
# fand-etl incident went unreported: the new pane died on a name-collision
# `docker run` failure while provision-worker.sh still exited 0. Gives the
# container PROVISION_SPAWN_CHECK_SECS (default 5) to come up, then treats
# a dead pane OR a not-running container as a failed spawn.
#
# PROVISION_SPAWN_CHECK_SECS=0 disables the check entirely (same "0 means
# off" convention as coordinator-watch.sh's other interval knobs) — for a
# harness that stubs tmux/docker without actually simulating a live pane or
# a running container, this check could never pass.
#
# On failure, also kills the window and removes brief_path (self-review
# findings): the brief was already written to inbox/ in step 3, before
# this check ran. Removing it without also killing the window would leave
# a worker that comes up late (a container just slow to start, not truly
# dead) alive with nothing in its inbox, parked forever; a retry would
# then see that still-alive window and queue a follow-up onto it instead
# of re-spawning cleanly, and if the slow start was actually hung, that
# recreates the exact stranded-brief failure this issue closes. Killing
# the window and removing the container (self-review, 9th pass — a
# container that was merely slow, not dead, can still come up seconds
# later with its window already gone, sitting there uncounted by any
# worker but still visible to `docker ps` and so still counted against
# HOST_MAX_WORKERS) makes "exit 4" a clean, fully-failed state: no window,
# no container, no unclaimed brief, nothing for a retry to collide with or
# be refused by. Nothing ever claimed this brief (the spawn never came
# up), so there's no in-progress work to lose; the pane's last lines
# printed just above are the forensic record. Re-provisioning the issue
# spawns fresh from scratch.
#
# Skips entirely (self-review, 5th pass) when the worker image isn't built
# yet: sandbox.sh builds it before its `docker run`, which routinely takes
# far longer than check_secs, and since the window-kill above, a false
# alarm here would end that build partway instead of just logging a false
# positive. A hung first-ever build then goes undetected by this check —
# same as before this issue existed — rather than mistaken for the
# fand-etl collision shape this check exists to catch.
post_spawn_health_check() {
    local issue="$1" window="$2" container="$3" brief_path="$4"
    local check_secs="${PROVISION_SPAWN_CHECK_SECS:-5}"
    [ "$check_secs" = "0" ] && return 0
    if ! docker image inspect llm-swarm-runner:latest >/dev/null 2>&1; then
        echo "[*] worker image llm-swarm-runner:latest not built yet — skipping post-spawn health check for issue #$issue (sandbox.sh is likely still building it)" >&2
        return 0
    fi
    sleep "$check_secs"

    # Under `set -euo pipefail`, `tmux list-panes` failing outright (the
    # window itself is gone, not just its pane dead — e.g. the pane exited
    # 0, which remain-on-exit does NOT keep around) would abort this whole
    # script via the command substitution's own exit status, well before
    # reaching the failure handling below. `|| true` avoids that; a window
    # that can't be queried at all is treated the same as a dead pane, not
    # defaulted to "alive" (self-review finding).
    local pane_dead
    pane_dead="$(tmux list-panes -t "$SESSION_NAME:$window" -F '#{pane_dead}' 2>/dev/null | head -1)" || true
    [ -z "$pane_dead" ] && pane_dead=1
    # self-review (11th pass): a single transient `docker ps` hiccup (empty
    # output, daemon momentarily unresponsive) would otherwise read as
    # "not running" and kill a perfectly healthy worker. One retry after a
    # short pause distinguishes a real failed container from a blip.
    local running=0 ps_try
    for ps_try in 1 2; do
        if docker ps --filter "name=^${container}\$" --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
            running=1
            break
        fi
        [ "$ps_try" = "1" ] && sleep 1
    done

    if [ "${pane_dead:-0}" = "1" ] || [ "$running" -eq 0 ]; then
        echo "ERROR: worker window $window for issue #$issue did not come up (pane_dead=${pane_dead:-0} container_running=$running)." >&2
        echo "       Last lines of the pane:" >&2
        tmux capture-pane -t "$SESSION_NAME:$window" -p 2>/dev/null | tail -40 >&2 || true
        tmux kill-window -t "$SESSION_NAME:$window" 2>/dev/null || true
        docker stop "$container" >/dev/null 2>&1 || true
        docker rm -f "$container" >/dev/null 2>&1 || true
        local brief_removed=0
        if [ -n "$brief_path" ] && [ -e "$brief_path" ]; then
            rm -f "$brief_path" 2>/dev/null && brief_removed=1
            echo "       Removed the unclaimed brief ($brief_path) so a retry doesn't queue a duplicate." >&2
        fi
        log_event worker.start.failed "issue=$issue window=$window pane_dead=${pane_dead:-0} container_running=$running brief_removed=$brief_removed"
        # self-review (7th pass): host_admission_check's pending-$container
        # marker is otherwise left behind by a failed spawn, double-counting
        # toward HOST_MAX_WORKERS until HOST_PENDING_TTL_SECS (120s) expires
        # it. Deliberately not touching last-spawn here: the stagger clock is
        # about host load from the attempt itself (docker run + the pane's
        # brief life), which still happened, so an immediate retry can still
        # see an exit-3 spawn_stagger refusal — bounded by HOST_SPAWN_STAGGER_SECS
        # and already retried by the coordinator, so left as-is (see Findings).
        rm -f "$HOST_STATE_DIR/pending-$container"
        exit 4
    fi
}

echo "=== provision-worker.sh ==="
echo "issue:      #$ISSUE"
echo "project:    $PROJECT_DIR"
echo "worktree:   $WT"
echo "branch:     $BRANCH"
echo "tmux:       $SESSION_NAME / iss-$ISSUE"
echo

cd "$PROJECT_DIR"

# 1. Worktree (idempotent). Pre-flight: refresh remote refs and branch the
#    worker explicitly from origin/<default>, not from the coordinator's
#    local HEAD. The coordinator's checkout can be stale, mid-rebase, or on
#    an unrelated feature branch — branching off the remote ref gives every
#    new worker a fresh, predictable base without touching the coordinator's
#    working tree.
git fetch --quiet origin || echo "WARN: git fetch failed — using cached remote refs" >&2
DEFAULT_REMOTE_REF="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
if [ -z "$DEFAULT_REMOTE_REF" ]; then
    for cand in main master; do
        if git show-ref --verify --quiet "refs/remotes/origin/$cand"; then
            DEFAULT_REMOTE_REF="origin/$cand"
            break
        fi
    done
fi
if [ -z "$DEFAULT_REMOTE_REF" ]; then
    echo "ERROR: could not resolve origin's default branch (looked for origin/main, origin/master)" >&2
    exit 2
fi

if [ -d "$WT" ]; then
    # Guard: wt-issue-N paths are namespaced only by issue number, so an
    # orphan from a deleted sibling repo (or a worktree from a different
    # project sharing this parent dir) can collide. Refuse to reuse unless
    # the existing worktree's common gitdir matches $PROJECT_DIR's.
    # See todo/TODO.md for the proposed path-namespacing fix.
    expected_common="$(cd "$PROJECT_DIR" && realpath "$(git rev-parse --git-common-dir)")"
    existing_common="$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$existing_common" ]; then
        existing_common="$(cd "$WT" && realpath "$existing_common" 2>/dev/null || true)"
    fi
    if [ -z "$existing_common" ] || [ "$existing_common" != "$expected_common" ]; then
        echo "ERROR: $WT exists but does not belong to $PROJECT_DIR" >&2
        echo "       existing gitdir: ${existing_common:-<broken or missing>}" >&2
        echo "       expected gitdir: $expected_common" >&2
        echo "       Likely an orphan from a previous project at the same parent dir." >&2
        echo "       Remove with:  rm -rf '$WT'" >&2
        echo "       (or 'git worktree remove --force $WT' from its owning repo, if still alive)" >&2
        exit 2
    fi
    echo "[1/4] worktree already exists — reusing existing $BRANCH (base unchanged)"
elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    # Stale branch: $BRANCH already exists but no worktree at $WT is attached
    # to it (deleted manually, orphaned by a worktree-grouping change, or
    # left behind by branch sweep — see #174). `git worktree add -b` refuses
    # to recreate an existing branch, and under `set -e` that failure used
    # to propagate as a plain nonzero exit with no diagnosis, or — worse, in
    # some invocation contexts — got swallowed, spawning no window and no
    # brief while still reporting success. Decide explicitly instead of
    # letting `-b` fail blind.
    unique_commits="$(git rev-list --count "$DEFAULT_REMOTE_REF..$BRANCH" 2>/dev/null || echo "")"
    if [ "$unique_commits" = "0" ]; then
        # No commits beyond the default branch means $BRANCH is an ancestor
        # of (or equal to) $DEFAULT_REMOTE_REF, so fast-forwarding it there
        # is lossless. Do that before attaching a worktree so a long-stale
        # branch (0-ahead but many commits *behind*) doesn't hand the worker
        # an outdated base — without this it would silently reuse the old
        # tip instead of matching the fresh-branch path's base.
        git branch -f "$BRANCH" "$DEFAULT_REMOTE_REF"
        git worktree add "$WT" "$BRANCH"
        echo "[1/4] worktree created (reused stale branch $BRANCH — no unique commits vs $DEFAULT_REMOTE_REF, fast-forwarded)"
    else
        echo "ERROR: branch '$BRANCH' already exists with ${unique_commits:-an unknown number of} commit(s) not on $DEFAULT_REMOTE_REF," >&2
        echo "       but no worktree at $WT is attached to it. Refusing to silently discard or" >&2
        echo "       reuse that work." >&2
        echo "       Remedy: inspect it —  git log $DEFAULT_REMOTE_REF..$BRANCH" >&2
        echo "         then either reuse it:  git worktree add '$WT' '$BRANCH'" >&2
        echo "         or discard it:         git branch -D '$BRANCH'   (then re-run this script)" >&2
        log_event provision.stale_branch "issue=$ISSUE branch=$BRANCH unique_commits=${unique_commits:-unknown}"
        exit 2
    fi
else
    git worktree add "$WT" -b "$BRANCH" "$DEFAULT_REMOTE_REF"
    echo "[1/4] worktree created (base: $DEFAULT_REMOTE_REF @ $(git rev-parse --short "$DEFAULT_REMOTE_REF"))"
fi

# Symlink the project's .env into the worktree so workers find credentials
# (DB hosts/ports/passwords, API keys) at the path the project's own code
# expects. .env is gitignored so worktrees don't get it from the checkout.
# Skip if the target already exists (worker may have written scratch creds).
if [ -f "$PROJECT_DIR/.env" ] && [ ! -e "$WT/.env" ]; then
    ln -s "$PROJECT_DIR/.env" "$WT/.env"
    echo "       linked .env -> $PROJECT_DIR/.env"
fi

# Same for .sandbox-env: sandbox.sh passes $PROJECT_DIR/.sandbox-env (the
# WORKTREE, from the worker's perspective) to `docker run --env-file`, but
# the file is gitignored so fresh worktrees never contain it. Linking the
# canonical project's copy lets per-project worker-container env (e.g.
# PRECOMMIT_FAST_TESTS=0, GRADLE_RO_DEP_CACHE) reach every worker.
if [ -f "$PROJECT_DIR/.sandbox-env" ] && [ ! -e "$WT/.sandbox-env" ]; then
    ln -s "$PROJECT_DIR/.sandbox-env" "$WT/.sandbox-env"
    echo "       linked .sandbox-env -> $PROJECT_DIR/.sandbox-env"
fi

# 2. Queue dirs (idempotent — listener also creates them on startup).
#    status/ holds worker-written state files (ready-for-review / blocked /
#    done-no-pr) so the watcher can react while the worker is still parked
#    and attachable — see "Worker status file" in prompts/worker.md.
#    outbox/ holds worker-written message files (fyi / decision-needed /
#    brief-draft) that wake the coordinator mid-task — the worker→coordinator
#    channel from issue #129; see "Worker outbox" in prompts/worker.md.
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing" "$WT/.swarm/tasks/done" "$WT/.swarm/tasks/status" "$WT/.swarm/tasks/outbox"

# Hide worker scratch (.swarm/) from the project's git view so `gh pr create`
# and `git status` don't flag it as an uncommitted/untracked change. Uses the
# per-clone info/exclude (not the tracked .gitignore), so the project repo's
# committed files are untouched. Idempotent — only appends once.
exclude_file="$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)"
if [ -n "$exclude_file" ] && [ -f "$exclude_file" ] && ! grep -qxF '.swarm/' "$exclude_file"; then
    printf '\n# llm-swarm-runner worker scratch (added by provision-worker.sh)\n.swarm/\n' >> "$exclude_file"
fi
echo "[2/4] queue dirs ready"

# Cap enforcement — resolved BEFORE the brief is written (issue #464).
#    Caps used to be checked only right before spawning the tmux window,
#    by which point the brief already existed in inbox/; a cap.refused
#    exit still left it there, and a later retry queued a duplicate
#    (fand-etl, 2026-09-25: #995/#996/#997 each got a stray brief from a
#    refused 01:13Z provision, then #995's 01:45Z retry ran the task
#    twice). Deciding window-exists vs new-capacity here, and exiting
#    before any brief is written, means a refusal leaves inbox/ untouched.
#
#    The worktree from step 1 is deliberately NOT rolled back on refusal:
#    it's an empty, unqueued worktree — harmless, and a retry reuses it
#    rather than recreating it. Leaving an orphaned wt-issue-N is the
#    accepted tradeoff (see issue #464).
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION_NAME' does not exist." >&2
    echo "  (Are you running this from inside the coordinator's session?)" >&2
    exit 2
fi

# Container name lets the tmux Ctrl-Z binding `docker exec` into this
# specific worker, and is the key check_stale_container/post_spawn_health_
# check use below. Format must match the binding in ~/.tmux.conf:
#   swarm-<session>-iss-<issue>
container_name="swarm-${SESSION_NAME}-iss-${ISSUE}"

# Skip cap enforcement if a window for this issue already exists — caps
# don't apply because we're not adding capacity, just queueing a follow-up
# task onto a worker that's already alive.
WINDOW_EXISTS=0
if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
    WINDOW_EXISTS=1
    # issue #493: remain-on-exit=failed (llm-start.sh) keeps a window listed
    # after its pane exits non-zero, so "window exists" alone can't tell a
    # genuinely live worker from a corpse left by a crashed/collided spawn.
    # A dead-paned window has nothing listening for the brief we're about
    # to queue — treating it as "listener will pick up the new task" (the
    # live-window path below) would silently strand that brief forever, the
    # same failure mode this issue exists to close. Reclaim it instead so
    # the normal cap-checked spawn path below provisions a fresh, genuinely
    # live window.
    #
    # `|| true` + empty-means-dead: the window can vanish between the
    # list-windows check above and here (its pane just exited 0, which
    # remain-on-exit doesn't keep around) — under `set -euo pipefail` that
    # would otherwise abort this whole script via the command substitution's
    # own exit status (self-review finding on post_spawn_health_check,
    # applied here too for the same race).
    pane_dead_flag="$(tmux list-panes -t "$SESSION_NAME:iss-$ISSUE" -F '#{pane_dead}' 2>/dev/null | head -1)" || true
    [ -z "$pane_dead_flag" ] && pane_dead_flag=1
    if [ "$pane_dead_flag" = "1" ]; then
        echo "[*] window iss-$ISSUE exists but its pane is dead — reclaiming" >&2
        tmux capture-pane -t "$SESSION_NAME:iss-$ISSUE" -p 2>/dev/null | tail -20 >&2 || true
        tmux kill-window -t "$SESSION_NAME:iss-$ISSUE" 2>/dev/null || true
        # self-review (12th pass): a dead pane can leave brief(s) behind in
        # inbox/ (never claimed) or processing/ (claimed, abandoned
        # mid-task) — the fresh listener this reclaim is about to spawn
        # would inherit those ALONGSIDE the new brief written further
        # below, re-running stale work. This is exactly the fand-etl
        # re-provision shape: the operator re-sends the same task and it
        # runs twice. Salvage them aside first (same destination
        # convention as kill-worktree.sh's own queued-file salvage) rather
        # than let a new listener silently pick them back up.
        stale_briefs=0
        for stale_subdir in inbox processing; do
            for stale_file in "$WT/.swarm/tasks/$stale_subdir"/*.md; do
                [ -e "$stale_file" ] || continue
                stale_salvage_dir="$PROJECT_DIR/.swarm/salvaged/iss-$ISSUE/$stale_subdir"
                mkdir -p "$stale_salvage_dir"
                mv "$stale_file" "$stale_salvage_dir/" 2>/dev/null && stale_briefs=$((stale_briefs + 1))
            done
        done
        if [ "$stale_briefs" -gt 0 ]; then
            echo "       Salvaged $stale_briefs stale brief(s) to $PROJECT_DIR/.swarm/salvaged/iss-$ISSUE/ (preserved, not auto-rerun — review and re-file if still relevant)" >&2
            # self-review (14th pass): the cap/admission/stale-container
            # checks below can still refuse this same re-provision (exit
            # 2/3/5) -- the issue then has no window AND no queued brief,
            # with the salvaged copy above as the only trace and none of
            # those refusal paths otherwise mentioning it. An EXIT trap
            # catches every such refusal (they each exit directly, from
            # several call sites) without threading this through each one;
            # it leaves the actual exit status untouched.
            trap 'rc=$?; [ "$rc" -ne 0 ] && echo "       Note: issue #$ISSUE still has $stale_briefs brief(s) salvaged to $PROJECT_DIR/.swarm/salvaged/iss-$ISSUE/ from the reclaim above, now unqueued until this is retried." >&2; :' EXIT
        fi
        log_event worker.dead_pane_reclaimed "issue=$ISSUE window=iss-$ISSUE stale_briefs_salvaged=$stale_briefs"
        WINDOW_EXISTS=0
    fi
fi

if [ "$WINDOW_EXISTS" -eq 0 ]; then
    # Cap enforcement: count alive workers (iss-*) and total windows BEFORE
    # the spawn. Refuse with exit 3 if either cap would be exceeded. The
    # coordinator catches non-zero exits and reports back to the user.
    alive_workers=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -c '^iss-' || true)
    total_windows=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | wc -l)
    if [ "$alive_workers" -ge "$MAX_WORKERS" ]; then
        echo "ERROR: MAX_WORKERS cap reached (alive=$alive_workers, max=$MAX_WORKERS)" >&2
        echo "       Wait for a worker to finish, or raise MAX_WORKERS in <project>/.swarm/.env." >&2
        log_event cap.refused "issue=$ISSUE reason=max_workers alive=$alive_workers max=$MAX_WORKERS"
        exit 3
    fi
    if [ "$total_windows" -ge "$MAX_TMUX_WINDOWS" ]; then
        echo "ERROR: MAX_TMUX_WINDOWS cap reached (total=$total_windows, max=$MAX_TMUX_WINDOWS)" >&2
        echo "       Close finished iss-* windows: tmux kill-window -t '$SESSION_NAME:iss-NN'" >&2
        echo "       Or raise MAX_TMUX_WINDOWS in <project>/.swarm/.env." >&2
        log_event cap.refused "issue=$ISSUE reason=max_tmux_windows total=$total_windows max=$MAX_TMUX_WINDOWS"
        exit 3
    fi
    # Host-wide admission (2026-09-29, after the load-95 review): every
    # swarm on this box provisions into the same RAM and the same 32
    # threads, so the decision is taken under one host-wide flock and
    # covers four things, in order:
    #   a) HOST_MAX_WORKERS  running swarm-* containers + spawns still in
    #      flight (a "pending" marker per spawn, written under the lock,
    #      dropped once the container shows up or after 120 s). Without the
    #      markers three coordinators counting `docker ps` in the same
    #      second all saw room for one more and 15 ran against a cap of 14.
    #   b) HOST_MAX_LOAD1    1-minute load average ceiling ("auto" =
    #      1.5 x nproc). Memory used to be the only governor and it cuts on
    #      the wrong axis: 9 workers dispatched inside one minute all
    #      compiled then forked test JVMs together (load 95 on 32 threads).
    #   c) HOST_MIN_MEM_AVAIL_MB  MemAvailable floor, so a spawn can't push
    #      the box into swap even when the container count is under cap.
    #   d) HOST_SPAWN_STAGGER_SECS  minimum gap between any two spawns
    #      host-wide, so the compile/fork peaks of new workers don't line up.
    # Each refusal is exit 3 + cap.refused, the same path the coordinator
    # already retries. 0 disables any one of them; HOST_STATE_DIR holds the
    # lock and markers (host-wide, outside every repo).
    host_admission_check

    # issue #493: clear any leftover same-name container before the brief
    # is written — see check_stale_container's header comment.
    check_stale_container "$ISSUE" "$container_name"
fi

# 3. Build task brief atomically (mktemp+mv inside same FS = atomic rename)
#
# TASK_ID base is second-resolution; on the rare case of two re-dispatches
# in the same wall-clock second for the same issue, append a counter
# (-2, -3, ...) so we don't silently clobber the previous brief. The common
# case (no collision) keeps the clean YYYYMMDD-HHMMSS-N naming.
#
# PROVISION_NOW_EPOCH lets callers (tests) freeze/inject "now" so the
# collision-suffix path doesn't depend on two real invocations landing in
# the same wall-clock second — see #192. Unset in normal operation.
if [ -n "${PROVISION_NOW_EPOCH:-}" ]; then
    NOW_FMT="$(date -d "@$PROVISION_NOW_EPOCH" +%Y%m%d-%H%M%S 2>/dev/null \
        || date -r "$PROVISION_NOW_EPOCH" +%Y%m%d-%H%M%S)"
else
    NOW_FMT="$(date +%Y%m%d-%H%M%S)"
fi
BASE_ID="$NOW_FMT-$ISSUE"
TASK_ID="$BASE_ID"
DEST="$WT/.swarm/tasks/inbox/$TASK_ID.md"
N=2
while [ -e "$DEST" ]; do
    TASK_ID="$BASE_ID-$N"
    DEST="$WT/.swarm/tasks/inbox/$TASK_ID.md"
    N=$((N + 1))
done

TMP="$(mktemp -p "$WT/.swarm/tasks/inbox" .tmp.XXXXXX.md)"
{
    # Worker baseline conventions (prompts/worker.md) are NOT cat'd here —
    # they reach the agent via system prompt at launch time (see
    # scripts/worker-listener.sh). Brief contents below are per-task.
    #
    # 1. Reference-docs index: tells the worker what authoritative docs live
    #    under $LLM_SWARM_DOCS/ (mounted ro into the container) and when to
    #    consult them. Index is small; the doc bodies stay on disk until needed.
    if [ -f "$WORKER_REFS_MD" ]; then
        cat "$WORKER_REFS_MD"
        echo
        echo "---"
        echo
    fi
    # 2. Project-specific guardrails (per-project policy may extend or
    #    override the worker baseline delivered via system prompt).
    if [ -f .swarm-policy.md ]; then
        echo "## Project Guardrails (MUST OBEY)"
        echo
        cat .swarm-policy.md
        echo
        echo "---"
        echo
    fi
    # 3. The actual task.
    echo "## Task"
    echo
    echo "Fix issue #$ISSUE. Details follow."
    echo
    gh issue view "$ISSUE"
} > "$TMP"
# `mv -n` won't clobber even if a colliding file appeared between our
# existence check and now; on the (vanishingly rare) race, fall back to
# bumping the counter and retrying once.
if ! mv -n "$TMP" "$DEST" 2>/dev/null || [ -f "$TMP" ]; then
    TASK_ID="$BASE_ID-$N"
    DEST="$WT/.swarm/tasks/inbox/$TASK_ID.md"
    mv "$TMP" "$DEST"
fi
echo "[3/4] brief queued: $DEST"

# Brief lint (ringer manifest-lint concept — docs/ringer-adoptions.md #6).
# Warn-only: dispatch proceeds, but unverifiable briefs (no acceptance
# criteria / can't-fail check / no named files / underspecified) are
# surfaced so the coordinator can improve the issue before the worker
# burns tokens on it. BRIEF_LINT=0 disables.
if [ "${BRIEF_LINT:-1}" = "1" ] && [ -x "$SCRIPT_DIR/lint-brief.sh" ]; then
    "$SCRIPT_DIR/lint-brief.sh" "$DEST" || true
fi

# 4. Spawn worker tmux window (background — does NOT steal focus from
#    coordinator). Session existence and caps were already checked above,
#    before the brief was written; WINDOW_EXISTS/alive_workers/total_windows
#    carry that decision forward so we don't re-check (and can't re-refuse
#    after the brief already exists).
if [ "$WINDOW_EXISTS" -eq 1 ]; then
    echo "[4/4] tmux window iss-$ISSUE already exists — listener will pick up the new task"
    log_event worker.requeue "issue=$ISSUE task_id=$TASK_ID"
else
    # container_name was computed above (needed earlier for
    # check_stale_container's pre-flight). WORKER_CHECK*/SWARM_EVAL_LOG must
    # ride this line too: _load-env.sh applies <project>/.swarm/.env only in
    # THIS host process, and the tmux window's shell inherits the tmux
    # server env instead — without the explicit hand-off the
    # acceptance-check config documented in .env.example never reaches
    # sandbox.sh (and thus never the listener).
    tmux new-window -d -t "$SESSION_NAME" -n "iss-$ISSUE" \
        "WORKER_CONTAINER_NAME=$(printf '%q' "$container_name") WORKER_CMD=$(printf '%q' "${WORKER_CMD:-claude}") WORKER_MODEL=$(printf '%q' "${WORKER_MODEL:-}") WORKER_PROMPT_FILE=$(printf '%q' "${WORKER_PROMPT_FILE:-}") WORKER_HEADLESS=$(printf '%q' "${WORKER_HEADLESS:-0}") WORKER_SELF_REVIEW=$(printf '%q' "${WORKER_SELF_REVIEW:-1}") SELF_REVIEW_CMD=$(printf '%q' "${SELF_REVIEW_CMD:-}") SELF_REVIEW_MODEL=$(printf '%q' "${SELF_REVIEW_MODEL:-}") WORKER_CHECK=$(printf '%q' "${WORKER_CHECK:-}") WORKER_CHECK_CMD=$(printf '%q' "${WORKER_CHECK_CMD:-}") WORKER_CHECK_TIMEOUT=$(printf '%q' "${WORKER_CHECK_TIMEOUT:-}") WORKER_CHECK_RETRY=$(printf '%q' "${WORKER_CHECK_RETRY:-}") SWARM_EVAL_LOG=$(printf '%q' "${SWARM_EVAL_LOG:-}") EXTRA_MOUNTS=$(printf '%q' "${EXTRA_MOUNTS:-}") SANDBOX_DEP_CACHE=$(printf '%q' "${SANDBOX_DEP_CACHE:-}") SANDBOX_CPUS=$(printf '%q' "${SANDBOX_CPUS:-}") SANDBOX_GRADLE_LIMITS=$(printf '%q' "${SANDBOX_GRADLE_LIMITS:-}") SANDBOX_GRADLE_WORKERS_MAX=$(printf '%q' "${SANDBOX_GRADLE_WORKERS_MAX:-}") SANDBOX_KOTLIN_DAEMON_XMX=$(printf '%q' "${SANDBOX_KOTLIN_DAEMON_XMX:-}") SANDBOX_ALLOW_BACKGROUND_TASKS=$(printf '%q' "${SANDBOX_ALLOW_BACKGROUND_TASKS:-}") $(printf '%q' "$SANDBOX_SH") $(printf '%q' "$WT") listener"
    echo "[4/4] tmux window iss-$ISSUE spawned (listener)"
    log_event worker.start "issue=$ISSUE task_id=$TASK_ID window=iss-$ISSUE alive=$((alive_workers + 1))/$MAX_WORKERS total_windows=$((total_windows + 1))/$MAX_TMUX_WINDOWS"

    # issue #493: don't report success on tmux's say-so alone — verify the
    # pane actually survived past its first line (see
    # post_spawn_health_check's header comment). Exits non-zero on failure.
    post_spawn_health_check "$ISSUE" "iss-$ISSUE" "$container_name" "$DEST"
fi

echo
echo "Provisioned worker for issue #$ISSUE."
echo "  task_id: $TASK_ID"
echo "  worker: tmux window '$SESSION_NAME:iss-$ISSUE'"
echo "  monitor: ls $WT/.swarm/tasks/done/"
echo "  events:  tail -F $EVENTS_LOG"
