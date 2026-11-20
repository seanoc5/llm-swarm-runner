#!/usr/bin/env bash
#
# release-parked-worker.sh — restart a FINISHED worker whose interactive agent
# session is parked at an idle prompt, so its listener claims the brief
# waiting in inbox/ (issue #1025, regression of #941).
#
# Usage:
#   release-parked-worker.sh <issue-N | wt-path> [--dry-run]
#
# Why this exists: requeue.sh drops a brief in inbox/, but a worker that
# finished its task and never ran /quit sits inside the live agent process;
# worker-listener.sh's poll loop is blocked on it and cannot see the brief.
# coordinator-watch.sh releases such a session on its own sweep, but that path
# needs a running watcher plus half a dozen pane-text gates to agree, and it
# failed twice in fand-app on 2026-11-19. This script is the same release done
# synchronously, from the coordinator's own shell, with every safety check
# reading files and git state rather than pane text.
#
# It restarts (kill window + provision-worker.sh --wake) only when ALL hold:
#   - an agent process (not the listener's bash) owns the window's pane
#   - a brief is waiting in inbox/
#   - nothing is claimed in processing/ (the worker is not mid-task)
#   - the newest done/ outcome JSON exists (the worker declared itself done)
#   - the pane shows no busy marker (no "esc to interrupt", spinner, ...)
#   - the worktree is clean and has no unpushed commits (nothing is lost)
# Otherwise it exits 1 and prints the failed condition; nothing is touched.
#
# Exit codes: 0 released (or dry-run would), 1 refused (condition above not
# met; the brief stays queued), 2 usage/resolution error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"
PROVISION_WORKER="${PROVISION_WORKER:-$SCRIPT_DIR/provision-worker.sh}"
# shellcheck source=scripts/_pane-composer.sh
. "$SCRIPT_DIR/_pane-composer.sh"
# shellcheck source=scripts/_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" 2>/dev/null || true

TARGET="${1:-}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
[ -n "$TARGET" ] || { echo "usage: release-parked-worker.sh <issue-N | wt-path> [--dry-run]" >&2; exit 2; }

if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    PROJECT_DIR="${PROJECT_DIR:-$PWD}"
    WT="$(swarm_worktree_dir "$PROJECT_DIR" "$TARGET")"
else
    WT="$TARGET"
fi
[ -d "$WT" ] || { echo "ERROR: worktree not found: $WT" >&2; exit 2; }
WT="$(cd "$WT" && pwd)"

case "$(basename "$WT")" in
    wt-issue-[0-9]*) ISSUE="${WT##*/wt-issue-}" ;;
    *) echo "ERROR: $WT is not a wt-issue-<N> worktree" >&2; exit 2 ;;
esac
WIN="iss-$ISSUE"

GIT_COMMON_DIR="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "ERROR: $WT is not a git worktree" >&2; exit 2; }
MAIN_REPO="$(dirname "$GIT_COMMON_DIR")"
SESSION_NAME="llm-$(basename "$MAIN_REPO")"

refuse() { echo "release-parked-worker: not releasing $WIN — $1" >&2; exit 1; }

tmux has-session -t "$SESSION_NAME" 2>/dev/null || refuse "no tmux session $SESSION_NAME"
pane_cmd="$(tmux list-panes -t "$SESSION_NAME:$WIN" -F '#{pane_current_command}' 2>/dev/null | sed -n 1p)" || pane_cmd=""
case "$pane_cmd" in
    "") refuse "no window $WIN in $SESSION_NAME" ;;
    bash|zsh|sh|fish) refuse "pane is the listener's own shell, which claims the brief itself" ;;
esac

TASKS="$WT/.swarm/tasks"
find "$TASKS/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -q . \
    || refuse "no brief waiting in inbox/"
find "$TASKS/processing" -maxdepth 1 -type f 2>/dev/null | grep -q . \
    && refuse "a task is still claimed in processing/ (worker not finished)"
find "$TASKS/done" -maxdepth 1 -type f \( -name '*.ok.json' -o -name '*.err.json' \) 2>/dev/null | grep -q . \
    || refuse "no done/ outcome JSON (worker never declared itself done)"

# ANSI-stripped capture; the dim suggested-prompt on the composer line is not
# activity, so only the busy markers are matched (same pattern the watcher uses).
pane_text="$(tmux capture-pane -t "$SESSION_NAME:$WIN.0" -p 2>/dev/null || true)"
if printf '%s\n' "$pane_text" | LC_ALL=C grep -qE "${WORKER_COMPACT_BUSY_PATTERN:-$PANE_BUSY_PATTERN_DEFAULT}"; then
    refuse "pane shows a live turn (busy marker on screen)"
fi

porcelain="$(git -C "$WT" status --porcelain 2>/dev/null)" || refuse "git status failed"
[ -z "$porcelain" ] || refuse "worktree has uncommitted changes"
unpushed="$(git -C "$WT" rev-list --count HEAD --not --remotes 2>/dev/null)" || refuse "git rev-list failed"
[ "$unpushed" = "0" ] || refuse "worktree has $unpushed unpushed commit(s)"

if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY] would kill window $WIN + container, then provision-worker.sh --wake $ISSUE"
    exit 0
fi

# Marker first (same contract as the watcher's hard restart): provision-worker
# --wake and sideline_wake_pass both key on it, so a failed wake is retried.
{
    printf 'sidelined_at=%s\n' "$(date -u +%Y%m%dT%H%M%SZ)"
    printf 'reason=release_parked_worker\n'
    printf 'capture=\n'
} > "$WT/.swarm/sidelined" 2>/dev/null || refuse "cannot write .swarm/sidelined marker"

# Last-moment race check: a slow /quit (or the watcher) may have let the
# listener claim the brief already. Killing now would destroy that fresh run.
if ! find "$TASKS/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -q .; then
    rm -f "$WT/.swarm/sidelined"
    refuse "brief was claimed while checking (nothing to do)"
fi

tmux kill-window -t "$SESSION_NAME:$WIN" 2>/dev/null || true
docker stop -t 10 "swarm-${SESSION_NAME}-${WIN}" >/dev/null 2>&1 || true

rc=0
"$PROVISION_WORKER" --wake "$ISSUE" "$MAIN_REPO" || rc=$?
if [ "$rc" != "0" ]; then
    echo "release-parked-worker: provision-worker.sh --wake exited $rc; the .swarm/sidelined marker is set, so coordinator-watch.sh's sideline sweep retries it" >&2
    exit 1
fi
echo "✓ released parked $WIN: session restarted, its listener will claim the queued brief"
