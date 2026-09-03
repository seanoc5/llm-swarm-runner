#!/usr/bin/env bash
#
# kill-finished-workers.sh — bulk-close idle iss-* worker tmux windows
#
# Defaults to "parked-only mode": kills iss-* windows whose listener has
# printed the post-task "[polling for next brief" marker (claude exited,
# listener polling). Skips windows tied to an open PR (preserves scrollback
# for review). Active workers are left alone.
#
# Use --all to include active windows.
# Use --merged-only / --pr-finalized to gate on PR state instead of
#   listener-parked state — these modes reap even when claude's REPL is
#   still open, since the upstream PR being MERGED|CLOSED is a stronger
#   "safe to reap" signal than pane scrollback.
# Use --no-pr-check to skip the gh round-trip and ignore PR state.
# Use --idle-min N to require N min of pane inactivity before killing.
# Use --with-worktree to also remove the git worktree + delete branch.
# Use --dry-run to preview without action.
# Use --yes to skip the confirmation prompt for --all --with-worktree.
# Use --no-compose-down to skip tearing down a worktree's docker compose
#   stack (only meaningful with --with-worktree).
#
# EVENTS LOG + PANE ARCHIVE
#   Every actual kill appends a `reap.window` line to
#   <project>/.swarm/events.log (issue, window, branch, reasons,
#   with_worktree, capture) and snapshots the pane's last
#   REAP_CAPTURE_LINES (default 500) scrollback lines to
#   <project>/.swarm/reaped/iss-N-<utc>.txt before the window dies.
#   Dry runs log nothing.
#
# UNPROCESSED BRIEFS (issue #317)
#   With --with-worktree, kill-worktree.sh salvages any unprocessed
#   inbox/processing/outbox briefs into <project>/.swarm/salvaged/iss-N/
#   before removing the worktree (or, with --refuse-nonempty-inbox, skips
#   that worktree entirely). --dry-run previews the would-be-salvaged
#   counts per window without touching anything.

set -euo pipefail

