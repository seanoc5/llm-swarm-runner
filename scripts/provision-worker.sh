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

EVENTS LOG
    Appends to <project>/.swarm/events.log:
      worker.start     new iss-N window created (alive=A/MAX, total=W/MAX)
      worker.requeue   existing iss-N window reused for follow-up task
      cap.refused      MAX_WORKERS, MAX_TMUX_WINDOWS, HOST_MAX_WORKERS, host load,
                       host memory or the spawn stagger refused the spawn (reason=)

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

# Skip cap enforcement if a window for this issue already exists — caps
# don't apply because we're not adding capacity, just queueing a follow-up
# task onto a worker that's already alive.
WINDOW_EXISTS=0
if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
    WINDOW_EXISTS=1
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
    # Container name lets the tmux Ctrl-Z binding `docker exec` into this
    # specific worker. Format must match the binding in ~/.tmux.conf:
    #   swarm-<session>-iss-<issue>
    container_name="swarm-${SESSION_NAME}-iss-${ISSUE}"
    # WORKER_CHECK*/SWARM_EVAL_LOG must ride this line too: _load-env.sh
    # applies <project>/.swarm/.env only in THIS host process, and the tmux
    # window's shell inherits the tmux server env instead — without the
    # explicit hand-off the acceptance-check config documented in
    # .env.example never reaches sandbox.sh (and thus never the listener).
    tmux new-window -d -t "$SESSION_NAME" -n "iss-$ISSUE" \
        "WORKER_CONTAINER_NAME=$(printf '%q' "$container_name") WORKER_CMD=$(printf '%q' "${WORKER_CMD:-claude}") WORKER_MODEL=$(printf '%q' "${WORKER_MODEL:-}") WORKER_HEADLESS=$(printf '%q' "${WORKER_HEADLESS:-0}") WORKER_SELF_REVIEW=$(printf '%q' "${WORKER_SELF_REVIEW:-1}") WORKER_CHECK=$(printf '%q' "${WORKER_CHECK:-}") WORKER_CHECK_CMD=$(printf '%q' "${WORKER_CHECK_CMD:-}") WORKER_CHECK_TIMEOUT=$(printf '%q' "${WORKER_CHECK_TIMEOUT:-}") WORKER_CHECK_RETRY=$(printf '%q' "${WORKER_CHECK_RETRY:-}") SWARM_EVAL_LOG=$(printf '%q' "${SWARM_EVAL_LOG:-}") EXTRA_MOUNTS=$(printf '%q' "${EXTRA_MOUNTS:-}") SANDBOX_DEP_CACHE=$(printf '%q' "${SANDBOX_DEP_CACHE:-}") SANDBOX_CPUS=$(printf '%q' "${SANDBOX_CPUS:-}") SANDBOX_GRADLE_LIMITS=$(printf '%q' "${SANDBOX_GRADLE_LIMITS:-}") SANDBOX_GRADLE_WORKERS_MAX=$(printf '%q' "${SANDBOX_GRADLE_WORKERS_MAX:-}") SANDBOX_KOTLIN_DAEMON_XMX=$(printf '%q' "${SANDBOX_KOTLIN_DAEMON_XMX:-}") SANDBOX_ALLOW_BACKGROUND_TASKS=$(printf '%q' "${SANDBOX_ALLOW_BACKGROUND_TASKS:-}") $(printf '%q' "$SANDBOX_SH") $(printf '%q' "$WT") listener"
    echo "[4/4] tmux window iss-$ISSUE spawned (listener)"
    log_event worker.start "issue=$ISSUE task_id=$TASK_ID window=iss-$ISSUE alive=$((alive_workers + 1))/$MAX_WORKERS total_windows=$((total_windows + 1))/$MAX_TMUX_WINDOWS"
fi

echo
echo "Provisioned worker for issue #$ISSUE."
echo "  task_id: $TASK_ID"
echo "  worker: tmux window '$SESSION_NAME:iss-$ISSUE'"
echo "  monitor: ls $WT/.swarm/tasks/done/"
echo "  events:  tail -F $EVENTS_LOG"
