#!/usr/bin/env bash
# shellcheck disable=SC2034  # COORD_* are read by helpers eval'd from coordinator-watch.sh
# test-coord-inbox-wait.sh — COORD_INBOX_WAITER: the coordinator's background
# waiter rings the inbox doorbell for an idle coordinator, its Stop hook asks
# for a waiter when none is running, and the watcher holds its typed wake
# while one is armed (falling back after the grace). No tmux, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT="$ROOT/scripts/coord-inbox-wait.sh"
HOOK="$ROOT/scripts/coord-hook.sh"
WATCH="$ROOT/scripts/coordinator-watch.sh"
T="$(mktemp -d -t coord-inbox-wait-XXXXXX)"
P="$T/proj"; mkdir -p "$P/.swarm/coord-inbox"
S="$P/.swarm"
pids=()
cleanup() { local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT

export COORD_INBOX_WAITER_POLL_SECS=0.2
waiter() { COORD_INBOX_WAITER="${WV:-1}" "$WAIT" "$P"; }
# Background runs exec directly so $! is the waiter itself, not a subshell.
W=(env COORD_INBOX_WAITER=1 "$WAIT" "$P")
# wait_for <secs> <command...>: polls until the command succeeds.
wait_for() {
    local n=$(( $1 * 10 )); shift
    while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
    return 1
}
alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! kill -0 "$1" 2>/dev/null; }
state() { cut -d' ' -f1 "$S/coordinator-state" 2>/dev/null || echo none; }

# ── the waiter ──────────────────────────────────────────────────────────────
out="$(WV=0 waiter)"
check "COORD_INBOX_WAITER=0: waiter declines and exits" "off" "$(case "$out" in *"is off"*) echo off ;; *) echo "$out" ;; esac)"

echo 1 > "$S/coord-hook-rang"
date +%s > "$S/coord-waiter-asked"
touch -d '1 hour ago' "$S/coord-inbox/old-outcome.md"   # predates arming: never rings
"${W[@]}" > "$T/w1.out" & w1=$!; pids+=("$w1")
wait_for 3 test -f "$S/coord-inbox-waiter" || red "waiter never wrote its pid file"
check "pid file names the waiter" "$w1" "$(cut -d' ' -f1 "$S/coord-inbox-waiter")"
check "arming answers the hook's ask" "gone" "$([ -e "$S/coord-waiter-asked" ] && echo present || echo gone)"
grep -q "coord.waiter.armed pid=$w1" "$S/events.log" && got=yes || got=no
check "arming logged" "yes" "$got"

out="$(waiter)"
check "a second waiter exits at once" "already" "$(case "$out" in *"already armed (pid $w1)"*) echo already ;; *) echo "$out" ;; esac)"

sleep 1.1   # item mtimes below must be >= the waiter's start second
echo "activity" > "$S/coord-inbox/20991231T000000Z-activity-1-1.md"
sleep 0.8
check "an old item or an activity-poll item never rings" "alive" "$(alive "$w1" && echo alive || echo rang)"

echo "busy $(date +%s)" > "$S/coordinator-state"
echo "outcome" > "$S/coord-inbox/20991231T000001Z-outcome-1-1.md"
sleep 0.8
check "coordinator busy: waiter leaves it to the Stop hook" "alive" "$(alive "$w1" && echo alive || echo rang)"

echo "idle $(date +%s)" > "$S/coordinator-state"
wait_for 3 dead "$w1" || red "waiter never rang for an idle coordinator"
wait "$w1" || true
case "$(tail -n 1 "$T/w1.out")" in
    "Inbox: 3 item(s) in .swarm/coord-inbox/"*) got=nudge ;; *) got="$(cat "$T/w1.out")" ;;
esac
check "rings with the nudge, counting every item" "nudge" "$got"
check "ring marks the coordinator busy (no UserPromptSubmit on a task wake)" "busy" "$(state)"
rang="$(cut -d' ' -f1 "$S/coord-hook-rang")"; rc="$(cut -d' ' -f2 "$S/coord-hook-rang")"
[ "$rang" -gt 1 ] && [ "$rc" = 3 ] && got=yes || got="rang=[$rang $rc]"
check "ring recorded in coord-hook-rang" "yes" "$got"
grep -q 'coord.wake.waiter_rang items=3' "$S/events.log" && got=yes || got=no
check "ring logged" "yes" "$got"
check "pid file removed on exit" "gone" "$([ -e "$S/coord-inbox-waiter" ] && echo present || echo gone)"