usage() {
    cat <<EOF
kill-finished-workers.sh — bulk-close idle iss-* worker tmux windows

USAGE
    kill-finished-workers.sh [FLAGS]

DESCRIPTION
    Default mode kills iss-* windows that are ALL of:
      - parked  (listener at "[polling for next brief" — claude has exited)
      - PR-safe (no open GH PR exists for fix/issue-N)
      - idle for at least --idle-min N (default 0)

FLAGS
    -h, --help              Show this help and exit
    -a, --all               Include active windows (claude still running).
                            PR-check + idle-min still apply unless overridden.
        --no-pr-check       Skip 'gh pr view fix/issue-N' check (avoid network)
        --merged-only       STRICT: only reap when PR state is MERGED.
                            Strictest mode — guarantees no unmerged work
                            is destroyed even on origin. PR-state is a
                            stronger signal than listener-parked, so the
                            parked check is bypassed in this mode (the
                            window is reaped even if claude's REPL is
                            still open — the PR being MERGED means the
                            work is preserved upstream).
        --pr-finalized      Reap when PR state is MERGED *or* CLOSED.
                            "Finalized" means GitHub considers the PR done
                            (user merged it, or closed it as
                            rejected/superseded/duplicate). Local worktree
                            + branch are removed; the branch on origin is
                            preserved, so a CLOSED PR remains recoverable
                            via `gh pr reopen N`. Used by the watcher's
                            autoclose pass for smoother slot reclamation.
                            Parked check is bypassed in this mode for the
                            same reason as --merged-only.
    -i, --idle-min N        Require N+ minutes since last pane activity
                            (default 0 — any parked window is eligible)
    -w, --with-worktree     Also remove git worktree + delete branch
                            (calls kill-worktree.sh; uncommitted work LOST)
        --no-compose-down   Skip docker compose teardown before worktree
                            removal (preserves containers for inspection;
                            only meaningful with --with-worktree)
        --refuse-nonempty-inbox
                            Forwarded to kill-worktree.sh: skip a worktree
                            entirely (no removal) instead of salvaging
                            unprocessed inbox/outbox briefs (issue #317).
                            Only meaningful with --with-worktree.
    -n, --dry-run           List what would be killed; take no action
    -y, --yes               Skip the --all --with-worktree confirmation
    -s, --session NAME      Override session name
                            (default: llm-\$(basename \$PWD))

EXAMPLES
    kill-finished-workers.sh                          # parked + PR-safe
    kill-finished-workers.sh --dry-run                # preview
    kill-finished-workers.sh --idle-min 5             # at least 5 min idle
    kill-finished-workers.sh --no-pr-check            # don't hit gh
    kill-finished-workers.sh --all                    # include active
    kill-finished-workers.sh --with-worktree          # parked + worktrees
    kill-finished-workers.sh --all --with-worktree    # full nuke (prompts)
    kill-finished-workers.sh --all --with-worktree -y # full nuke, no prompt
    kill-finished-workers.sh --merged-only --with-worktree -y     # safe auto-reap
    kill-finished-workers.sh --pr-finalized --with-worktree -y    # also reap closed-without-merge
    kill-finished-workers.sh --with-worktree --no-compose-down    # keep containers for inspection
    kill-finished-workers.sh --with-worktree --refuse-nonempty-inbox  # stall instead of salvage

EXIT
    0    success (or nothing to do)
    1    invalid args / session not found / user aborted confirmation
EOF
}

ALL=0
WITH_WT=0
DRY=0
YES=0
NO_COMPOSE_DOWN=0
REFUSE_NONEMPTY_INBOX=0
PR_CHECK=1
MERGED_ONLY=0
PR_FINALIZED=0
IDLE_MIN=0
SESSION_NAME="${SESSION_NAME:-llm-$(basename "$PWD")}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"
KILL_WT="$LLM_SWARM_DIR/scripts/kill-worktree.sh"
PROJECT_DIR="$PWD"

# Source the env loader for SWARM_WORKTREE_GROUPING + swarm_worktree_dir(),
# needed to locate each issue's worktree so PR checks can key off the
# branch actually checked out there (see worktree_branch() below).
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

# Append-only structured event log + reaped-pane archive. Same format as
# coordinator-watch.sh / provision-worker.sh. Every actual kill emits a
# `reap.window` event naming the window, and archives the pane's last
# scrollback lines under .swarm/reaped/ first — reaping destroys the only
# in-flight audit trail (pane history), so snapshot it before the kill.
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
REAPED_DIR="$PROJECT_DIR/.swarm/reaped"
REAP_CAPTURE_LINES="${REAP_CAPTURE_LINES:-500}"
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

require_value() {
    if [ -z "${2:-}" ] || [[ "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            usage; exit 0 ;;
        -a|--all)             ALL=1; shift ;;
        -w|--with-worktree)   WITH_WT=1; shift ;;
        --no-compose-down)    NO_COMPOSE_DOWN=1; shift ;;
        --refuse-nonempty-inbox) REFUSE_NONEMPTY_INBOX=1; shift ;;
        -n|--dry-run)         DRY=1; shift ;;
        -y|--yes)             YES=1; shift ;;
        --no-pr-check)        PR_CHECK=0; shift ;;
        --merged-only)        MERGED_ONLY=1; shift ;;
        --pr-finalized)       PR_FINALIZED=1; shift ;;
        -i|--idle-min)        require_value "$1" "${2:-}"; IDLE_MIN="$2"; shift 2 ;;
        --idle-min=*)         IDLE_MIN="${1#*=}"; shift ;;
        -s|--session)         require_value "$1" "${2:-}"; SESSION_NAME="$2"; shift 2 ;;
        --session=*)          SESSION_NAME="${1#*=}"; shift ;;
        -*)                   echo "ERROR: unknown flag: $1 (try --help)" >&2; exit 1 ;;
        *)                    echo "ERROR: unexpected positional arg: $1 (try --help)" >&2; exit 1 ;;
    esac
done

