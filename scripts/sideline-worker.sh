#!/usr/bin/env bash
#
# sideline-worker.sh — free an idle worker's slot, keep everything else.
#
# Issue #622. Stops the worker's tmux window and container (the two things
# MAX_WORKERS and HOST_MAX_WORKERS count) and keeps the worktree, branch,
# PR and the agent's transcripts. A "warm" archive: the next brief that
# lands in the worktree's inbox (requeue.sh) gets the worker re-spawned by
# coordinator-watch.sh through `provision-worker.sh --wake`, which runs the
# normal caps and host admission first.
#
# Not to be confused with an interactive session "parked at rest" (#313):
# that worker still holds its slot; a sidelined one does not.
#
# Usage:
#   sideline-worker.sh <issue> [project-dir] [--reason TEXT]
#
# Steps:
#   1. Refuse (exit 3) if the inbox holds a queued brief — that worker is
#      about to have work, so sidelining it would only bounce it.
#   2. Save the window's scrollback to
#      <project>/.swarm/sidelined/iss-N-<utc>.txt.
#   3. Move any claimed brief in processing/ to <wt>/.swarm/tasks/sidelined/
#      (kept, not re-run on wake; a stalled task needs a fresh brief that
#      says what to do next).
#   4. Write the marker <wt>/.swarm/sidelined (key=value lines).
#   5. Kill the iss-N window and stop the container.
#   6. Log worker.sideline to <project>/.swarm/events.log.
#
# Exit: 0 sidelined, 2 usage/setup error, 3 refused (queued brief).
set -euo pipefail

REASON="manual"
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --reason) REASON="${2:?--reason needs text}"; shift 2 ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1' (try --help)" >&2; exit 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
ISSUE="${ARGS[0]:-}"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "usage: sideline-worker.sh <issue> [project-dir] [--reason TEXT]" >&2; exit 2; }
PROJECT_DIR="$(cd "${ARGS[1]:-$PWD}" && pwd)"
REASON="${REASON// /_}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"
WT="$(swarm_worktree_dir "$PROJECT_DIR" "$ISSUE")"
SESSION_NAME="${SESSION_NAME:-llm-$(basename "$PROJECT_DIR")}"
WINDOW="iss-$ISSUE"
CONTAINER="swarm-${SESSION_NAME}-iss-${ISSUE}"

EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
log_event() {
    local cat="$1"; shift
    printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

[ -d "$WT/.swarm/tasks" ] || { echo "ERROR: no worker queue at $WT/.swarm/tasks" >&2; exit 2; }

shopt -s nullglob
queued=("$WT"/.swarm/tasks/inbox/*.md)
if [ ${#queued[@]} -gt 0 ]; then
    echo "REFUSED: $WT has ${#queued[@]} queued brief(s) in inbox/ — not sidelining a worker that is about to run." >&2
    exit 3
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
capture_dir="$PROJECT_DIR/.swarm/sidelined"
mkdir -p "$capture_dir"
capture="$capture_dir/iss-$ISSUE-$stamp.txt"
if ! tmux capture-pane -p -t "$SESSION_NAME:$WINDOW.0" -S -2000 > "$capture" 2>/dev/null; then
    rm -f "$capture"
    capture=""
fi

parked_dir="$WT/.swarm/tasks/sidelined"
briefs=()
for f in "$WT"/.swarm/tasks/processing/*.md; do
    mkdir -p "$parked_dir"
    mv "$f" "$parked_dir/" && briefs+=("$parked_dir/$(basename "$f")")
done
shopt -u nullglob

{
    printf 'sidelined_at=%s\n' "$stamp"
    printf 'reason=%s\n' "$REASON"
    printf 'capture=%s\n' "$capture"
    for f in "${briefs[@]}"; do printf 'brief=%s\n' "$f"; done
} > "$WT/.swarm/sidelined"

tmux kill-window -t "$SESSION_NAME:$WINDOW" 2>/dev/null || true
# The container runs in the window's foreground and is --rm, so killing the
# window normally ends it; stop it explicitly so the host-wide count
# (running swarm-* containers) drops now, not whenever docker notices.
docker stop -t 10 "$CONTAINER" >/dev/null 2>&1 || true

log_event worker.sideline "issue=$ISSUE reason=$REASON briefs=${#briefs[@]} capture=${capture:-none}"
echo "Sidelined issue #$ISSUE ($REASON): window and container stopped; worktree kept at $WT."
[ ${#briefs[@]} -gt 0 ] && echo "  claimed brief moved to $parked_dir/"
[ -n "$capture" ] && echo "  scrollback: $capture"
echo "  wake it by queueing a brief:  $SCRIPT_DIR/requeue.sh $ISSUE <brief-file>"
