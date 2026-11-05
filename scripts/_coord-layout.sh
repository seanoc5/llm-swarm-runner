#!/usr/bin/env bash
#
# _coord-layout.sh — helpers for COORD_VIEWER=1 (issue #785): the coordinator
# window holds the Claude session (small, typing) plus a read-only viewer
# (large) running scripts/coordinator-conversation.sh. Sourced by llm-start.sh,
# coordinator-watch.sh and coordinator-layout.sh; defines functions only, and
# calls `tmux` unqualified so the caller's socket-scoped shadow applies.
#
# Invariant: the Claude session is ALWAYS pane 0 of the coordinator window.
# Every doorbell, composer check, busy check and capture targets
# "$SESSION:coordinator.0". The viewer is split BELOW pane 0 (split-window -v
# without -b), so tmux numbers it 1 and the session keeps index 0. The viewer
# carries the pane title COORD_VIEWER_TITLE; callers that have to assume pane 0
# is the session (llm-start.sh, the watcher) check coord_pane_is_viewer first,
# because closing the session pane by hand renumbers the viewer to 0.

COORD_VIEWER_TITLE="coord-viewer"

# coord_pane_is_viewer <pane-target>: true when that pane is the viewer.
coord_pane_is_viewer() {
    local title
    title="$(tmux display-message -p -t "$1" -F '#{pane_title}' 2>/dev/null)" || return 1
    [ "$title" = "$COORD_VIEWER_TITLE" ]
}

# coord_viewer_panes <session>: ids of viewer panes in the coordinator window.
coord_viewer_panes() {
    tmux list-panes -t "$1:coordinator" -F '#{pane_id} #{pane_title}' 2>/dev/null |
        awk -v t="$COORD_VIEWER_TITLE" '$2 == t { print $1 }'
}

# coord_layout_on <session> <project-dir> <llm-swarm-dir> [viewer-percent]:
# add the viewer below the session pane. Idempotent. Returns 1 when there is
# no coordinator window or its pane 0 is itself the viewer (session gone).
coord_layout_on() {
    local session="$1" project="$2" swarm_dir="$3" pct="${4:-75}"
    case "$pct" in ''|*[!0-9]*) pct=75 ;; esac
    [ "$pct" -ge 10 ] && [ "$pct" -le 90 ] || pct=75
    tmux list-windows -t "$session" -F '#W' 2>/dev/null | grep -qx coordinator || return 1
    coord_pane_is_viewer "$session:coordinator.0" && return 1
    [ -n "$(coord_viewer_panes "$session")" ] && return 0
    local new
    new="$(tmux split-window -d -v -l "${pct}%" -P -F '#{pane_id}' \
        -t "$session:coordinator.0" -c "$project" \
        "exec bash $(printf '%q' "$swarm_dir/scripts/coordinator-layout.sh") viewer-loop $(printf '%q' "$project")")" || return 1
    tmux select-pane -t "$new" -T "$COORD_VIEWER_TITLE"
    tmux select-pane -t "$session:coordinator.0"
}

# coord_layout_off <session>: close the viewer pane(s). The session pane and
# the watcher are untouched.
coord_layout_off() {
    local p
    for p in $(coord_viewer_panes "$1"); do
        tmux kill-pane -t "$p" 2>/dev/null || true
    done
}

# coord_layout_viewer_loop <project-dir>: what the viewer pane runs. A viewer
# crash only restarts the viewer. It closes its own pane when it is the last
# pane left (the session pane was closed), so a stray viewer never becomes
# pane 0 for long.
coord_layout_viewer_loop() {
    local project="$1" here="${TMUX_PANE:-}"
    while :; do
        if [ -n "$here" ] && [ "$(tmux list-panes -t "$here" -F x 2>/dev/null | wc -l)" -eq 1 ]; then
            tmux kill-pane -t "$here" 2>/dev/null || true
            return 0
        fi
        # Don't let a viewer failure propagate; show it and retry.
        bash "$(dirname "${BASH_SOURCE[0]}")/coordinator-conversation.sh" "$project" --tail 20 --interval 2 &
        local pid=$!
        # Re-check for a lone pane while the viewer runs.
        while kill -0 "$pid" 2>/dev/null; do
            sleep 3
            if [ -n "$here" ] && [ "$(tmux list-panes -t "$here" -F x 2>/dev/null | wc -l)" -eq 1 ]; then
                kill "$pid" 2>/dev/null || true
                tmux kill-pane -t "$here" 2>/dev/null || true
                return 0
            fi
        done
        wait "$pid" || echo "[viewer exited rc=$?; restarting in 3s]" >&2
        sleep 3
    done
}
