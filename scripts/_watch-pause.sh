#!/usr/bin/env bash
#
# _watch-pause.sh — shared reader for the watcher pause sentinel (issue #457).
# Sourced by coordinator-watch.sh, coord-hook.sh, coord-inbox-wait.sh and
# watch-pause.sh; defines functions only, prints nothing when sourced.
#
# The sentinel is <project>/.swarm/watch-paused, plain key=value lines:
#   until=<epoch>     when the pause ends (always present)
#   mode=quiet|full   quiet: keep polling and writing coord-inbox/, only the
#                     doorbell is withheld. full: the timer sweeps (reaps,
#                     compaction, worker delivery) stop too.
#   reason=<text>     optional, shown in the pane and the event log
#   since=<epoch>     when it was written
#
# It is re-read on every use (never cached), so a pause starts and ends with
# no watcher restart, and it expires by itself: a forgotten pause cannot
# strand a swarm. A held wake is not lost while paused: the inbox note is
# already on disk (#430) and the hold-retry pass delivers one nudge, with the
# live item count, once the pause is over.

# watch_pause_file <swarm-dir>
watch_pause_file() { printf '%s/watch-paused\n' "$1"; }

# watch_pause_read <swarm-dir>
# Sets WP_UNTIL, WP_MODE, WP_REASON, WP_SINCE and returns 0 while a pause is
# in force. Returns 1 (and clears the WP_* vars) when there is none, the file
# is unreadable or has no valid until=, or the pause has expired. An expired
# sentinel is removed and logged as coord.resume exactly once: the rename is
# the claim, so two processes noticing the expiry cannot both log it.
watch_pause_read() {
    local f line k v now
    f="$(watch_pause_file "$1")"
    WP_UNTIL="" WP_MODE="" WP_REASON="" WP_SINCE=""
    [ -f "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            until)  WP_UNTIL="$v" ;;
            mode)   WP_MODE="$v" ;;
            reason) WP_REASON="$v" ;;
            since)  WP_SINCE="$v" ;;
        esac
    done < "$f" 2>/dev/null
    [[ "$WP_UNTIL" =~ ^[0-9]+$ ]] || { WP_UNTIL="" ; return 1; }
    [ "$WP_MODE" = "full" ] || WP_MODE="quiet"
    now="$(date +%s)"
    if [ "$now" -ge "$WP_UNTIL" ]; then
        if mv "$f" "$f.expired.$$" 2>/dev/null; then
            # A new pause may have replaced the expired file between the read
            # and the rename. If what we claimed is still live, put it back
            # (-n: never over a newer one) and treat the pause as in force.
            local claimed
            claimed="$(sed -n '/^until=/{s///p;q}' "$f.expired.$$" 2>/dev/null)"
            if [[ "$claimed" =~ ^[0-9]+$ ]] && [ "$claimed" -gt "$(date +%s)" ]; then
                mv -n "$f.expired.$$" "$f" 2>/dev/null || true
                rm -f "$f.expired.$$"
                watch_pause_read "$1"
                return
            fi
            rm -f "$f.expired.$$"
            watch_pause_log "$1" "coord.resume reason=expired mode=$WP_MODE"
        fi
        WP_UNTIL="" WP_MODE="" WP_REASON="" WP_SINCE=""
        return 1
    fi
    return 0
}

# watch_pause_active <swarm-dir>: any pause (quiet or full) in force.
watch_pause_active() { watch_pause_read "$1"; }

# watch_pause_full <swarm-dir>: a full pause in force.
watch_pause_full() { watch_pause_read "$1" && [ "$WP_MODE" = "full" ]; }

# watch_pause_describe: one line for the pane / --status, after a successful
# watch_pause_read. "PAUSED (quiet) until 14:05 (42m left) — deploy window"
watch_pause_describe() {
    local left=$(( WP_UNTIL - $(date +%s) ))
    [ "$left" -ge 0 ] || left=0
    printf 'PAUSED (%s) until %s (%dm%02ds left)%s\n' "$WP_MODE" \
        "$(date -d "@$WP_UNTIL" +%H:%M)" $((left / 60)) $((left % 60)) \
        "${WP_REASON:+ — $WP_REASON}"
}

# watch_pause_log <swarm-dir> "<category> k=v ..."
# Same line shape as the watcher's log_event ("<ts>  <category>  k=v ...").
watch_pause_log() {
    local cat="${2%% *}" rest=""
    [ "$2" = "$cat" ] || rest="${2#* }"
    printf '%s  %-15s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cat" "$rest" \
        >> "$1/events.log" 2>/dev/null || true
}
