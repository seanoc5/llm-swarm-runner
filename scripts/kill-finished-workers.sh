#!/usr/bin/env bash
#
# kill-finished-workers.sh — bulk-close idle iss-* worker tmux windows
#
# Defaults to "parked-or-merged mode": kills iss-* windows that are EITHER
# parked (listener has printed the post-task "[polling for next brief"
# marker — claude exited, listener polling) OR have a MERGED upstream PR
# (issue #386: the default worker is an interactive claude REPL that never
# exits on its own, so "parked" alone is structurally unreachable for it —
# a MERGED PR is at least as strong a "safe to reap" signal). Skips windows
# tied to an open PR (preserves scrollback for review). A parked window is
# reaped regardless of terminal PR state, same as always; the CLOSED-
# without-merge protection is specific to an ACTIVE window (still running
# claude) — that one is left alone by default, since neither "parked" nor
# "merged" hold for it. Rerun with --pr-finalized to also reap those.
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
#
# WINDOWLESS WORKTREES (issue #406)
#   Everything above keys off live `iss-*` tmux windows, so a tmux session
#   restart (every window gone, worktrees untouched on disk) orphans any
#   worktree whose PR already finalized while its window was alive.
#   --with-worktree combined with --merged-only or --pr-finalized (the two
#   modes that already gate purely on PR state, bypassing "parked"
#   scrollback a dead window can no longer show) additionally scans this
#   project's OWN registered worktrees via list-own-worktrees.sh's
#   swarm_own_worktree_dirs() — never a path glob (issue #357) — for any
#   whose issue number has no matching `iss-*` window at all, and applies
#   the exact same terminal-state test before routing removal through
#   kill-worktree.sh (same salvage/orphan-notify semantics as any other
#   reap). A worktree with no window and an OPEN (or absent) PR is left
#   untouched, same as always.

set -euo pipefail

