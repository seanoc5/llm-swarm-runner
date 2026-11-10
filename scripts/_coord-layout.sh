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
COORD_VIEWER_MIN_ROWS=3   # smallest viewer worth adding

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
    tmux list-windows -t "$session" -F '#W' 2>/dev/null | grep -x coordinator >/dev/null || return 1
    coord_pane_is_viewer "$session:coordinator.0" && return 1
    [ -n "$(coord_viewer_panes "$session")" ] && return 0
    # Floor on the session pane (#785 review): the viewer gets pct% of the
    # window but never so much that the session keeps fewer than
    # COORD_VIEWER_MIN_SESSION_ROWS rows (one row goes to the border). Busy
    # and composer checks read that pane's screen; a few rows can push the
    # "esc to interrupt" line off it. A window too short to hold both gets no
    # viewer at all (return 1) instead of a session pane that cannot be read.
    local min_rows="${COORD_VIEWER_MIN_SESSION_ROWS:-12}" height rows max_rows
    case "$min_rows" in ''|*[!0-9]*) min_rows=12 ;; esac
    height="$(tmux display-message -p -t "$session:coordinator.0" -F '#{pane_height}' 2>/dev/null)" || height=""
    case "$height" in ''|*[!0-9]*) return 1 ;; esac
    max_rows=$((height - min_rows - 1))
    if [ "$max_rows" -lt "$COORD_VIEWER_MIN_ROWS" ]; then
        echo "coord-layout: window is $height rows; need >= $((min_rows + 1 + COORD_VIEWER_MIN_ROWS)) for a viewer beside a $min_rows-row session pane; not adding one" >&2
        return 1
    fi
    rows=$((height * pct / 100))
    [ "$rows" -le "$max_rows" ] || rows="$max_rows"
    [ "$rows" -ge "$COORD_VIEWER_MIN_ROWS" ] || rows="$COORD_VIEWER_MIN_ROWS"
    local new
    new="$(tmux split-window -d -v -l "$rows" -P -F '#{pane_id}' \
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

# coord_pane_busy_visible <pane-target> <busy-pattern>: true when the VISIBLE
# rows of the pane match. This is the master behaviour of every busy check.
# Use it wherever a stale marker would lead to pasting over an operator draft
# or to reporting that something was submitted or started (#785 review):
# reprompt_composer_dirty, reprompt_confirm_submitted, compact_confirm_submitted
# and the wait-for-compaction-to-start loop. A tmux failure reads "not busy".
# (grep -E >/dev/null, not grep -q: callers run under pipefail, and -q exiting
# early SIGPIPEs the sed upstream, so a long capture would never match.)
coord_pane_busy_visible() {
    local target="$1" pattern="$2" strip content
    strip='s/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g'
    content="$(tmux capture-pane -t "$target" -p 2>/dev/null)" || return 1
    printf '%s\n' "$content" | sed "$strip" | LC_ALL=C grep -E "$pattern" >/dev/null
}

# coord_viewer_layout_on <pane-target>: true when that pane's window holds a
# viewer pane, i.e. COORD_VIEWER's layout is actually in effect. Without it
# every busy check behaves exactly as it did before #785.
coord_viewer_layout_on() {
    tmux list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | grep -Fx -- "$COORD_VIEWER_TITLE" >/dev/null
}

# coord_pane_busy_match <pane-target> <busy-pattern>: true when the pane is
# mid-turn, for "don't interrupt" checks ONLY (#785 review): the watcher's hold
# gate, the skip-compaction gate, the don't-send-Escape gate. Those fail toward
# waiting when a marker is stale. Never call it where a stale marker would lead
# to a paste or to reporting success; use coord_pane_busy_visible there.
#
# With no viewer pane in the window (COORD_VIEWER off) this is exactly
# coord_pane_busy_visible, whatever the pane's height.
#
# With the viewer layout on, the session pane is short. `capture-pane -p` reads
# only the visible rows, and a long todo list can push the "esc to interrupt"
# line above them, so a doorbell or /compact would land mid-turn. So when the
# pane is shorter than COORD_BUSY_FULL_ROWS (24) and the visible rows show no
# marker, the last COORD_BUSY_SCROLLBACK_LINES (60) lines of scrollback are
# searched too.
#
# Scrollback can hold a marker from a turn that ended (a redraw taller than
# the pane leaves old frames behind), and nothing there ever scrolls away on
# its own. So a scrollback-only match is trusted only while the pane's
# visible-plus-scrollback text is still changing: the text is hashed, and once
# it has not changed for COORD_BUSY_SCROLLBACK_MAX_SECS (90) the match is
# ignored (idle) until the text changes again. Worst case, a stale marker
# reads busy for 90s. A match on the visible rows needs no such guard. Any
# tmux failure reads as "not busy", like the visible-only checks did.
# (grep -E >/dev/null, not grep -q: callers run under pipefail, and -q exiting
# early SIGPIPEs the sed upstream, so a long capture would never match.)
coord_pane_busy_match() {
    local target="$1" pattern="$2" strip height hist state now
    strip='s/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g'
    coord_pane_busy_visible "$target" "$pattern" && return 0
    coord_viewer_layout_on "$target" || return 1   # setting off: master behaviour
    height="$(tmux display-message -p -t "$target" -F '#{pane_height}' 2>/dev/null)" || return 1
    case "$height" in ''|*[!0-9]*) return 1 ;; esac
    state="${COORD_BUSY_STATE_FILE:-${TMPDIR:-/tmp}/llm-swarm-busy-$(id -u)-$(printf '%s' "$target" | tr -c 'A-Za-z0-9' _)}"
    if [ "$height" -ge "${COORD_BUSY_FULL_ROWS:-24}" ]; then
        rm -f "$state" 2>/dev/null
        return 1
    fi
    hist="$(tmux capture-pane -t "$target" -p -S "-${COORD_BUSY_SCROLLBACK_LINES:-60}" 2>/dev/null)" || return 1
    if ! printf '%s\n' "$hist" | sed "$strip" | LC_ALL=C grep -E "$pattern" >/dev/null; then
        rm -f "$state" 2>/dev/null
        return 1
    fi
    local sum since prev_sum prev_since
    sum="$(printf '%s' "$hist" | cksum | cut -d' ' -f1)"
    now="$(date +%s)"
    prev_sum=""; prev_since=""
    [ -r "$state" ] && read -r prev_sum prev_since < "$state" 2>/dev/null || true
    case "$prev_since" in ''|*[!0-9]*) prev_sum="" ;; esac
    if [ "$prev_sum" != "$sum" ]; then
        printf '%s %s\n' "$sum" "$now" > "$state" 2>/dev/null || true
        return 0
    fi
    [ $((now - prev_since)) -lt "${COORD_BUSY_SCROLLBACK_MAX_SECS:-90}" ]
}