# Already rung by the Stop hook: the re-armed waiter stays quiet.
echo "idle $(date +%s)" > "$S/coordinator-state"
"${W[@]}" > "$T/w2.out" & w2=$!; pids+=("$w2")
wait_for 3 test -f "$S/coord-inbox-waiter" || red "second waiter never armed"
sleep 1.1
echo "outbox" > "$S/coord-inbox/20991231T000002Z-outbox-1-1.md"
echo "$(( $(date +%s) + 1 )) 4" > "$S/coord-hook-rang"
sleep 0.8
check "an item the Stop hook already rang doesn't ring again" "alive" "$(alive "$w2" && echo alive || echo rang)"
kill "$w2"; wait "$w2" 2>/dev/null || true

# Parent gone (coordinator session ended): exits without ringing.
bash -c "COORD_INBOX_WAITER=1 '$WAIT' '$P' > '$T/w3.out' & echo \$! > '$T/w3.pid'; sleep 0.5"
w3="$(cat "$T/w3.pid")"; pids+=("$w3")
wait_for 3 dead "$w3" || red "orphaned waiter kept running"
check "orphaned waiter exits without ringing" "0" "$(grep -c '^Inbox:' "$T/w3.out" || true)"

# Startup line and heartbeat. Heartbeats go to a status file, never stdout, so
# the wake nudge can't be buried (or truncated away) by long idle output.
check "startup line names pid and inbox path" "yes" \
    "$(grep -q "armed pid=$w1, watching $S/coord-inbox" "$T/w1.out" && echo yes || echo no)"
rm -f "$S/coord-inbox/"*.md "$S/coord-inbox-waiter"
echo "x" > "$S/coord-inbox/20991231T000000Z-activity-9-9.md"   # counts toward inbox=, never wakes
env COORD_INBOX_WAITER=1 COORD_INBOX_WAIT_HEARTBEAT_SECS=1 "$WAIT" "$P" > "$T/hb.out" & hb=$!; pids+=("$hb")
wait_for 5 grep -qs 'waiting since' "$S/coord-inbox-waiter.status" || red "no heartbeat written to the status file"
grep -Eq '^\[coord-inbox-wait [0-9:]+\] waiting since [0-9:]+ \([0-9]+h[0-9]{2}m\), last poll [0-9:]+, inbox=1 \(wake-eligible=0\), coordinator-state=' "$S/coord-inbox-waiter.status" && got=yes || got="$(cat "$S/coord-inbox-waiter.status")"
check "heartbeat status line shows inbox and wake-eligible counts" "yes" "$got"
check "heartbeat doesn't end the waiter" "alive" "$(alive "$hb" && echo alive || echo exited)"
sleep 2.3   # at least two more heartbeats
check "status file is one overwritten line, not appended" "1" "$(wc -l < "$S/coord-inbox-waiter.status" | tr -d ' ')"
check "heartbeats never reach stdout" "0" "$(grep -c 'waiting since' "$T/hb.out" || true)"
# Wake after heartbeats: stdout is exactly the startup line then the nudge, so
# the nudge survives truncation from either end (head -n 2 and tail -n 1 both see it).
sleep 0.2
echo "idle $(date +%s)" > "$S/coordinator-state"
echo 1 > "$S/coord-hook-rang"
echo "outcome" > "$S/coord-inbox/20991231T000001Z-outcome-9-9.md"
wait_for 3 dead "$hb" || red "heartbeating waiter never rang"
wait "$hb" || true
check "stdout after heartbeats + wake is exactly 2 lines" "2" "$(wc -l < "$T/hb.out" | tr -d ' ')"
case "$(tail -n 1 "$T/hb.out")" in
    "Inbox: 2 item(s) in .swarm/coord-inbox/"*) got=nudge ;; *) got="$(cat "$T/hb.out")" ;;
esac
check "nudge is the last line" "nudge" "$got"
check "nudge survives head-only truncation (head -n 2)" "1" "$(head -n 2 "$T/hb.out" | grep -c '^Inbox: 2 item')"
check "nudge appears exactly once" "1" "$(grep -c '^Inbox:' "$T/hb.out")"
check "status file removed on exit" "gone" "$([ -e "$S/coord-inbox-waiter.status" ] && echo present || echo gone)"
rm -f "$S/coord-inbox/"*.md "$S/coord-inbox-waiter"
env COORD_INBOX_WAITER=1 COORD_INBOX_WAIT_HEARTBEAT_SECS=0 "$WAIT" "$P" > "$T/hb0.out" & hb0=$!; pids+=("$hb0")
sleep 1.5
check "heartbeat 0: startup line only, no status file" "1|gone" \
    "$(wc -l < "$T/hb0.out" | tr -d ' ')|$([ -e "$S/coord-inbox-waiter.status" ] && echo present || echo gone)"
