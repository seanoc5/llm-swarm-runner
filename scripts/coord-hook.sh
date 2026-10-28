#!/usr/bin/env bash
# coord-hook.sh — Claude Code hook for the coordinator session (issue #666).
#
# Installed by coordinator-claude.sh via `claude --settings` when
# COORD_HOOK_STATE=1, so it runs for the coordinator process only — never
# for workers or for an operator's ad-hoc `claude` in the same project.
#
# Two jobs, both replacing a screen read in coordinator-watch.sh:
#
#   1. State file. Writes "<state> <epoch>" to .swarm/coordinator-state:
#        UserPromptSubmit -> busy     (a turn started)
#        Stop             -> idle     (the turn ended)
#        Notification     -> waiting  (permission / idle prompt)
#      The watcher reads it instead of matching spinner text on the pane.
#
#   2. Doorbell at turn end. On Stop, if coord-inbox/ holds items newer than
#      the last ring, the hook returns {"decision":"block","reason":<nudge>}
#      and Claude Code continues the turn with the nudge as input — nothing
#      is typed into the composer, so a half-typed operator draft is never
#      at risk. The ring is recorded in .swarm/coord-hook-rang so the
#      watcher treats that wake as delivered instead of pasting it again.
#      stop_hook_active=true (we already rang once this turn end) never
#      rings again, so this cannot loop.
#
#   3. Inbox waiter (COORD_INBOX_WAITER=1). An idle coordinator fires no
#      hooks, so coord-inbox-wait.sh runs as its background shell and wakes
#      it when an item lands. When no waiter is running, Stop asks the
#      coordinator to arm one (appended to the doorbell, or on its own).
#      An ask the coordinator hasn't answered (the waiter deletes
#      coord-waiter-asked when it arms) isn't repeated for
#      COORD_INBOX_WAITER_ASK_SECS, so a coordinator that can't arm it
#      never loops.
#
# Fails open: any error leaves the hook silent (exit 0, no output), which
# Claude Code treats as "no opinion" — the watcher then falls back to its
# screen-based checks because the state file goes stale.

set -uo pipefail

event="${1:-}"
input="$(cat 2>/dev/null || true)"
[ "${COORD_HOOK_STATE:-0}" = "1" ] || exit 0

project="${CLAUDE_PROJECT_DIR:-$PWD}"
swarm="$project/.swarm"
[ -d "$swarm" ] || exit 0

state_file="$swarm/coordinator-state"
rang_file="$swarm/coord-hook-rang"
inbox="$swarm/coord-inbox"
events="$swarm/events.log"
# Must match coordinator-watch.sh's COORD_INBOX_NUDGE_TEMPLATE default
# (tests/test-coord-hook.sh asserts it): the watcher recognises its own
# doorbell by this text.
template="${COORD_INBOX_NUDGE_TEMPLATE:-Inbox: %N item(s) in .swarm/coord-inbox/ — read and triage them (see prompts/coordinator.md \"Inbox\").}"

now="$(date +%s)"

write_state() {
    local tmp
    tmp="$(mktemp "$swarm/.tmp.coordinator-state.XXXXXX" 2>/dev/null)" || return 0
    printf '%s %s\n' "$1" "$now" > "$tmp" && mv -f "$tmp" "$state_file" || rm -f "$tmp"
}

log_event() {
    printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$events" 2>/dev/null || true
}

# waiter_arm_request: prints the "arm the waiter" sentence when
# COORD_INBOX_WAITER=1, no live waiter heartbeat exists, and no unanswered ask
# is younger than COORD_INBOX_WAITER_ASK_SECS; records the ask. Prints
# nothing otherwise.
waiter_arm_request() {
    [ "${COORD_INBOX_WAITER:-0}" = "1" ] || return 0
    local pid_file="$swarm/coord-inbox-waiter" asked_file="$swarm/coord-waiter-asked"
    local pid m asked
    if read -r pid _ 2>/dev/null < "$pid_file" && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        m="$(stat -c %Y "$pid_file" 2>/dev/null || echo 0)"
        [ $((now - m)) -le "${COORD_INBOX_WAITER_STALE_SECS:-30}" ] && return 0
    fi
    asked="$(cat "$asked_file" 2>/dev/null || echo 0)"
    [[ "$asked" =~ ^[0-9]+$ ]] || asked=0
    [ $((now - asked)) -ge "${COORD_INBOX_WAITER_ASK_SECS:-300}" ] || return 0
    printf '%s\n' "$now" > "$asked_file" 2>/dev/null || true
    log_event "coord.waiter.ask"
    printf 'Arm the inbox waiter: run %s %s with run_in_background (Bash), then end your turn. It wakes you when an inbox item lands; nothing more to do with it until then.' \
        "$(printf '%q' "$(cd "$(dirname "$0")" && pwd)/coord-inbox-wait.sh")" "$(printf '%q' "$project")"
}

case "$event" in
    UserPromptSubmit) write_state busy ;;
    Notification)     write_state waiting ;;
    Stop)
        active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
        count=0 newest=0
        for f in "$inbox"/*.md; do
            [ -f "$f" ] || continue
            count=$((count + 1))
            m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
            [ "$m" -gt "$newest" ] && newest="$m"
        done
        last_rang="$(cut -d' ' -f1 "$rang_file" 2>/dev/null || echo 0)"
        [[ "$last_rang" =~ ^[0-9]+$ ]] || last_rang=0
        if [ "$active" != "true" ] && [ "$count" -gt 0 ] && [ "$newest" -gt "$last_rang" ]; then
            printf '%s %s\n' "$now" "$count" > "$rang_file" 2>/dev/null || true
            # Same debounce clock the watcher stamps when it rings.
            printf '%s\n' "$now" > "$swarm/coord-wake-last" 2>/dev/null || true
            write_state busy
            log_event "coord.wake.hook_rang items=$count"
            arm="$(waiter_arm_request)"
            jq -n --arg r "${template//%N/$count}${arm:+ $arm}" '{decision: "block", reason: $r}'
        elif arm="$(waiter_arm_request)" && [ -n "$arm" ]; then
            write_state busy
            jq -n --arg r "$arm" '{decision: "block", reason: $r}'
        else
            write_state idle
        fi
        ;;
esac
exit 0