# IDLE_MIN must be a non-negative integer
if ! [[ "$IDLE_MIN" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --idle-min must be a non-negative integer (got: $IDLE_MIN)" >&2
    exit 1
fi

if [ "$MERGED_ONLY" = "1" ] && [ "$PR_FINALIZED" = "1" ]; then
    echo "ERROR: --merged-only and --pr-finalized are mutually exclusive" >&2
    exit 1
fi

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION_NAME' does not exist" >&2
    exit 1
fi

# Confirmation gate for the most destructive combo.
if [ "$ALL" = "1" ] && [ "$WITH_WT" = "1" ] && [ "$YES" != "1" ] && [ "$DRY" != "1" ]; then
    cat <<'WARN'
WARNING: --all --with-worktree will:
  - kill EVERY iss-* tmux window (active claude sessions terminated)
  - remove EVERY wt-issue-* worktree (uncommitted local work LOST)
  - delete EVERY local fix/issue-* branch (remote PRs preserved)

WARN
    read -r -p "Type 'yes' to proceed: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# Cache `now` once for idle-min math; consistent across loop iterations.
NOW=$(date +%s)

# Find all iss-* windows. nullglob-equivalent via grep that returns 0 lines
# rather than nonzero when no matches.
mapfile -t WINDOWS < <(tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep '^iss-' || true)

if [ "${#WINDOWS[@]}" -eq 0 ]; then
    echo "No iss-* windows in session '$SESSION_NAME'."
    exit 0
fi

echo "Found ${#WINDOWS[@]} iss-* window(s) in session '$SESSION_NAME':"

# Helpers --------------------------------------------------------------------

# Returns 0 if pane scrollback shows the listener parked at the
# "[polling for next brief" marker (the last line of the post-task status
# block; see worker-listener.sh's print_completion_block).
is_parked() {
    tmux capture-pane -t "$SESSION_NAME:$1" -p -S -5 2>/dev/null | grep -q '\[polling for next brief'
}

# Returns minutes since last pane activity. Uses tmux's window_activity
# (last data sent to the pane) — listener's 2s sleep loop doesn't print
# anything, so this stays at the status block's wall-clock time.
window_idle_min() {
    local activity
    activity=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name} #{window_activity}' 2>/dev/null \
                | awk -v w="$1" '$1 == w { print $2 }')
    if [ -z "$activity" ]; then
        echo 0
        return
    fi
    echo $(( (NOW - activity) / 60 ))
}

# Resolves the branch to run PR checks against for issue N. Prefers the
# branch actually checked out in that issue's worktree over the
# dirname-derived fix/issue-N — a parked worker can be repurposed onto a
# different branch mid-life (checkout -B), which decouples the two. Falls
# back to fix/issue-N only when there's no worktree to inspect at all
# (already reaped, or never had --with-worktree applied) — that's the
# pre-#97 behavior and not a regression. If the worktree EXISTS but is on
# a detached HEAD, prints nothing (caller must treat that as "unknown,
# don't reap") rather than silently falling back to fix/issue-N — a stale
# dirname-derived branch could be finalized while the detached HEAD holds
# unrelated, unpreserved work. Mirrors reap-orphan-worktrees.sh's handling.
worktree_branch() {
    local issue="$1" wt
    wt="$(swarm_worktree_dir "$PROJECT_DIR" "$issue")"
    if [ -d "$wt" ]; then
        # || true: git exits nonzero here on a detached HEAD (rc 1) and on a
        # corrupt worktree registration (rc 128 — .git/worktrees/<wt> pruned
        # while the dir survived, e.g. after a docker/session restart).
        # Without the guard, set -e propagates that rc through the caller's
        # command substitution and aborts the ENTIRE reap pass — one sick
        # worktree silently disables autoclose for the whole swarm (#223).
        git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true
        return
    fi
    echo "fix/issue-$issue"
}

# Returns 0 if there's an OPEN GH PR for the given branch (i.e., should
# preserve). Returns 1 otherwise (no PR, merged, closed). Network
# round-trip; gated by PR_CHECK at call site.
has_open_pr() {
    local branch="$1"
    # `gh pr view <branch>` is the cheapest single-PR query. Output filtered
    # for state. 2>/dev/null swallows "no pull requests found" noise.
    local state
    state=$(gh pr view "$branch" --json state -q .state 2>/dev/null || true)
    [ "$state" = "OPEN" ]
}

# Portable mtime (epoch seconds). GNU coreutils first, BSD fallback. Mirrors
# reap-orphan-worktrees.sh's mtime_epoch — kept local since scripts here are
# self-contained (see scripts/README.md).
mtime_epoch() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Counts queued files directly in dir (0 if dir absent/empty): any regular
# file except a `.tmp.*` in-progress write — mirrors worker-listener.sh's
# claim_next_task() selection and kill-worktree.sh's count_queued_files
# (issue #317) exactly; kept local per the self-contained-scripts
# convention (see mtime_epoch above). Used only for the --dry-run preview
# here — kill-worktree.sh does the real count-and-salvage.
count_queued_files() {
    local dir="$1"
    [ -d "$dir" ] || { echo 0; return; }
    find "$dir" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | wc -l | tr -d ' '
}