usage() {
    cat <<EOF
kill-finished-workers.sh — bulk-close idle iss-* worker tmux windows

USAGE
    kill-finished-workers.sh [FLAGS]

DESCRIPTION
    Default mode kills iss-* windows that are PR-safe (no OPEN GH PR for
    the branch checked out in that issue's worktree), idle for at least
    --idle-min N (default 0), and EITHER:
      - parked     (listener at "[polling for next brief" — claude exited), or
      - PR-merged  (the branch's PR is MERGED)
    (issue #386: "parked" alone is unreachable for the default interactive
    worker, which never exits its own REPL — a MERGED PR is an equally
    strong "safe to reap" signal.) A parked window is reaped regardless of
    terminal PR state, same as always. An ACTIVE window (still running
    claude) whose PR is CLOSED without merging is the one case left alone
    by default — rerun with --pr-finalized to also reap those. --idle-min
    still defaults to 0, so a freshly-merged active window can be reaped
    immediately with no grace period; pass --idle-min N for one.

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
                            work is preserved upstream). With
                            --with-worktree, also reaps a registered
                            worktree with NO matching iss-* window at all
                            (issue #406 — see WINDOWLESS WORKTREES above).
        --pr-finalized      Reap when PR state is MERGED *or* CLOSED.
                            "Finalized" means GitHub considers the PR done
                            (user merged it, or closed it as
                            rejected/superseded/duplicate). Local worktree
                            + branch are removed; the branch on origin is
                            preserved, so a CLOSED PR remains recoverable
                            via `gh pr reopen N`. Used by the watcher's
                            autoclose pass for smoother slot reclamation.
                            Parked check is bypassed in this mode for the
                            same reason as --merged-only. With
                            --with-worktree, also reaps a registered
                            worktree with NO matching iss-* window at all
                            (issue #406 — see WINDOWLESS WORKTREES above).
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
    kill-finished-workers.sh                          # (parked or merged) + PR-safe
    kill-finished-workers.sh --dry-run                # preview
    kill-finished-workers.sh --idle-min 5             # at least 5 min idle
    kill-finished-workers.sh --no-pr-check            # don't hit gh
    kill-finished-workers.sh --all                    # include active
    kill-finished-workers.sh --with-worktree          # (parked or merged) + worktrees
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

# issue #406: --merged-only/--pr-finalized already gate purely on PR state
# (bypassing "parked", which needs a live window to observe in the first
# place), so with --with-worktree these two modes still have windowless
# worktrees worth scanning even when zero iss-* windows exist at all (a
# tmux session restart drops every window but leaves worktrees on disk).
# Every other mode/flag combo keeps the old exit-immediately behavior.
CHECK_WINDOWLESS=0
if [ "$WITH_WT" = "1" ] && { [ "$MERGED_ONLY" = "1" ] || [ "$PR_FINALIZED" = "1" ]; }; then
    CHECK_WINDOWLESS=1
fi

if [ "${#WINDOWS[@]}" -eq 0 ]; then
    echo "No iss-* windows in session '$SESSION_NAME'."
    if [ "$CHECK_WINDOWLESS" = "0" ]; then
        exit 0
    fi
    echo "Scanning for windowless worktrees (--with-worktree + pr-gated mode)..."
else
    echo "Found ${#WINDOWS[@]} iss-* window(s) in session '$SESSION_NAME':"
fi

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

# Populates PR_STATE / PR_CREATED_AT / PR_NUMBER for the given branch with a
# single `gh pr view` round-trip. Returns 1 (all three left empty) when no
# PR exists for the branch. issue #386: the old code called `gh pr view`
# separately for the default mode's open-PR guard and again for
# --merged-only/--pr-finalized — up to twice per window for the same PR.
# Callers gate the call itself (see the main loop) so plain default mode
# with --no-pr-check still avoids the network entirely.
PR_STATE=""
PR_CREATED_AT=""
PR_NUMBER=""
fetch_pr_state() {
    local branch="$1" json
    PR_STATE=""
    PR_CREATED_AT=""
    PR_NUMBER=""
    json=$(gh pr view "$branch" --json state,createdAt,number -q '"\(.state)\t\(.createdAt)\t\(.number)"' 2>/dev/null || true)
    [ -n "$json" ] || return 1
    IFS=$'\t' read -r PR_STATE PR_CREATED_AT PR_NUMBER <<< "$json"
    return 0
}

# True if the last fetch_pr_state() call found an OPEN PR (i.e., should
# preserve the window/worktree regardless of mode).
pr_is_open() {
    [ "$PR_STATE" = "OPEN" ]
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

# Returns 0 if the PR state cached by fetch_pr_state() is MERGED (strict)
# AND was created after the given worktree came into existence. Returns 1
# for OPEN, CLOSED-without-merge, no PR at all, or a MERGED PR that
# predates the worktree (issue #185 — stale history from a recycled branch
# name, not evidence about the CURRENT worktree). Used by --merged-only
# mode, and (issue #386) as part of default mode's parked-OR-merged gate,
# so we never reap a worktree whose work hasn't been preserved upstream.
pr_is_merged() {
    local wt="$1"
    if [ -z "$PR_STATE" ]; then
        PR_SKIP_REASON="no PR found"
        return 1
    fi
    if [ "$PR_STATE" != "MERGED" ]; then
        PR_SKIP_REASON="not MERGED (state=$PR_STATE)"
        return 1
    fi
    if pr_predates_worktree "$PR_CREATED_AT" "$wt"; then
        PR_SKIP_REASON="terminal state predates this worktree"
        return 1
    fi
    return 0
}

# Returns 0 if the PR state cached by fetch_pr_state() is finalized —
# MERGED or CLOSED — AND was created after the given worktree came into
# existence. Returns 1 for OPEN, no PR at all, or a finalized PR that
# predates the worktree (issue #185). Used by --pr-finalized mode so the
# watcher can also reap PRs the user has rejected/closed without merging
# (superseded, duplicate, abandoned). Local worktree + branch get removed,
# but the origin branch is preserved by kill-worktree.sh (it only does
# `git branch -D`, never `git push --delete`), so accidental closures are
# recoverable via `gh pr reopen N`.
pr_is_finalized() {
    local wt="$1"
    if [ -z "$PR_STATE" ]; then
        PR_SKIP_REASON="no PR found"
        return 1
    fi
    case "$PR_STATE" in
        MERGED|CLOSED) : ;;
        *)
            PR_SKIP_REASON="not MERGED|CLOSED (state=$PR_STATE)"
            return 1
            ;;
    esac
    if pr_predates_worktree "$PR_CREATED_AT" "$wt"; then
        PR_SKIP_REASON="terminal state predates this worktree"
        return 1
    fi
    return 0
}

# Decide which ones to kill ---------------------------------------------------
KILL_LIST=()
declare -A KILL_REASONS KILL_BRANCH
# issue #406: issue numbers already covered by a live iss-* window, so the
# windowless-worktree scan below never double-processes one whose window
# just happens to still be around.
declare -A WINDOW_ISSUES
for w in "${WINDOWS[@]}"; do
    WINDOW_ISSUES["${w#iss-}"]=1
done
# Tally of default-mode windows skipped only because their PR is CLOSED
# without merging — surfaced in the "nothing to kill" summary below so
# --pr-finalized doesn't stay a silent, undiscoverable escape hatch
# (issue #386 part 1).
SKIPPED_FINALIZED=0
for w in "${WINDOWS[@]}"; do
    issue="${w#iss-}"
    reasons=()
    branch=""
    wt=""
    parked=0
    merged=0

    # Resolve the worktree's actual branch + fetch PR state ONCE per
    # window (single `gh pr view` round-trip) whenever any mode needs PR
    # info: --merged-only/--pr-finalized always do; plain PR_CHECK (the
    # default and --all) does unless --no-pr-check disabled the network
    # entirely. Done up front so both the eligibility gate below and the
    # later PR-safety check can read the same cached PR_STATE instead of
    # each hitting `gh` separately.
    if [ "$MERGED_ONLY" = "1" ] || [ "$PR_FINALIZED" = "1" ] || [ "$PR_CHECK" = "1" ]; then
        branch="$(worktree_branch "$issue")"
        if [ -z "$branch" ]; then
            echo "  $w  [can't resolve worktree branch (detached HEAD or corrupt worktree registration) → skip]"
            continue
        fi
        wt="$(swarm_worktree_dir "$PROJECT_DIR" "$issue")"
        fetch_pr_state "$branch" || true
    fi

    # Eligibility gate.
    #
    # issue #386: default mode used to gate on is_parked() alone — pane
    # scrollback showing the listener's "[polling for next brief" marker,
    # printed only after the agent invocation returns (worker-listener.sh's
    # print_completion_block). The default worker is an interactive claude
    # REPL that never exits on its own, so that marker — and therefore
    # "parked" — is structurally unreachable for it; default mode could
    # never reap a single default-shaped worker, merged PR or not. A
    # branch whose PR is MERGED is at least as strong a "safe to reap"
    # signal as parked scrollback (the watcher's --merged-only mode
    # already treats it that way), so default mode now reaps on parked OR
    # PR-merged.
    #
    # --merged-only and --pr-finalized use PR state exclusively (parked is
    # a strictly weaker signal there) and --all bypasses this gate by
    # design (its whole purpose is to include active windows).
    if [ "$ALL" = "1" ]; then
        reasons+=("--all")
    elif [ "$MERGED_ONLY" = "1" ] || [ "$PR_FINALIZED" = "1" ]; then
        reasons+=("pr-gated")
    else
        is_parked "$w" && parked=1
        if [ "$PR_CHECK" = "1" ] && pr_is_merged "$wt"; then
            merged=1
        fi
        if [ "$parked" = "0" ] && [ "$merged" = "0" ]; then
            if [ "$PR_CHECK" = "1" ] && [ "$PR_STATE" = "CLOSED" ]; then
                echo "  $w  [active, PR #$PR_NUMBER CLOSED (not merged) → skip (parked-only mode; rerun with --pr-finalized to reap)]"
                SKIPPED_FINALIZED=$((SKIPPED_FINALIZED + 1))
            else
                echo "  $w  [active → skip]"
            fi
            continue
        fi
        [ "$parked" = "1" ] && reasons+=("parked")
        [ "$merged" = "1" ] && reasons+=("PR-merged")
    fi

    # Idle-min check (applied in all modes when N>0)
    if [ "$IDLE_MIN" -gt 0 ]; then
        idle=$(window_idle_min "$w")
        if [ "$idle" -lt "$IDLE_MIN" ]; then
            echo "  $w  [idle ${idle}m < ${IDLE_MIN}m → skip]"
            continue
        fi
        reasons+=("idle ${idle}m")
    fi

    # PR check (applied in all modes when enabled). Uses the PR_STATE
    # cached by fetch_pr_state above, resolved once per window against the
    # actual checked-out branch (see worktree_branch), not the
    # dirname-derived fix/issue-N. wt is passed alongside so
    # pr_is_merged/pr_is_finalized can ignore a terminal PR that predates
    # this worktree (issue #185).
    if [ "$MERGED_ONLY" = "1" ]; then
        if ! pr_is_merged "$wt"; then
            echo "  $w  [PR $branch: ${PR_SKIP_REASON:-unknown reason} → skip (merged-only mode)]"
            continue
        fi
        reasons+=("PR-merged")
    elif [ "$PR_FINALIZED" = "1" ]; then
        if ! pr_is_finalized "$wt"; then
            echo "  $w  [PR $branch: ${PR_SKIP_REASON:-unknown reason} → skip (pr-finalized mode)]"
            continue
        fi
        reasons+=("PR-finalized")
    elif [ "$PR_CHECK" = "1" ]; then
        if pr_is_open; then
            echo "  $w  [PR $branch still OPEN → skip (use --no-pr-check to override)]"
            continue
        fi
        # Already covered by the eligibility gate's "PR-merged" reason
        # above — avoid a redundant token in the kill-line/reap.window log.
        [ "$merged" = "1" ] || reasons+=("PR-safe")
    fi

    # Survived all filters → kill
    echo "  $w  [$(IFS=,; echo "${reasons[*]}") → kill]"
    KILL_LIST+=("$w")
    reasons_str="$(IFS=,; echo "${reasons[*]}")"
    KILL_REASONS[$w]="${reasons_str// /_}"
    KILL_BRANCH[$w]="${branch:-}"
done

# Windowless worktrees (issue #406) -------------------------------------------
#
# A tmux session restart drops every iss-* window while the worktrees
# themselves (and whatever PR state their branch reached in the meantime)
# survive untouched on disk. The loop above can never see one of these —
# it only ever iterates WINDOWS. --merged-only/--pr-finalized already gate
# purely on terminal PR state rather than "parked" scrollback (which needs
# a live window to print into), so those two modes extend naturally to a
# worktree with no window at all. Discovered via swarm_own_worktree_dirs
# (sourced from _load-env.sh — same function list-own-worktrees.sh wraps)
# rather than a path glob (issue #357), and gated on --with-worktree since
# there is nothing to reap here without it.
if [ "$CHECK_WINDOWLESS" = "1" ]; then
    while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        issue="$(basename "$wt")"
        issue="${issue#wt-issue-}"
        # Already decided above (its iss-* window is still alive) — skip
        # to avoid a duplicate kill-worktree.sh invocation.
        [ -n "${WINDOW_ISSUES[$issue]:-}" ] && continue

        w="iss-$issue"
        reasons=()
        # Same detached-HEAD/corrupt-registration guard as worktree_branch()
        # above: print an explicit skip rather than silently falling back
        # to a dirname-derived branch that may have nothing to do with
        # what's actually checked out here.
        branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        if [ -z "$branch" ]; then
            echo "  $w  [no window; can't resolve worktree branch (detached HEAD or corrupt worktree registration) → skip]"
            continue
        fi
        fetch_pr_state "$branch" || true

        if [ "$MERGED_ONLY" = "1" ]; then
            if ! pr_is_merged "$wt"; then
                echo "  $w  [no window; PR $branch: ${PR_SKIP_REASON:-unknown reason} → skip (merged-only mode)]"
                continue
            fi
            reasons+=("no-window" "PR-merged")
        else
            if ! pr_is_finalized "$wt"; then
                echo "  $w  [no window; PR $branch: ${PR_SKIP_REASON:-unknown reason} → skip (pr-finalized mode)]"
                continue
            fi
            reasons+=("no-window" "PR-finalized")
        fi

        echo "  $w  [$(IFS=,; echo "${reasons[*]}") → kill]"
        KILL_LIST+=("$w")
        reasons_str="$(IFS=,; echo "${reasons[*]}")"
        KILL_REASONS[$w]="${reasons_str// /_}"
        KILL_BRANCH[$w]="$branch"
    done < <(swarm_own_worktree_dirs "$PROJECT_DIR")
fi

if [ "${#KILL_LIST[@]}" -eq 0 ]; then
    echo
    if [ "$SKIPPED_FINALIZED" -gt 0 ]; then
        echo "Nothing to kill given current filters. $SKIPPED_FINALIZED window(s) have a closed (non-merged) PR — rerun with --pr-finalized to reap them."
    else
        echo "Nothing to kill given current filters."
    fi
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
