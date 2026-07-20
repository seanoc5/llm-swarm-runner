#!/usr/bin/env bash
#
# kill-finished-workers.sh — bulk-close idle iss-* worker tmux windows
#
# Defaults to "parked-only mode": kills iss-* windows whose listener is at
# "Waiting for next" (claude exited, listener polling). Skips windows tied
# to an open PR (preserves scrollback for review). Active workers are left
# alone.
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

set -euo pipefail

usage() {
    cat <<EOF
kill-finished-workers.sh — bulk-close idle iss-* worker tmux windows

USAGE
    kill-finished-workers.sh [FLAGS]

DESCRIPTION
    Default mode kills iss-* windows that are ALL of:
      - parked  (listener at "Waiting for next" — claude has exited)
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
PR_CHECK=1
MERGED_ONLY=0
PR_FINALIZED=0
IDLE_MIN=0
SESSION_NAME="${SESSION_NAME:-llm-$(basename "$PWD")}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"
KILL_WT="$LLM_SWARM_DIR/scripts/kill-worktree.sh"

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

# Returns 0 if pane scrollback shows the listener parked at "Waiting for next".
is_parked() {
    tmux capture-pane -t "$SESSION_NAME:$1" -p -S -5 2>/dev/null | grep -q 'Waiting for next'
}

# Returns minutes since last pane activity. Uses tmux's window_activity
# (last data sent to the pane) — listener's 2s sleep loop doesn't print
# anything, so this stays at the last "Task complete" line's wall-clock time.
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

# Returns 0 if there's an OPEN GH PR for fix/issue-N (i.e., should preserve).
# Returns 1 otherwise (no PR, merged, closed). Network round-trip; gated by
# PR_CHECK at call site.
has_open_pr() {
    local issue="$1"
    # `gh pr view <branch>` is the cheapest single-PR query. Output filtered
    # for state. 2>/dev/null swallows "no pull requests found" noise.
    local state
    state=$(gh pr view "fix/issue-$issue" --json state -q .state 2>/dev/null || true)
    [ "$state" = "OPEN" ]
}

# Returns 0 if the PR for fix/issue-N is MERGED (strict). Returns 1 for
# OPEN, CLOSED-without-merge, or no PR at all. Used by --merged-only mode
# so we never reap a worktree whose work hasn't been preserved upstream.
pr_is_merged() {
    local issue="$1"
    local state
    state=$(gh pr view "fix/issue-$issue" --json state -q .state 2>/dev/null || true)
    [ "$state" = "MERGED" ]
}

# Returns 0 if the PR for fix/issue-N is finalized — MERGED or CLOSED.
# Returns 1 for OPEN or no PR at all. Used by --pr-finalized mode so the
# watcher can also reap PRs the user has rejected/closed without merging
# (superseded, duplicate, abandoned). Local worktree + branch get removed,
# but origin/fix/issue-N is preserved by kill-worktree.sh (it only does
# `git branch -D`, never `git push --delete`), so accidental closures are
# recoverable via `gh pr reopen N`.
pr_is_finalized() {
    local issue="$1"
    local state
    state=$(gh pr view "fix/issue-$issue" --json state -q .state 2>/dev/null || true)
    [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]
}

# Decide which ones to kill ---------------------------------------------------
KILL_LIST=()
for w in "${WINDOWS[@]}"; do
    issue="${w#iss-}"
    reasons=()

    # Parked check.
    #
    # Default mode uses pane scrollback ("Waiting for next" → listener
    # parked, claude has exited) as a proxy for "safe to reap." But
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

    # PR check (applied in both modes when enabled)
    if [ "$MERGED_ONLY" = "1" ]; then
        if ! pr_is_merged "$issue"; then
            echo "  $w  [PR fix/issue-$issue not MERGED → skip (merged-only mode)]"
            continue
        fi
        reasons+=("PR-merged")
    elif [ "$PR_FINALIZED" = "1" ]; then
        if ! pr_is_finalized "$issue"; then
            echo "  $w  [PR fix/issue-$issue not MERGED|CLOSED → skip (pr-finalized mode)]"
            continue
        fi
        reasons+=("PR-finalized")
    elif [ "$PR_CHECK" = "1" ]; then
        if has_open_pr "$issue"; then
            echo "  $w  [PR fix/issue-$issue still OPEN → skip (use --no-pr-check to override)]"
            continue
        fi
        reasons+=("PR-safe")
    fi

    # Survived all filters → kill
    echo "  $w  [$(IFS=,; echo "${reasons[*]}") → kill]"
    KILL_LIST+=("$w")
done

if [ "${#KILL_LIST[@]}" -eq 0 ]; then
    echo
    echo "Nothing to kill given current filters."
    exit 0
fi

if [ "$DRY" = "1" ]; then
    echo
    echo "DRY-RUN — no action taken. Would kill: ${KILL_LIST[*]}"
    [ "$WITH_WT" = "1" ] && echo "Would also remove worktrees + branches via kill-worktree.sh"
    exit 0
fi

# Execute --------------------------------------------------------------------
echo
for w in "${KILL_LIST[@]}"; do
    issue="${w#iss-}"
    if [ "$WITH_WT" = "1" ]; then
        if [ -x "$KILL_WT" ]; then
            echo "→ $w (issue #$issue): kill-worktree.sh (window + worktree + branch)"
            KILL_WT_ARGS=("$issue")
            [ "$NO_COMPOSE_DOWN" = "1" ] && KILL_WT_ARGS+=(--no-compose-down)
            "$KILL_WT" "${KILL_WT_ARGS[@]}" || echo "  WARN: kill-worktree.sh exited non-zero (continuing)"
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