# worktree_birth_path <worktree-dir>
#
# issue #232: the worktree ROOT directory's mtime bumps on every direct
# child create/rename/delete — .agent-task.md rewrites, build/.gradle
# creation, status-file writes — so any worker activity after the PR opens
# makes the root look "born" later than it really was, permanently
# defeating pr_predates_worktree below. `<worktree>/.git` is a FILE (not a
# dir) for a worktree checkout, written once by `git worktree add` and
# never touched again by normal work, so its mtime is a stable proxy for
# "when this worktree was born." Falls back to the worktree dir itself if
# that file is somehow absent (e.g. a non-worktree checkout in tests).
worktree_birth_path() {
    local wt="$1"
    if [ -f "$wt/.git" ]; then
        printf '%s/.git' "$wt"
    else
        printf '%s' "$wt"
    fi
}

# pr_predates_worktree <created_at-iso8601> <worktree-dir>
#
# issue #185: `gh pr view <branch>` returns the branch's most recent PR in
# ANY state. A recycled branch name whose previous PR is MERGED/CLOSED
# makes a freshly provisioned worktree on that branch look "finalized" to
# pr_is_merged/pr_is_finalized below, even though the terminal PR predates
# this worktree entirely and has nothing to do with the work currently in
# it. Compares the PR's createdAt against the worktree's birth timestamp
# (see worktree_birth_path — issue #232 moved this off the root dir's
# unstable mtime).
#
# Fails CLOSED (i.e. "does NOT predate", not stale) whenever either
# timestamp can't be resolved, so a parsing hiccup falls back to the
# pre-#185 behavior (treat the terminal PR as reap evidence) rather than
# silently blocking a legitimate reap forever.
pr_predates_worktree() {
    local created_at="$1" wt="$2"
    [ -n "$created_at" ] && [ -d "$wt" ] || return 1
    local pr_epoch wt_epoch
    pr_epoch=$(date -d "$created_at" +%s 2>/dev/null) || return 1
    [ -n "$pr_epoch" ] || return 1
    wt_epoch=$(mtime_epoch "$(worktree_birth_path "$wt")") || return 1
    [ -n "$wt_epoch" ] || return 1
    [ "$pr_epoch" -lt "$wt_epoch" ]
}

# Set by pr_is_merged/pr_is_finalized on a 1-return, to the specific
# condition that failed (issue #232: the two conditions used to be
# bundled into one caller-side message — "not MERGED|CLOSED" vs "terminal
# state predates this worktree" are very different diagnoses). Empty/stale
# on a 0-return; callers must only read it right after a failed call.
PR_SKIP_REASON=""

# Returns 0 if the PR for the given branch is MERGED (strict) AND was
# created after the given worktree came into existence. Returns 1 for
# OPEN, CLOSED-without-merge, no PR at all, or a MERGED PR that predates
# the worktree (issue #185 — stale history from a recycled branch name,
# not evidence about the CURRENT worktree). Used by --merged-only mode so
# we never reap a worktree whose work hasn't been preserved upstream.
pr_is_merged() {
    local branch="$1" wt="$2"
    local json state created_at
    json=$(gh pr view "$branch" --json state,createdAt -q '"\(.state)\t\(.createdAt)"' 2>/dev/null)
    if [ -z "$json" ]; then
        PR_SKIP_REASON="no PR found"
        return 1
    fi
    IFS=$'\t' read -r state created_at <<< "$json"
    if [ "$state" != "MERGED" ]; then
        PR_SKIP_REASON="not MERGED (state=$state)"
        return 1
    fi
    if pr_predates_worktree "$created_at" "$wt"; then
        PR_SKIP_REASON="terminal state predates this worktree"
        return 1
    fi
    return 0
}

# Returns 0 if the PR for the given branch is finalized — MERGED or
# CLOSED — AND was created after the given worktree came into existence.
# Returns 1 for OPEN, no PR at all, or a finalized PR that predates the
# worktree (issue #185). Used by --pr-finalized mode so the watcher can
# also reap PRs the user has rejected/closed without merging (superseded,
# duplicate, abandoned). Local worktree + branch get removed, but the
# origin branch is preserved by kill-worktree.sh (it only does `git
# branch -D`, never `git push --delete`), so accidental closures are
# recoverable via `gh pr reopen N`.
pr_is_finalized() {
    local branch="$1" wt="$2"
    local json state created_at
    json=$(gh pr view "$branch" --json state,createdAt -q '"\(.state)\t\(.createdAt)"' 2>/dev/null)
    if [ -z "$json" ]; then
        PR_SKIP_REASON="no PR found"
        return 1
    fi
    IFS=$'\t' read -r state created_at <<< "$json"
    case "$state" in
        MERGED|CLOSED) : ;;
        *)
            PR_SKIP_REASON="not MERGED|CLOSED (state=$state)"
            return 1
            ;;
    esac
    if pr_predates_worktree "$created_at" "$wt"; then
        PR_SKIP_REASON="terminal state predates this worktree"
        return 1
    fi
    return 0
}