kill "$hb0"; wait "$hb0" 2>/dev/null || true

# ── the Stop hook's arm request ─────────────────────────────────────────────
rm -f "$S/coord-inbox/"*.md "$S/coord-waiter-asked" "$S/coord-inbox-waiter"
hook() { printf '%s' "${2:-{\}}" | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE=1 COORD_INBOX_WAITER="${WV:-1}" "$HOOK" "$1"; }

out="$(WV=0 hook Stop '{"stop_hook_active":false}')"
check "waiter off: Stop stays silent" "idle|" "$(state)|$out"

out="$(hook Stop '{"stop_hook_active":false}')"
case "$(jq -r .reason <<<"$out")" in
    "Arm the inbox waiter: run "*coord-inbox-wait.sh*" with run_in_background"*) got=ask ;; *) got="$out" ;;
esac
check "no waiter running: Stop asks for one" "ask" "$got"
check "asking keeps the turn going" "busy" "$(state)"

out="$(hook Stop '{"stop_hook_active":true}')"
check "an unanswered ask isn't repeated (no loop)" "idle|" "$(state)|$out"

"${W[@]}" > /dev/null & w4=$!; pids+=("$w4")
wait_for 3 test -f "$S/coord-inbox-waiter" || red "waiter never armed for the hook test"
out="$(hook Stop '{"stop_hook_active":false}')"
check "waiter running: Stop stays silent" "idle|" "$(state)|$out"

kill "$w4"; wait "$w4" 2>/dev/null || true
echo 1 > "$S/coord-hook-rang"
echo "outcome" > "$S/coord-inbox/b.md"
out="$(hook Stop '{"stop_hook_active":false}')"
case "$(jq -r .reason <<<"$out")" in
    "Inbox: 1 item(s) in"*"Arm the inbox waiter: run "*) got=both ;; *) got="$out" ;;
esac
check "doorbell and arm request share one block" "both" "$got"

# ── the watcher ─────────────────────────────────────────────────────────────
eval "$(sed -n '/^mtime_epoch() {/,/^}/p; /^coord_inbox_waiter_armed() {/,/^}/p; /^coord_wake_waiter_hold() {/,/^}/p; /^coord_wake_hold_reason() {/,/^}/p' "$WATCH")"
declare -F mtime_epoch >/dev/null || mtime_epoch() { stat -c %Y "$1"; }
COORD_HOOK_STATE=1 COORD_INBOX_WAITER=1
COORD_INBOX_WAITER_FILE="$S/coord-inbox-waiter"
COORD_INBOX_WAITER_STALE_SECS=30 COORD_INBOX_WAITER_GRACE_SECS=120
COORD_WAKE_WAITER_OVERDUE_SINCE="" COORD_WAKE_BUSY_RETRY_SECS=0 WAKE_DEFER_ON_SWARM_BUSY=0
coord_human_present() { [ "${HUMAN:-0}" = 1 ]; }
worker_human_present() { return 1; }
wake_debounced() { return 1; }
EV="$T/watch-events"; : > "$EV"
log_event() { echo "$*" >> "$EV"; }
now="$(date +%s)"

echo "$$ $now" > "$COORD_INBOX_WAITER_FILE"
HUMAN=1
check "armed waiter outranks a present human (it never types)" "waiter_armed" "$(coord_wake_hold_reason)"
check "skip_waiter re-gates without it" "human_present" "$(coord_wake_hold_reason skip_waiter)"
HUMAN=0
coord_wake_waiter_hold "$((now - 10))" && got="hold" || got="type"
check "inside the grace: keep waiting for the waiter" "hold" "$got"
coord_wake_waiter_hold "$((now - 200))" && got="hold" || got="type"
check "past the grace: fall back to typing" "type" "$got"
coord_wake_waiter_hold "$((now - 200))" || true
check "overdue logged once per pending wake" "1" "$(grep -c waiter_overdue "$EV")"

touch -d '1 minute ago' "$COORD_INBOX_WAITER_FILE"
check "stale heartbeat: not armed" "" "$(coord_wake_hold_reason)"
echo "999999999 $now" > "$COORD_INBOX_WAITER_FILE"
check "dead pid: not armed" "" "$(coord_wake_hold_reason)"
echo "$$ $now" > "$COORD_INBOX_WAITER_FILE"; COORD_INBOX_WAITER=0
check "feature off: not armed" "" "$(coord_wake_hold_reason)"
