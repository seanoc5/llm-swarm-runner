#!/usr/bin/env bash
#
# _window-flags.sh — shared per-window tmux status flags (issue #594).
#
# A tmux window-level user option, `@swarm_flag`, holding one of the
# following single-glyph values. llm-start.sh's window-status-format
# renders it next to the window name so an operator scanning the tab bar —
# never opening every pane — can tell who needs them:
#   📬  worker finished, no PR open (worker status: done-no-pr)
#   👀  worker's PR is open and ready for review (not a draft) AND the
#       worker's pane is idle — never shown while the worker is still mid-
#       turn (e.g. iterating on its own self-review caveats after
#       pr-ready.sh already readied the PR). Optionally suffixed with the
#       PR body's risk rating (👀🟢 / 👀🟡 / 👀🔴, WATCH_WINDOW_FLAG_RISK).
#       Was a bare 🟡 originally; a non-color glyph now so colored dots
#       only ever mean merge risk.
#   ✋  worker posted a decision-needed outbox message, still unprocessed
#   🔔  the coordinator's last turn ended asking for an approval
#
# Sourced, not executed: `. "$SCRIPT_DIR/_window-flags.sh"`. Every caller
# (coordinator-watch.sh, provision-worker.sh, requeue.sh) already defines
# $SESSION_NAME (the swarm tmux session) before calling into this file, and
# already runs its other tmux calls bare (no `-L`), relying on the ambient
# $TMUX the swarm session's own pane sets — same assumption those scripts'
# existing tmux calls already make, nothing new here. A caller's own
# log_event function, if one is defined in the same shell by the time a
# function below actually runs, gets one line per real transition; a
# caller with none just gets the tmux state change silently.
#
# Kill switch: WATCH_WINDOW_FLAGS=0 turns every set/clear below into a
# no-op (default 1).
#
# All four flags share ONE option slot per window, so a caller never "owns"
# the slot outright — it owns exactly the (window, flag) PAIR it passes in.
# set_window_flag only overwrites a flag of equal or LOWER priority, never
# silently replacing a more urgent one still pending; clear_window_flag
# only clears when the CURRENT value is exactly the flag the caller is
# clearing, never erasing a different, more urgent flag that has since
# taken the slot. A flag passed to either function matches any current
# value that STARTS with it, so "👀" owns every risk-suffixed "👀🟢"-style
# variant (first glyphs are all distinct, so no other flag can collide).
# Priority, highest first: ✋ > 👀 > 📬. 🔔 only ever
# targets the "coordinator" window, which no worker flag ever contends
# for, so it is not ranked against the other three.

_window_flag_rank() {
    case "$1" in
        "✋") printf '3\n' ;;
        "👀"*) printf '2\n' ;;
        "📬") printf '1\n' ;;
        "") printf '0\n' ;;
        *) printf '1\n' ;;
    esac
}

_window_flag_current() {
    tmux show-window-options -t "$SESSION_NAME:$1" -v @swarm_flag 2>/dev/null
}

# set_window_flag <window> <flag> <reason>
#
# <window> is a bare tmux window name within $SESSION_NAME (e.g. "iss-42",
# "coordinator") — never an already "$SESSION_NAME:win"-qualified target.
set_window_flag() {
    local win="$1" flag="$2" reason="$3"
    [ "${WATCH_WINDOW_FLAGS:-1}" = "1" ] || return 0
    local cur
    cur="$(_window_flag_current "$win")" || true
    [ "$cur" = "$flag" ] && return 0
    local cur_rank flag_rank
    cur_rank="$(_window_flag_rank "$cur")"
    flag_rank="$(_window_flag_rank "$flag")"
    [ "$cur_rank" -gt "$flag_rank" ] && return 0
    tmux set-window-option -t "$SESSION_NAME:$win" @swarm_flag "$flag" 2>/dev/null || return 0
    if command -v log_event >/dev/null 2>&1; then
        log_event watch.flag "window=$win flag=$flag reason=$reason"
    fi
}

# clear_window_flag <window> <flag> <reason>
#
# <flag> is the flag the caller believes it owns right now — clearing is a
# no-op unless the window's CURRENT flag is this one, or a suffixed variant
# of it (see header).
clear_window_flag() {
    local win="$1" flag="$2" reason="$3"
    [ "${WATCH_WINDOW_FLAGS:-1}" = "1" ] || return 0
    local cur
    cur="$(_window_flag_current "$win")" || true
    [ -n "$cur" ] && [[ "$cur" == "$flag"* ]] || return 0
    tmux set-window-option -t "$SESSION_NAME:$win" -u @swarm_flag 2>/dev/null || return 0
    if command -v log_event >/dev/null 2>&1; then
        log_event watch.flag "window=$win flag=none reason=$reason"
    fi
}
