#!/usr/bin/env bash
# coordinator-layout.sh — turn the coordinator-window viewer layout on or off
# for a RUNNING swarm (issue #785; docs/coordinator-viewer.md).
#
# Usage (run from the project dir, or pass PROJECT_DIR):
#   coordinator-layout.sh on  [PROJECT_DIR]   add the read-only conversation
#                                             viewer below the Claude session
#   coordinator-layout.sh off [PROJECT_DIR]   close the viewer; session and
#                                             watcher are untouched
#   coordinator-layout.sh status [PROJECT_DIR]
# To make it the default at every llm-start.sh, set COORD_VIEWER=1 in
# .swarm/.env (viewer height: COORD_VIEWER_PCT, default 75).
# Internal: viewer-loop PROJECT_DIR (what the viewer pane runs).
set -uo pipefail
# Always this script's own checkout, never the ambient LLM_SWARM_DIR.
LLM_SWARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmd="${1:-}"; project="${2:-$PWD}"
case "$cmd" in -h|--help|"") sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
project="$(cd "$project" && pwd)"
# shellcheck source=_load-env.sh
. "$LLM_SWARM_DIR/scripts/_load-env.sh" "$project"
SESSION_NAME="llm-$(basename "$project")"
SWARM_SOCKET="swarm-$(basename "$project")"
# viewer-loop runs inside the tmux server it belongs to: plain tmux follows $TMUX.
[ "$cmd" = viewer-loop ] || tmux() { command tmux -L "$SWARM_SOCKET" "$@"; }
. "$LLM_SWARM_DIR/scripts/_coord-layout.sh"
if [ "$cmd" != viewer-loop ]; then
    tmux has-session -t "$SESSION_NAME" 2>/dev/null ||
        { echo "coordinator-layout.sh: no tmux session '$SESSION_NAME' on socket '$SWARM_SOCKET'" >&2; exit 2; }
fi
case "$cmd" in
    on)  coord_layout_on "$SESSION_NAME" "$project" "$LLM_SWARM_DIR" "${COORD_VIEWER_PCT:-75}" ||
             { echo "coordinator-layout.sh: viewer not added (no live coordinator pane, or the window is too short for the session-pane minimum)" >&2; exit 1; }
         echo "viewer on" ;;
    off) coord_layout_off "$SESSION_NAME"; echo "viewer off" ;;
    status) if [ -n "$(coord_viewer_panes "$SESSION_NAME")" ]; then echo on; else echo off; fi ;;
    viewer-loop) coord_layout_viewer_loop "$project" ;;
    *) echo "coordinator-layout.sh: unknown command '$cmd'" >&2; exit 2 ;;
esac
