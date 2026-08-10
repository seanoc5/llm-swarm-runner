#!/usr/bin/env bash
#
# sandbox-worktrees.sh — List git worktrees and optionally launch sandboxes
# and/or create tmux windows for each.
#
# Usage:
#   sandbox-worktrees.sh [options] [project-dir]
#
# Options:
#   -a, --agent AGENT      Launch sandbox with this agent (claude, gemini, codex, bash, listener).
#                           Without -t: launches in the current shell (exec).
#                           With -t: launches in each tmux window.
#   -t, --tmux             Create a tmux window per worktree
#   -s, --start-window N   First tmux window number (default: 7, implies --tmux)
#   -h, --help             Show this help
#
# With no flags, lists all worktrees and their branches — useful as a quick
# status check. Add -t to create tmux windows, -a to launch sandboxes.
#
# Examples:
#   # Just list worktrees
#   sandbox-worktrees.sh /opt/work/oconeco/fand-api
#
#   # Launch Claude sandbox in current window for this worktree
#   sandbox-worktrees.sh -a claude
#
#   # Create tmux windows 7+ for each worktree
#   sandbox-worktrees.sh -t /opt/work/oconeco/fand-api
#
#   # Create tmux windows AND launch Claude in each
#   sandbox-worktrees.sh -t -a claude /opt/work/oconeco/fand-api
#
#   # Start at window 3
#   sandbox-worktrees.sh -s 3 -a claude /opt/work/oconeco/fand-api
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
START_WINDOW=7
AGENT=""
PROJECT_DIR=""
USE_TMUX=false

usage() {
    sed -n '3,/^set /{ /^#/s/^# \?//p }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--start-window) START_WINDOW="$2"; USE_TMUX=true; shift 2 ;;
        -a|--agent)        AGENT="$2"; shift 2 ;;
        -t|--tmux)         USE_TMUX=true; shift ;;
        -h|--help)         usage ;;
        -*)                echo "Unknown option: $1" >&2; exit 1 ;;
        *)                 PROJECT_DIR="$1"; shift ;;
    esac
done

PROJECT_DIR="$(realpath "${PROJECT_DIR:-$PWD}")"

# Validate: must be a git repo
if ! git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    echo "Error: $PROJECT_DIR is not a git repository" >&2
    exit 1
fi

# Validate: tmux required when creating windows
if $USE_TMUX && [ -z "${TMUX:-}" ]; then
    echo "Error: not inside a tmux session (required for -t/--tmux)" >&2
    exit 1
fi

# --- Single-worktree mode: -a without -t launches sandbox in current shell ---
if [ -n "$AGENT" ] && ! $USE_TMUX; then
    exec "$REPO_ROOT/sandbox.sh" "$PROJECT_DIR" "$AGENT"
fi

# --- Multi-worktree mode: list (and optionally create tmux windows) ---

# Resolve the main repo root (handles being called from a worktree)
MAIN_REPO="$(git -C "$PROJECT_DIR" worktree list --porcelain | head -1 | sed 's/^worktree //')"

# Collect all worktrees (main first, then extras sorted by path)
mapfile -t WORKTREES < <(git -C "$MAIN_REPO" worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //')

if [ ${#WORKTREES[@]} -eq 0 ]; then
    echo "No worktrees found for $MAIN_REPO"
    exit 1
fi

echo "Found ${#WORKTREES[@]} worktree(s) for $(basename "$MAIN_REPO"):"
echo ""

WINDOW=$START_WINDOW
for wt in "${WORKTREES[@]}"; do
    wt_name="$(basename "$wt")"

    # Check branch/HEAD state for display
    branch="$(git -C "$wt" branch --show-current 2>/dev/null || echo "detached")"
    [ -z "$branch" ] && branch="detached"

    # Smart format the branch name for tmux: strip common prefixes
    short_branch="$branch"
    if [[ "$short_branch" == */* ]]; then
        # Remove everything before the last slash for typical prefix/name branches
        short_branch="${short_branch##*/}"
    fi

    if $USE_TMUX; then
        echo "  Window $WINDOW: $wt_name ($branch)"

        # Create tmux window (or reuse if it already exists at that index)
        if tmux list-windows -F '#{window_index}' | grep -q "^${WINDOW}$"; then
            echo "    -> window $WINDOW already exists, skipping creation"
        else
            tmux new-window -t "$WINDOW" -n "$short_branch" -c "$wt"
        fi

        # Optionally launch sandbox
        if [ -n "$AGENT" ]; then
            # Run the sandbox, then rename the window when it exits
            tmux send-keys -t "$WINDOW" "$REPO_ROOT/sandbox.sh $wt $AGENT; tmux rename-window '💤 $short_branch'" Enter
            echo "    -> launched sandbox ($AGENT)"
        fi

        WINDOW=$((WINDOW + 1))
    else
        echo "  $wt_name ($branch)"
        echo "    $wt"
    fi
done

echo ""
if $USE_TMUX; then
    echo "Done. Use <tmux-prefix> $START_WINDOW through <tmux-prefix> $((WINDOW - 1)) to switch windows."
else
    echo "Use -t to create tmux windows, -a to launch sandboxes."
fi