# Decide which ones to kill ---------------------------------------------------
KILL_LIST=()
declare -A KILL_REASONS KILL_BRANCH
for w in "${WINDOWS[@]}"; do
    issue="${w#iss-}"
    reasons=()

    # Parked check.
    #
    # Default mode uses pane scrollback ("[polling for next brief" →
    # listener parked, claude has exited) as a proxy for "safe to reap." But
    # --merged-only and --pr-finalized provide a strictly stronger
    # signal — PR state on GitHub. If the upstream PR is MERGED or
    # CLOSED, the work is preserved (or explicitly rejected) regardless
    # of whether claude's local REPL is still open, so the parked check
    # would only block legitimate reaps. Skip it in those modes.
    #
    # --all already bypasses the parked check by design (its whole
    # purpose is to include active windows).
    if [ "$ALL" = "1" ]; then
        reasons+=("--all")
    elif [ "$MERGED_ONLY" = "1" ] || [ "$PR_FINALIZED" = "1" ]; then
        reasons+=("pr-gated")
    else
        if ! is_parked "$w"; then
            echo "  $w  [active → skip]"
            continue
        fi
        reasons+=("parked")
    fi

    # Idle-min check (applied in both modes when N>0)
    if [ "$IDLE_MIN" -gt 0 ]; then
        idle=$(window_idle_min "$w")
        if [ "$idle" -lt "$IDLE_MIN" ]; then
            echo "  $w  [idle ${idle}m < ${IDLE_MIN}m → skip]"
            continue
        fi
        reasons+=("idle ${idle}m")
    fi

    # PR check (applied in both modes when enabled). Resolved once per
    # window against the actual checked-out branch (see worktree_branch),
    # not the dirname-derived fix/issue-N. wt is passed alongside so
    # pr_is_merged/pr_is_finalized can ignore a terminal PR that predates
    # this worktree (issue #185).
    if [ "$MERGED_ONLY" = "1" ] || [ "$PR_FINALIZED" = "1" ] || [ "$PR_CHECK" = "1" ]; then
        branch="$(worktree_branch "$issue")"
        if [ -z "$branch" ]; then
            echo "  $w  [can't resolve worktree branch (detached HEAD or corrupt worktree registration) → skip]"
            continue
        fi
        wt="$(swarm_worktree_dir "$PROJECT_DIR" "$issue")"
    fi
    if [ "$MERGED_ONLY" = "1" ]; then
        if ! pr_is_merged "$branch" "$wt"; then
            echo "  $w  [PR $branch: ${PR_SKIP_REASON:-unknown reason} → skip (merged-only mode)]"
            continue
        fi
        reasons+=("PR-merged")
    elif [ "$PR_FINALIZED" = "1" ]; then
        if ! pr_is_finalized "$branch" "$wt"; then
            echo "  $w  [PR $branch: ${PR_SKIP_REASON:-unknown reason} → skip (pr-finalized mode)]"
            continue
        fi
        reasons+=("PR-finalized")
    elif [ "$PR_CHECK" = "1" ]; then
        if has_open_pr "$branch"; then
            echo "  $w  [PR $branch still OPEN → skip (use --no-pr-check to override)]"
            continue
        fi
        reasons+=("PR-safe")
    fi

    # Survived all filters → kill
    echo "  $w  [$(IFS=,; echo "${reasons[*]}") → kill]"
    KILL_LIST+=("$w")
    reasons_str="$(IFS=,; echo "${reasons[*]}")"
    KILL_REASONS[$w]="${reasons_str// /_}"
    KILL_BRANCH[$w]="${branch:-}"
done

if [ "${#KILL_LIST[@]}" -eq 0 ]; then
    echo
    echo "Nothing to kill given current filters."
    exit 0
fi

