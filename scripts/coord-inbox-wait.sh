#!/usr/bin/env bash
# coord-inbox-wait.sh — the coordinator's background inbox doorbell.
#
# The coordinator runs this as a background shell (Bash run_in_background).
# It blocks until a new item lands in .swarm/coord-inbox/, then prints the
# inbox nudge and exits. Claude Code wakes an idle session when one of its
# background tasks finishes, so the coordinator gets the doorbell without
# anything typed into its composer. coord-hook.sh's Stop hook asks the
# coordinator to re-arm this whenever no waiter is running.
#
# Gated on COORD_INBOX_WAITER=1 (which needs COORD_HOOK_STATE=1). Files:
#   .swarm/coord-inbox-waiter   "<pid> <epoch>"; mtime refreshed every poll.
#                                The watcher holds its typed wake while this
#                                is fresh and the pid is alive.
#   .swarm/coord-hook-rang       shared with coord-hook.sh: an item no newer
#                                than the last ring was already announced.
#
# Doesn't fire while .swarm/coordinator-state reads busy: the Stop hook rings
# at that turn end instead. Exits quietly when its parent shell goes away
# (the coordinator session ended).
#
# Stdout is exactly two lines over the waiter's life: a startup line, then (on
# a wake) the inbox nudge. Heartbeats never go to stdout: after a long idle they
# would bury the nudge, and a reader that keeps only the head or only the tail
# of long background output could lose it. Instead, every
# COORD_INBOX_WAIT_HEARTBEAT_SECS (default 600; 0 disables) the waiter
# overwrites one line in .swarm/coord-inbox-waiter.status (waiting since, last
# poll, inbox counts, coordinator state), so an idle waiter is distinguishable
# from a hung one with `cat`. Only the exit wakes the session.
#
# Usage: coord-inbox-wait.sh [project-dir]

set -uo pipefail

[ "${COORD_INBOX_WAITER:-0}" = "1" ] || { echo "COORD_INBOX_WAITER is off; nothing to arm."; exit 0; }

project="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
swarm="$project/.swarm"
[ -d "$swarm" ] || { echo "no .swarm/ under $project"; exit 0; }

inbox="$swarm/coord-inbox"
pid_file="$swarm/coord-inbox-waiter"
rang_file="$swarm/coord-hook-rang"
status_file="$swarm/coord-inbox-waiter.status"
state_file="$swarm/coordinator-state"
events="$swarm/events.log"
poll="${COORD_INBOX_WAITER_POLL_SECS:-2}"
heartbeat="${COORD_INBOX_WAIT_HEARTBEAT_SECS:-600}"
if [[ "$heartbeat" =~ ^[0-9]+$ ]]; then heartbeat=$((10#$heartbeat)); else heartbeat=600; fi
busy_max="${COORD_HOOK_BUSY_MAX_SECS:-3600}"
# Must match coord-hook.sh and coordinator-watch.sh.
template="${COORD_INBOX_NUDGE_TEMPLATE:-Inbox: %N item(s) in .swarm/coord-inbox/ — read and triage them (see prompts/coordinator.md \"Inbox\").}"

log_event() {
    printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$events" 2>/dev/null || true
}

# One waiter per project. A second one exits at once rather than killing the
# first: killing it would finish that task too, and wake the session twice.
if read -r other _ 2>/dev/null < "$pid_file" && [[ "$other" =~ ^[0-9]+$ ]] \
        && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
    echo "Inbox waiter already armed (pid $other); nothing to do."
    exit 0
fi

start="$(date +%s)"
parent="$PPID"
printf '%s %s\n' "$$" "$start" > "$pid_file"
# Answers coord-hook.sh's arm request, so its next ask isn't throttled.
rm -f "$swarm/coord-waiter-asked"
release() {
    local p=""
    read -r p _ 2>/dev/null < "$pid_file"
    [ "$p" = "$$" ] && rm -f "$pid_file" "$status_file"
}
trap release EXIT
log_event "coord.waiter.armed pid=$$"
printf '[coord-inbox-wait %s] armed pid=%s, watching %s (heartbeat %s)\n' \
    "$(date +%H:%M)" "$$" "$inbox" \
    "$([ "$heartbeat" -gt 0 ] && echo "every ${heartbeat}s to ${status_file#"$project"/}" || echo off)"
next_beat=$((start + heartbeat))

while :; do
    # Parent gone: the session ended. Exit without ringing.
    { [ "$PPID" = "$parent" ] && kill -0 "$parent" 2>/dev/null; } || exit 0
    touch "$pid_file" 2>/dev/null || true

    count=0 wake_count=0 newest=0
    for f in "$inbox"/*.md; do
        [ -f "$f" ] || continue
        count=$((count + 1))
        # Activity-poll items are inbox-only (no doorbell, issue #430): they
        # ride along with the next wake but never trigger one.
        case "${f##*/}" in *-activity-*) continue ;; esac
        wake_count=$((wake_count + 1))
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        [ "$m" -gt "$newest" ] && newest="$m"
    done
    last_rang="$(cut -d' ' -f1 "$rang_file" 2>/dev/null || echo 0)"
    [[ "$last_rang" =~ ^[0-9]+$ ]] || last_rang=0
    # New since arming, and not already rung by the Stop hook.
    if [ "$count" -gt 0 ] && [ "$newest" -ge "$start" ] && [ "$newest" -gt "$last_rang" ]; then
        read -r s e 2>/dev/null < "$state_file" || s=""
        now="$(date +%s)"
        if ! { [ "$s" = busy ] && [[ "$e" =~ ^[0-9]+$ ]] && [ $((now - e)) -le "$busy_max" ]; }; then
            printf '%s %s\n' "$now" "$count" > "$rang_file" 2>/dev/null || true
            printf '%s\n' "$now" > "$swarm/coord-wake-last" 2>/dev/null || true
            # A task-notification wake doesn't fire UserPromptSubmit, so say
            # busy here; the Stop hook writes idle when the turn ends.
            printf 'busy %s\n' "$now" > "$state_file" 2>/dev/null || true
            log_event "coord.wake.waiter_rang items=$count"
            printf '%s\n' "${template//%N/$count}"
            exit 0
        fi
    fi
    if [ "$heartbeat" -gt 0 ]; then
        now="$(date +%s)"
        if [ "$now" -ge "$next_beat" ]; then
            next_beat=$((now + heartbeat))
            up=$((now - start))
            read -r st _ 2>/dev/null < "$state_file" || st=""
            # Overwrite, never append or print: stdout must stay the nudge only.
            printf '[coord-inbox-wait %s] waiting since %s (%dh%02dm), last poll %s, inbox=%s (wake-eligible=%s), coordinator-state=%s\n' \
                "$(date +%H:%M)" "$(date -d "@$start" +%H:%M)" $((up / 3600)) $((up % 3600 / 60)) \
                "$(date +%H:%M:%S)" "$count" "$wake_count" "${st:-unknown}" > "$status_file" 2>/dev/null || true
        fi
    fi
    sleep "$poll"
done
