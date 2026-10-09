#!/usr/bin/env bash
#
# provision-worker.sh — coordinator helper to provision a worker for an issue.
#
# One call does: create worktree, init queue, check caps, write the brief
# atomically, spawn the worker tmux window, verify it came up. The
# coordinator calls it as a single command (no $(...) at its tool layer,
# which gemini's run_shell_command guardrails require). See --help for the
# contract (exit codes, config, events).
set -euo pipefail

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
provision-worker.sh — Provision a worker for one GitHub issue

USAGE
    provision-worker.sh <issue-number> [project-dir]     (project-dir default: $PWD)

WHAT IT DOES
    1. Worktree <worktree-parent>/wt-issue-N on branch fix/issue-N, based on
       origin's default branch (reused if present). <worktree-parent> is the
       project's parent dir, or <project-parent>/<project>-worktrees when
       SWARM_WORKTREE_GROUPING=project.
    2. Queue dirs under <wt>/.swarm/tasks/.
    3. Caps and host admission (below), then the brief: prompts/refs.md +
       .swarm-policy.md + `gh issue view N`, atomically written to inbox/.
    4. tmux window 'iss-N' running the sandbox listener, then a health poll.
    If a live iss-N window already exists, steps 3-4 only queue a follow-up
    brief onto it (no caps, no spawn).