if [ "$DRY" = "1" ]; then
    echo
    echo "DRY-RUN — no action taken. Would kill: ${KILL_LIST[*]}"
    if [ "$WITH_WT" = "1" ]; then
        echo "Would also remove worktrees + branches via kill-worktree.sh"
        # issue #317: preview salvage counts per window without touching
        # anything — mirrors the check kill-worktree.sh performs for real.
        for w in "${KILL_LIST[@]}"; do
            issue="${w#iss-}"
            wt="$(swarm_worktree_dir "$PROJECT_DIR" "$issue")"
            [ -d "$wt" ] || continue
            inbox_n=$(count_queued_files "$wt/.swarm/tasks/inbox")
            processing_n=$(count_queued_files "$wt/.swarm/tasks/processing")
            outbox_n=$(count_queued_files "$wt/.swarm/tasks/outbox")
            total=$((inbox_n + processing_n + outbox_n))
            if [ "$total" -gt 0 ]; then
                echo "  $w: would salvage $total unprocessed brief(s) (inbox=$inbox_n processing=$processing_n outbox=$outbox_n)"
            else
                echo "  $w: no unprocessed briefs"
            fi
        done
    fi
    exit 0
fi

# Execute --------------------------------------------------------------------

# Snapshot the pane's tail before killing, then emit the per-target
# reap.window event. The capture is the post-mortem substitute for the
# scrollback the kill destroys — e.g. "who actually ran the merge on that
# high-risk PR" is only answerable from pane history once the window is
# gone. capture=failed (window died between listing and capture) is still
# logged so the reap itself stays on the record.
capture_and_log_reap() {
    local w="$1" issue="$2"
    local ts file capture_ref
    ts="$(date -u +'%Y%m%dT%H%M%SZ')"
    file="$REAPED_DIR/$w-$ts.txt"
    mkdir -p "$REAPED_DIR" 2>/dev/null || true
    if tmux capture-pane -p -t "$SESSION_NAME:$w" -S "-$REAP_CAPTURE_LINES" > "$file" 2>/dev/null; then
        capture_ref="$file"
    else
        capture_ref="failed"
        rm -f "$file" 2>/dev/null || true
    fi
    log_event reap.window \
        "issue=$issue window=$w branch=${KILL_BRANCH[$w]:-unknown} reasons=${KILL_REASONS[$w]:-} with_worktree=$WITH_WT capture=$capture_ref"
}

echo
for w in "${KILL_LIST[@]}"; do
    issue="${w#iss-}"
    capture_and_log_reap "$w" "$issue"
    if [ "$WITH_WT" = "1" ]; then
        if [ -x "$KILL_WT" ]; then
            echo "→ $w (issue #$issue): kill-worktree.sh (window + worktree + branch)"
            KILL_WT_ARGS=("$issue")
            [ "$NO_COMPOSE_DOWN" = "1" ] && KILL_WT_ARGS+=(--no-compose-down)
            [ "$REFUSE_NONEMPTY_INBOX" = "1" ] && KILL_WT_ARGS+=(--refuse-nonempty-inbox)
            kw_rc=0
            "$KILL_WT" "${KILL_WT_ARGS[@]}" || kw_rc=$?
            # issue #181: exit 75 = deferred (in-flight check-on-done claim),
            # not a real failure — kill-worktree.sh retries cleanly next pass.
            # issue #317: exit 76 = refused (non-empty inbox/outbox under
            # --refuse-nonempty-inbox) — also not a real failure, just a
            # worktree deliberately left in place for a human to drain.
            if [ "$kw_rc" -eq 75 ]; then
                echo "  ⏸ deferred: in-flight check-on-done claim (retry next reap pass)"
            elif [ "$kw_rc" -eq 76 ]; then
                echo "  ✗ refused: non-empty inbox/outbox (retry next reap pass, or drop --refuse-nonempty-inbox to salvage+reap)"
            elif [ "$kw_rc" -ne 0 ]; then
                echo "  WARN: kill-worktree.sh exited non-zero (continuing)"
            fi
        else
            echo "ERROR: kill-worktree.sh not executable at $KILL_WT" >&2
            exit 1
        fi
    else
        echo "→ $w: tmux kill-window"
        tmux kill-window -t "$SESSION_NAME:$w" 2>/dev/null || echo "  WARN: kill-window failed (continuing)"
    fi
done

echo
echo "Done. Closed ${#KILL_LIST[@]} window(s)."