EXIT CODES
    0  provisioned (or follow-up queued)
    2  setup refused, nothing running: bad flag, issue fetch failed, no
       origin default branch, orphan worktree, stale branch with unique
       commits, missing tmux session, stale container that won't clear
    3  cap refused (cap.refused event) — the coordinator retries these
    4  spawn confirmed dead: window, container and brief all removed, so a
       retry starts clean
    5  a same-name container exists AND its iss-N window is alive — a worker
       is running; use requeue.sh, not a retry
    6  still starting after PROVISION_SPAWN_CHECK_SECS (pane alive, container
       not seen yet) — nothing cleaned up; re-running would double-provision.
       Check `docker ps` / `tmux capture-pane`.
    Caps and admission run before the brief is written, so 2/3/5 leave no
    brief behind (#464). The worktree is kept on refusal; a retry reuses it.

CAPS (exit 3)
    MAX_WORKERS              5     alive iss-* windows in this session
    MAX_TMUX_WINDOWS         10    total windows in this session
    Host-wide, under one flock in HOST_STATE_DIR (set these in <sandbox>/.env;
    _load-env.sh ignores them in <project>/.swarm/.env):
    HOST_MAX_WORKERS         8     running swarm-* containers + spawns in flight
    HOST_MAX_LOAD1           auto  1-min load ceiling (auto = 1.5 x nproc; 0 off)
    HOST_MIN_MEM_AVAIL_MB    16384 MemAvailable floor (0 off)
    HOST_SPAWN_STAGGER_SECS  60    min gap between spawns host-wide (0 off)
    HOST_STATE_DIR           $TMPDIR/llm-swarm-host-<uid>  lock, pending
                                   markers, dispatch-paused (nightly-full-tests.sh)

OTHER CONFIG  (shell env > <project>/.swarm/.env > <sandbox>/.env > .env.example)
    PROVISION_SPAWN_CHECK_SECS           120  health-poll ceiling (0 disables;
                                              also skipped while the image is
                                              unbuilt — pre-build with
                                              scripts/build-image.sh)
    PROVISION_STALE_CONTAINER_WAIT_SECS  15   wait for a stale container's name to clear
    SANDBOX_SH, LLM_SWARM_DIR            auto
    BRIEF_LINT                           1    run lint-brief.sh (warn-only)

EVENTS  (<project>/.swarm/events.log)
    worker.start                 window spawned (logged before the health poll)
    worker.start.failed          spawn confirmed dead (exit 4); follows a worker.start
    worker.start.indeterminate   health poll ran out, pane alive (exit 6)
    worker.requeue               follow-up queued onto a live window
    worker.dead_pane_reclaimed   dead-pane iss-N window killed, its stale briefs
                                 salvaged to .swarm/salvaged/iss-N/
    provision.stale_container    state=cleared|window_alive|removal_timeout
    provision.stale_branch       fix/issue-N has unique commits, no worktree
    cap.refused                  reason=max_workers|max_tmux_windows|dispatch_paused|
                                 host_max_workers|host_load|host_mem|spawn_stagger
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
PROJECT_DIR="$(cd "${2:-$PWD}" && pwd)"
BRANCH="fix/issue-$ISSUE"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"
WINDOW="iss-$ISSUE"
# Must match the Ctrl-Z `docker exec` binding in ~/.tmux.conf.
CONTAINER="swarm-${SESSION_NAME}-iss-${ISSUE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"
SANDBOX_SH="${SANDBOX_SH:-$LLM_SWARM_DIR/sandbox.sh}"

# Loads <project>/.swarm/.env and sandbox defaults (the tmux session usually
# has them already; this covers standalone runs) and defines
# swarm_worktree_dir, so WT is computed after it.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"
WT="$(swarm_worktree_dir "$PROJECT_DIR" "$ISSUE")"
mkdir -p "$(dirname "$WT")"

MAX_WORKERS="${MAX_WORKERS:-5}"
MAX_TMUX_WINDOWS="${MAX_TMUX_WINDOWS:-10}"
HOST_MAX_WORKERS="${HOST_MAX_WORKERS:-8}"
HOST_MAX_LOAD1="${HOST_MAX_LOAD1:-auto}"
HOST_MIN_MEM_AVAIL_MB="${HOST_MIN_MEM_AVAIL_MB:-16384}"
HOST_SPAWN_STAGGER_SECS="${HOST_SPAWN_STAGGER_SECS:-60}"
HOST_STATE_DIR="${HOST_STATE_DIR:-${TMPDIR:-/tmp}/llm-swarm-host-$(id -u)}"
SPAWN_CHECK_SECS="${PROVISION_SPAWN_CHECK_SECS:-120}"
# A pending marker must outlive this run's health poll plus the setup before
# it (#546). Each marker stores its writer's TTL, because projects can set
# different PROVISION_SPAWN_CHECK_SECS and share HOST_STATE_DIR.
HOST_PENDING_TTL_SECS="$(awk -v c="$SPAWN_CHECK_SECS" 'BEGIN{v=c+30; if (v<120) v=120; printf "%.0f", v}')"

# Worker conventions (prompts/worker.md) reach the agent as a system prompt
# via worker-listener.sh; the brief carries only per-task content.
WORKER_REFS_MD="$LLM_SWARM_DIR/prompts/refs.md"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true
log_event() {
    local cat="$1"; shift
    printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

# issue #594: set_window_flag/clear_window_flag — see scripts/_window-flags.sh.
# shellcheck source=_window-flags.sh
. "$SCRIPT_DIR/_window-flags.sh"

# --- helpers ------------------------------------------------------------------

# pane_is_dead <window>: true if the pane is dead OR the window can't be
# queried (a pane that exited 0 isn't kept by remain-on-exit, so the window
# can vanish between list-windows and here; `|| true` keeps set -e out of it).
pane_is_dead() {
    local pd
    pd="$(tmux list-panes -t "$SESSION_NAME:$1" -F '#{pane_dead}' 2>/dev/null | head -1)" || true
    [ "${pd:-1}" = "1" ]
}

window_listed() {
    tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "$1"
}

# container_listed [-a] <name>: exact-name match (-a includes stopped ones).
container_listed() {
    local all=()
    [ "$1" = "-a" ] && { all=(-a); shift; }
    docker ps "${all[@]}" --filter "name=^$1\$" --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

remove_container() {
    docker stop "$1" >/dev/null 2>&1 || true
    docker rm -f "$1" >/dev/null 2>&1 || true
}

# drop_pending_marker <container>: every refusal after admission drops the
# marker, or it double-counts toward HOST_MAX_WORKERS until its TTL expires.
drop_pending_marker() {
    rm -f -- "$HOST_STATE_DIR/pending-$1"
}

# refuse_cap <reason> <message> <hint> [k=v ...]  -> exit 3
refuse_cap() {
    local reason="$1" msg="$2" hint="$3"; shift 3
    echo "ERROR: $msg" >&2
    [ -n "$hint" ] && echo "       $hint" >&2
    log_event cap.refused "issue=$ISSUE reason=$reason $*"
    exit 3
}

# --- session caps -------------------------------------------------------------

session_cap_check() {
    alive_workers=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -c '^iss-' || true)
    total_windows=$(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | wc -l)
    [ "$alive_workers" -ge "$MAX_WORKERS" ] && refuse_cap max_workers \
        "MAX_WORKERS cap reached (alive=$alive_workers, max=$MAX_WORKERS)" \
        "Wait for a worker to finish, or raise MAX_WORKERS in <project>/.swarm/.env." \
        "alive=$alive_workers max=$MAX_WORKERS"
    [ "$total_windows" -ge "$MAX_TMUX_WINDOWS" ] && refuse_cap max_tmux_windows \
        "MAX_TMUX_WINDOWS cap reached (total=$total_windows, max=$MAX_TMUX_WINDOWS)" \
        "Close finished windows (tmux kill-window -t '$SESSION_NAME:iss-NN') or raise MAX_TMUX_WINDOWS in <project>/.swarm/.env." \
        "total=$total_windows max=$MAX_TMUX_WINDOWS"
    return 0
}

# --- host-wide admission ------------------------------------------------------
# Every swarm on the host shares its RAM and cores, so admission is decided
# under one host-wide flock (2026-09-29, after load 95 on 32 threads and
# 16 x 8 GB workers filling 128 GB). Test hooks: HOST_LOADAVG_FILE and
# HOST_MEMINFO_FILE replace /proc/{loadavg,meminfo}.

host_admission_check() {
    mkdir -p "$HOST_STATE_DIR"
    exec 9>"$HOST_STATE_DIR/cap.lock"
    flock -w 30 9 || echo "warn: host cap lock busy for 30 s; proceeding unlocked" >&2

    # Dispatch pause: "<expiry-epoch> <reason...>" from nightly-full-tests.sh.
    # Expired or malformed files are removed, so a crashed nightly can't
    # hold dispatch forever.
    local pause_file="$HOST_STATE_DIR/dispatch-paused"
    if [ -f "$pause_file" ]; then
        local p_until="" p_reason="" p_left=0
        read -r p_until p_reason < "$pause_file" || true
        [[ "$p_until" =~ ^[0-9]+$ ]] && p_left=$(( p_until - $(date +%s) ))
        [ "$p_left" -gt 0 ] && refuse_cap dispatch_paused \
            "dispatch paused host-wide (${p_reason:-no reason given})" \
            "Retry after ${p_left}s at the latest (the pause may lift sooner); the coordinator does this on its own." \
            "left=${p_left}s"
        rm -f -- "$pause_file"
    fi

    # Container count = running + spawns admitted but not yet in docker ps.
    # Without pending markers, three coordinators in the same second all saw
    # room for one more.
    if [ "$HOST_MAX_WORKERS" != "0" ]; then
        local running running_n=0 pending=0 m name age marker_ttl now
        running="$(docker ps --filter 'name=^swarm-' --format '{{.Names}}' 2>/dev/null || true)"
        [ -n "$running" ] && running_n=$(wc -l <<< "$running")
        now=$(date +%s)
        for m in "$HOST_STATE_DIR"/pending-*; do
            [ -e "$m" ] || continue
            name="${m##*/pending-}"
            age=$(( now - $(stat -c %Y "$m" 2>/dev/null || echo "$now") ))
            # Judge each marker by its own stored TTL (pre-#546 markers have
            # none; fall back to ours).
            marker_ttl="$(cat -- "$m" 2>/dev/null)" || true
            [[ "$marker_ttl" =~ ^[0-9]+$ ]] || marker_ttl="$HOST_PENDING_TTL_SECS"
            if grep -qx -- "$name" <<< "$running" || [ "$age" -gt "$marker_ttl" ]; then
                rm -f -- "$m"
            else
                pending=$((pending + 1))
            fi
        done
        local total=$(( running_n + pending ))
        [ "$total" -ge "$HOST_MAX_WORKERS" ] && refuse_cap host_max_workers \
            "HOST_MAX_WORKERS cap reached (running swarm-* containers + pending spawns=$total, max=$HOST_MAX_WORKERS, all swarms)" \
            "Reap finished workers in every swarm (kill-finished-workers.sh), or raise HOST_MAX_WORKERS in <sandbox>/.env." \
            "total=$total running=$running_n pending=$pending max=$HOST_MAX_WORKERS"
    fi

    # Load ceiling: memory alone cut on the wrong axis — 9 workers spawned
    # in one minute compiled and forked test JVMs together.
    if [ "$HOST_MAX_LOAD1" != "0" ]; then
        local max_load load1 nproc_n
        nproc_n=$(nproc 2>/dev/null || echo 4)
        if [ "$HOST_MAX_LOAD1" = "auto" ]; then
            max_load=$(( nproc_n * 3 / 2 ))
        else
            max_load="$HOST_MAX_LOAD1"
        fi
        load1="$(cut -d' ' -f1 "${HOST_LOADAVG_FILE:-/proc/loadavg}" 2>/dev/null || echo 0)"
        awk -v l="${load1:-0}" -v m="$max_load" 'BEGIN{exit !(l+0 > m+0)}' && refuse_cap host_load \
            "host load too high for a new worker (load1=$load1, max=$max_load, nproc=$nproc_n)" \
            "Wait for the running workers' compile/test peaks to pass, or set HOST_MAX_LOAD1 in <sandbox>/.env (0 disables)." \
            "load1=$load1 max=$max_load"
    fi

    if [ "$HOST_MIN_MEM_AVAIL_MB" != "0" ]; then
        local avail_kb avail_mb
        avail_kb="$(awk '/^MemAvailable:/ {print $2}' "${HOST_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null || echo 0)"
        avail_mb=$(( ${avail_kb:-0} / 1024 ))
        [ "$avail_mb" -lt "$HOST_MIN_MEM_AVAIL_MB" ] && refuse_cap host_mem \
            "host memory too low for a new worker (MemAvailable=${avail_mb} MB, min=${HOST_MIN_MEM_AVAIL_MB} MB)" \
            "Reap finished workers, or lower HOST_MIN_MEM_AVAIL_MB in <sandbox>/.env (0 disables)." \
            "avail_mb=$avail_mb min_mb=$HOST_MIN_MEM_AVAIL_MB"
    fi

    # Stagger so new workers' compile/fork peaks don't line up.
    if [ "$HOST_SPAWN_STAGGER_SECS" != "0" ] && [ -e "$HOST_STATE_DIR/last-spawn" ]; then
        local since=$(( $(date +%s) - $(stat -c %Y "$HOST_STATE_DIR/last-spawn") ))
        [ "$since" -lt "$HOST_SPAWN_STAGGER_SECS" ] && refuse_cap spawn_stagger \
            "a worker was spawned ${since}s ago on this host; minimum gap is ${HOST_SPAWN_STAGGER_SECS}s (HOST_SPAWN_STAGGER_SECS)" \
            "Retry after $((HOST_SPAWN_STAGGER_SECS - since))s; the coordinator does this on its own." \
            "since=$since min=$HOST_SPAWN_STAGGER_SECS"
    fi

    # Admitted. last-spawn is deliberately not rolled back on a later
    # failure: the attempt itself still loaded the host.
    echo "$HOST_PENDING_TTL_SECS" > "$HOST_STATE_DIR/pending-$CONTAINER"
    touch "$HOST_STATE_DIR/last-spawn"
    exec 9>&-
}

# --- stale container (#493) ---------------------------------------------------
# A container can outlive its window (window-only reap, session restart, the
# dead-pane reclaim below), and `docker run --name` then fails. fand-etl
# 2026-09-27: the pane died on exit 125, this script still exited 0, and the
# brief sat unclaimed for ~7 hours.

# check_stale_container <issue> <container>
check_stale_container() {
    local issue="$1" container="$2" window="iss-$1"
    container_listed -a "$container" || return 0

    # Defense in depth: the caller only gets here with no live window, but
    # never stop a container whose window is genuinely alive.
    if window_listed "$window" && ! pane_is_dead "$window"; then
        echo "ERROR: container '$container' exists and its tmux window $window is alive." >&2
        echo "       The worker is running — route this brief through requeue.sh instead." >&2
        log_event provision.stale_container "issue=$issue container=$container state=window_alive"
        drop_pending_marker "$container"
        exit 5
    fi

    local running=0
    container_listed "$container" && running=1
    echo "[*] stale container '$container' found (running=$running, no live tracking window) — clearing before spawn" >&2
    remove_container "$container"

    # `docker rm -f` returning doesn't mean the name is free: --rm's async
    # auto-removal can still hold it. Poll until docker ps -a drops it.
    local wait_secs="${PROVISION_STALE_CONTAINER_WAIT_SECS:-15}"
    local deadline=$(( $(date +%s) + wait_secs ))
    while container_listed -a "$container"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "ERROR: container '$container' still present after stop+rm and a ${wait_secs}s wait." >&2
            echo "       Remove it manually:  docker rm -f '$container'" >&2
            log_event provision.stale_container "issue=$issue container=$container state=removal_timeout"
            drop_pending_marker "$container"
            exit 2
        fi
        sleep 0.5
    done
    log_event provision.stale_container "issue=$issue container=$container state=cleared running_was=$running"
}

# --- post-spawn health poll (#493, #546) --------------------------------------
# `tmux new-window` succeeding only means tmux accepted the request. Poll
# until the container is running (success), the pane dies (exit 4, full
# cleanup), or the deadline passes with the pane alive (exit 6, no cleanup).
# A one-shot check after a fixed sleep killed healthy spawns on a loaded host
# (SAMlytics#397: `docker create` at +31s).

# post_spawn_health_check <issue> <window> <container> <brief_path>
post_spawn_health_check() {
    local issue="$1" window="$2" container="$3" brief_path="$4"
    local check_secs="${PROVISION_SPAWN_CHECK_SECS:-120}"
    [ "$check_secs" = "0" ] && return 0
    # sandbox.sh builds a missing image before `docker run`, which can take
    # far longer than the poll; killing the window would abort the build.
    if ! docker image inspect llm-swarm-runner:latest >/dev/null 2>&1; then
        echo "[*] worker image llm-swarm-runner:latest not built yet — skipping post-spawn health check for issue #$issue (sandbox.sh is likely still building it)" >&2
        return 0
    fi

    local poll_interval=1
    awk -v c="$check_secs" 'BEGIN{exit !(c<1)}' && poll_interval="$check_secs"
    # Wall-clock deadline, not a poll count: each tmux/docker call can be
    # slow on exactly the loaded host this guards.
    local deadline_ns
    deadline_ns=$(( $(date +%s%N) + $(awk -v s="$check_secs" 'BEGIN{printf "%.0f", s*1000000000}') ))

    local dead=0 poll_num=0
    while :; do
        poll_num=$((poll_num + 1))
        if pane_is_dead "$window"; then dead=1; break; fi
        container_listed "$container" && return 0
        # Always allow a second poll, so a docker blip on a short budget
        # still gets its retry.
        [ "$poll_num" -ge 2 ] && [ "$(date +%s%N)" -ge "$deadline_ns" ] && break
        sleep "$poll_interval"
    done

    if [ "$dead" -eq 1 ]; then
        echo "ERROR: worker window $window for issue #$issue did not come up (pane_dead=1 container_running=0)." >&2
        echo "       Last lines of the pane:" >&2
        tmux capture-pane -t "$SESSION_NAME:$window.0" -p 2>/dev/null | tail -40 >&2 || true
        # Remove window, container and brief together so a late-starting
        # worker can't park with an empty inbox and a retry starts clean.
        tmux kill-window -t "$SESSION_NAME:$window" 2>/dev/null || true
        remove_container "$container"
        local brief_removed=0
        if [ -n "$brief_path" ] && [ -e "$brief_path" ]; then
            rm -f "$brief_path" 2>/dev/null && brief_removed=1
            echo "       Removed the unclaimed brief ($brief_path) so a retry doesn't queue a duplicate." >&2
        fi
        log_event worker.start.failed "issue=$issue window=$window pane_dead=1 container_running=0 brief_removed=$brief_removed"
        drop_pending_marker "$container"
        exit 4
    fi

    # Pane alive, container never seen: may just be slow. Leave everything
    # (including the pending marker, so it keeps counting) and say so.
    echo "WARN: worker window $window for issue #$issue is still starting after ${check_secs}s (pane alive, container not observed yet) — leaving window and container running." >&2
    echo "      Check again:  docker ps --filter name=^${container}\$   /   tmux capture-pane -t '$SESSION_NAME:$window' -p" >&2
    log_event worker.start.indeterminate "issue=$issue window=$window check_secs=$check_secs"
    exit 6
}

# --- main ---------------------------------------------------------------------

echo "=== provision-worker.sh ==="
echo "issue:      #$ISSUE"
echo "project:    $PROJECT_DIR"
echo "worktree:   $WT"
echo "branch:     $BRANCH"
echo "tmux:       $SESSION_NAME / $WINDOW"
echo

cd "$PROJECT_DIR"

# 1. Worktree, branched from origin's default branch (not the coordinator's
#    local HEAD, which may be stale or on another branch).
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
    # wt-issue-N is namespaced only by issue number, so refuse to reuse a
    # worktree that belongs to another repo sharing this parent dir.
    expected_common="$(realpath "$(git rev-parse --git-common-dir)")"
    existing_common="$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null || true)"
    [ -n "$existing_common" ] && existing_common="$(cd "$WT" && realpath "$existing_common" 2>/dev/null || true)"
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
    # Branch exists without a worktree (manual delete, branch sweep #174,
    # grouping change). `worktree add -b` would fail blind, so decide here.
    unique_commits="$(git rev-list --count "$DEFAULT_REMOTE_REF..$BRANCH" 2>/dev/null || echo "")"
    if [ "$unique_commits" = "0" ]; then
        # Nothing unique, so fast-forwarding to the fresh base is lossless.
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

# Gitignored files the worker needs: .env (project credentials) and
# .sandbox-env (sandbox.sh's --env-file). Never overwrite a worker's own copy.
for f in .env .sandbox-env; do
    if [ -f "$PROJECT_DIR/$f" ] && [ ! -e "$WT/$f" ]; then
        ln -s "$PROJECT_DIR/$f" "$WT/$f"
        echo "       linked $f -> $PROJECT_DIR/$f"
    fi
done

# 2. Queue dirs (the listener creates them too). status/ and outbox/ are the
#    worker->watcher/coordinator channels (prompts/worker.md).
mkdir -p "$WT"/.swarm/tasks/{inbox,processing,done,status,outbox}

# Hide .swarm/ from the worktree's git view via info/exclude (not the
# tracked .gitignore).
exclude_file="$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)"
if [ -n "$exclude_file" ] && [ -f "$exclude_file" ] && ! grep -qxF '.swarm/' "$exclude_file"; then
    printf '\n# llm-swarm-runner worker scratch (added by provision-worker.sh)\n.swarm/\n' >> "$exclude_file"
fi
echo "[2/4] queue dirs ready"

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION_NAME' does not exist." >&2
    echo "  (Are you running this from inside the coordinator's session?)" >&2
    exit 2
fi

# Fetch the issue before any cap is claimed, so a bad issue number or a gh
# outage refuses cleanly instead of failing mid-brief with a pending marker
# already written.
if ! ISSUE_TEXT="$(gh issue view "$ISSUE")"; then
    echo "ERROR: gh issue view $ISSUE failed — nothing queued." >&2
    exit 2
fi

# A live iss-N window means "queue a follow-up": no caps, no spawn.
# remain-on-exit=failed (llm-start.sh) keeps a crashed window listed, so a
# dead pane is reclaimed and treated as no window (#493).
WINDOW_EXISTS=0
if window_listed "$WINDOW"; then
    WINDOW_EXISTS=1
    if pane_is_dead "$WINDOW"; then
        echo "[*] window $WINDOW exists but its pane is dead — reclaiming" >&2
        tmux capture-pane -t "$SESSION_NAME:$WINDOW.0" -p 2>/dev/null | tail -20 >&2 || true
        tmux kill-window -t "$SESSION_NAME:$WINDOW" 2>/dev/null || true
        # Move its unclaimed/abandoned briefs aside so the fresh listener
        # doesn't re-run stale work next to the new brief.
        stale_briefs=0
        salvage_root="$PROJECT_DIR/.swarm/salvaged/$WINDOW"
        for sub in inbox processing; do
            for f in "$WT/.swarm/tasks/$sub"/*.md; do
                [ -e "$f" ] || continue
                mkdir -p "$salvage_root/$sub"
                mv "$f" "$salvage_root/$sub/" 2>/dev/null && stale_briefs=$((stale_briefs + 1))
            done
        done
        if [ "$stale_briefs" -gt 0 ]; then
            echo "       Salvaged $stale_briefs stale brief(s) to $salvage_root/ (preserved, not auto-rerun — review and re-file if still relevant)" >&2
            # If a check below refuses, the issue is left with no window and
            # no queued brief; say where the briefs went.
            trap 'rc=$?; [ "$rc" -ne 0 ] && echo "       Note: issue #$ISSUE still has $stale_briefs brief(s) salvaged to $salvage_root/ from the reclaim above, now unqueued until this is retried." >&2; :' EXIT
        fi
        log_event worker.dead_pane_reclaimed "issue=$ISSUE window=$WINDOW stale_briefs_salvaged=$stale_briefs"
        WINDOW_EXISTS=0
    fi
fi

# Caps run before the brief is written, so a refusal leaves inbox/ untouched
# (#464: a refused-then-retried provision used to run the task twice).
if [ "$WINDOW_EXISTS" -eq 0 ]; then
    session_cap_check
    host_admission_check
    check_stale_container "$ISSUE" "$CONTAINER"
fi

# 3. Brief, written atomically (mktemp + rename in the same dir). TASK_ID
#    gets a -2, -3... suffix on a same-second collision. PROVISION_NOW_EPOCH
#    freezes "now" for tests (#192).
if [ -n "${PROVISION_NOW_EPOCH:-}" ]; then
    NOW_FMT="$(date -d "@$PROVISION_NOW_EPOCH" +%Y%m%d-%H%M%S 2>/dev/null \
        || date -r "$PROVISION_NOW_EPOCH" +%Y%m%d-%H%M%S)"
else
    NOW_FMT="$(date +%Y%m%d-%H%M%S)"
fi
INBOX="$WT/.swarm/tasks/inbox"
BASE_ID="$NOW_FMT-$ISSUE"
TASK_ID="$BASE_ID"
N=2
while [ -e "$INBOX/$TASK_ID.md" ]; do
    TASK_ID="$BASE_ID-$N"
    N=$((N + 1))
done

TMP="$(mktemp -p "$INBOX" .tmp.XXXXXX.md)"
{
    # refs.md is a "consult when relevant" index, so it rides the brief
    # rather than the system prompt.
    if [ -f "$WORKER_REFS_MD" ]; then
        cat "$WORKER_REFS_MD"
        printf '\n---\n\n'
    fi
    if [ -f .swarm-policy.md ]; then
        printf '## Project Guardrails (MUST OBEY)\n\n'
        cat .swarm-policy.md
        printf '\n---\n\n'
    fi
    printf '## Task\n\nFix issue #%s. Details follow.\n\n' "$ISSUE"
    printf '%s\n' "$ISSUE_TEXT"
} > "$TMP"
# `mv -n` never clobbers; if a same-name brief appeared since the check, take
# the next suffix.
if ! mv -n "$TMP" "$INBOX/$TASK_ID.md" 2>/dev/null || [ -f "$TMP" ]; then
    TASK_ID="$BASE_ID-$N"
    mv "$TMP" "$INBOX/$TASK_ID.md"
fi
DEST="$INBOX/$TASK_ID.md"
echo "[3/4] brief queued: $DEST"

# Warn-only lint for unverifiable briefs (docs/ringer-adoptions.md #6).
if [ "${BRIEF_LINT:-1}" = "1" ] && [ -x "$SCRIPT_DIR/lint-brief.sh" ]; then
    "$SCRIPT_DIR/lint-brief.sh" "$DEST" || true
fi

# 4. Spawn (detached, so the coordinator keeps focus).
if [ "$WINDOW_EXISTS" -eq 1 ]; then
    echo "[4/4] tmux window $WINDOW already exists — listener will pick up the new task"
    log_event worker.requeue "issue=$ISSUE task_id=$TASK_ID"
    # issue #594: a new brief just got dispatched into this window — any 📬
    # (finished, no PR) or 👀 (PR ready) flag left over from the PREVIOUS
    # task is stale now. See scripts/_window-flags.sh.
    clear_window_flag "iss-$ISSUE" "📬" "new_brief_claimed task_id=$TASK_ID"
    clear_window_flag "iss-$ISSUE" "👀" "new_brief_claimed task_id=$TASK_ID"
else
    # The window's shell inherits the tmux server env, not this process's,
    # so everything _load-env.sh applied from <project>/.swarm/.env must be
    # handed over explicitly. NAME or NAME=default.
    PASS_VARS=(
        WORKER_CMD=claude WORKER_MODEL WORKER_PROMPT_FILE WORKER_HEADLESS=0
        WORKER_SELF_REVIEW=1 WORKER_SELF_REVIEW_MAX_ROUNDS=3
        SELF_REVIEW_CMD SELF_REVIEW_MODEL
        WORKER_CHECK WORKER_CHECK_CMD WORKER_CHECK_TIMEOUT WORKER_CHECK_RETRY
        SWARM_EVAL_LOG EXTRA_MOUNTS
        SANDBOX_DEP_CACHE SANDBOX_CPUS SANDBOX_GRADLE_LIMITS SANDBOX_GRADLE_WORKERS_MAX
        SANDBOX_KOTLIN_DAEMON_XMX SANDBOX_ALLOW_BACKGROUND_TASKS
    )
    window_cmd="WORKER_CONTAINER_NAME=$(printf '%q' "$CONTAINER")"
    for spec in "${PASS_VARS[@]}"; do
        name="${spec%%=*}"
        default=""; [[ "$spec" == *=* ]] && default="${spec#*=}"
        window_cmd+=" $name=$(printf '%q' "${!name:-$default}")"
    done
    window_cmd+=" $(printf '%q' "$SANDBOX_SH") $(printf '%q' "$WT") listener"
    tmux new-window -d -t "$SESSION_NAME" -n "$WINDOW" "$window_cmd"
    # Pin pane 0 (#555): a user conf sourced between window creations could
    # shift it, breaking every `.0` target.
    tmux set-window-option -t "$SESSION_NAME:iss-$ISSUE" pane-base-index 0 2>/dev/null || true
    echo "[4/4] tmux window $WINDOW spawned (listener)"
    # Logged at spawn time; coordinator-watch.sh anchors its paste-grace
    # window to it (#497). A worker.start.failed may follow.
    log_event worker.start "issue=$ISSUE task_id=$TASK_ID window=$WINDOW alive=$((alive_workers + 1))/$MAX_WORKERS total_windows=$((total_windows + 1))/$MAX_TMUX_WINDOWS"
    post_spawn_health_check "$ISSUE" "$WINDOW" "$CONTAINER" "$DEST"
fi

echo
echo "Provisioned worker for issue #$ISSUE."
echo "  task_id: $TASK_ID"
echo "  worker: tmux window '$SESSION_NAME:$WINDOW'"
echo "  monitor: ls $WT/.swarm/tasks/done/"
echo "  events:  tail -F $EVENTS_LOG"
