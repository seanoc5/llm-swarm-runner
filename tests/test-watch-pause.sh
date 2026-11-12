#!/usr/bin/env bash
# test-watch-pause.sh — issue #457: the declared, self-expiring watcher pause.
# watch-pause.sh writes/clears <project>/.swarm/watch-paused; the watcher's
# wake-hold gate, split tick and timer sweeps, the Stop hook and the inbox
# waiter all honor it. No tmux, no gh, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/scripts/coordinator-watch.sh"
PAUSE="$ROOT/scripts/watch-pause.sh"
T="$(mktemp -d -t watch-pause-XXXXXX)"
trap 'rm -rf "$T"' EXIT
P="$T/proj"; mkdir -p "$P/.swarm"
SW="$P/.swarm"; EV="$SW/events.log"

echo "== watch-pause.sh"
out="$("$PAUSE" 30m --reason "deploy window" --project "$P")"
case "$out" in "PAUSED (quiet) until "*"— deploy window") green "pause prints the banner line" ;; *) red "banner: $out" ;; esac
grep -q '^mode=quiet$' "$SW/watch-paused" && green "default mode is quiet" || red "mode"
grep -Eq 'coord\.pause +mode=quiet until=[0-9T:Z-]+ secs=1800 reason="deploy window"' "$EV" && green "coord.pause logged" || red "no coord.pause: $(cat "$EV")"
"$PAUSE" --status --project "$P" | grep -q '^PAUSED (quiet)' && green "--status shows remaining time" || red "status"
"$PAUSE" 2h --full --project "$P" >/dev/null
grep -q '^mode=full$' "$SW/watch-paused" && grep -q "^until=$(( $(grep '^since=' "$SW/watch-paused" | cut -d= -f2) + 7200 ))$" "$SW/watch-paused" \
    && green "a repeat call replaces the pause (full, 2h)" || red "replace"
"$PAUSE" --resume --project "$P" | grep -q resumed && [ ! -e "$SW/watch-paused" ] && green "--resume removes the sentinel" || red "resume"
grep -Eq 'coord\.resume +reason=manual' "$EV" && green "coord.resume logged" || red "no coord.resume"
check "--status when not paused" "not paused" "$("$PAUSE" --status --project "$P")"
"$PAUSE" 0 --project "$P" 2>/dev/null && red "zero duration accepted" || green "zero duration refused"
"$PAUSE" bogus --project "$P" 2>/dev/null && red "bad duration accepted" || green "bad duration refused"

echo "== expiry"
printf 'until=%s\nmode=quiet\nreason=old\n' "$(( $(date +%s) - 5 ))" > "$SW/watch-paused"
: > "$EV"
. "$ROOT/scripts/_watch-pause.sh"
watch_pause_active "$SW" && red "expired pause still active" || green "an expired pause is not active"
[ ! -e "$SW/watch-paused" ] && green "expired sentinel is removed" || red "sentinel left behind"
check "expiry logged once" "1" "$(grep -c 'coord\.resume' "$EV")"
watch_pause_active "$SW" || true
check "expiry not logged twice" "1" "$(grep -c 'coord\.resume' "$EV")"
printf 'garbage\n' > "$SW/watch-paused"
watch_pause_active "$SW" && red "garbage sentinel counts as paused" || green "an unparseable sentinel never pauses"
rm -f "$SW/watch-paused"

echo "== watcher gates"
eval "$(sed -n '/^coord_wake_hold_reason() {/,/^}/p; /^coord_ring_doorbell() {/,/^}/p; /^coord_split_tick() {/,/^}/p' "$WATCH")"
for fn in coord_wake_hold_reason coord_ring_doorbell coord_split_tick; do declare -F "$fn" >/dev/null || red "could not extract $fn"; done
PROJECT_DIR="$P"; COORD_WAKE_LOCK="$T/lock"; COORD_WAKE_LOCK_TIMEOUT_SECS=5; DRY_RUN=0; DEBOUNCE_SECS=0
COORD_WAKE_BUSY_RETRY_SECS=0; WAKE_DEFER_ON_SWARM_BUSY=0
coord_inbox_waiter_armed() { return 1; }; coord_human_present() { return 1; }; worker_human_present() { return 1; }
coord_batch_window_open() { return 1; }; wake_debounced() { return 1; }
coord_split_active() { return 1; }
log_event() { echo "$*" >> "$T/wev"; }
: > "$T/wev"; marks="$T/marks"; : > "$marks"
coord_wake_hold_mark_pending() { echo "$1" >> "$marks"; }
coord_wake_set_pending() { :; }; coord_wake_clear_pending() { :; }; coord_wake_hold_clear_pending() { :; }
wake_clock_set() { :; }; maybe_auto_compact() { :; }; coord_batch_note_ring() { :; }; coord_batch_unnote_ring() { :; }
coord_inbox_nudge_text() { echo "Inbox: 3 item(s)"; }
LLM_START="$T/llm-start"; RANG="$T/rang"; : > "$RANG"
printf '#!/bin/sh\necho "$1" >> "%s"\n' "$RANG" > "$LLM_START"; chmod +x "$LLM_START"

check "no pause: hold reason empty" "" "$(coord_wake_hold_reason)"
coord_ring_doorbell stall >/dev/null || true
check "no pause: doorbell rings" "1" "$(wc -l < "$RANG" | tr -d ' ')"
: > "$RANG"
"$PAUSE" 10m --project "$P" >/dev/null
check "paused: hold reason is paused" "paused" "$(coord_wake_hold_reason)"
coord_ring_doorbell stall >/dev/null || true
check "paused: zero doorbell pastes" "0" "$(wc -l < "$RANG" | tr -d ' ')"
check "paused: wake marked pending for the retry pass" "paused" "$(cat "$marks")"
grep -q 'coord.wake.defer reason=paused' "$T/wev" && green "paused: deferral logged" || red "no defer log"
"$PAUSE" --resume --project "$P" >/dev/null
check "resumed: hold reason empty again" "" "$(coord_wake_hold_reason)"

echo "== retry pass never forces a paused wake"
grep -q 'reason_now" = "paused"' "$WATCH" && green "retry pass has a no-ceiling branch for paused" || red "no paused branch in coord_wake_hold_retry_pass"

echo "== split tick"
coord_split_active() { return 0; }
coord_split_decide() { echo decide >> "$T/split"; return 1; }
COORD_INBOX_DIR="$SW/coord-inbox"; mkdir -p "$COORD_INBOX_DIR"; : > "$T/split"
"$PAUSE" 10m --project "$P" >/dev/null
coord_split_tick x
check "paused: split tick starts nothing" "0" "$(wc -l < "$T/split" | tr -d ' ')"
"$PAUSE" --resume --project "$P" >/dev/null
coord_split_tick x
check "resumed: split tick decides again" "1" "$(wc -l < "$T/split" | tr -d ' ')"

echo "== timer sweeps"
for fn in run_watch_timer_loop run_worker_compact_loop run_auto_compact_poll_loop; do
    body="$(sed -n "/^$fn() {/,/^}/p" "$WATCH")"
    case "$body" in *watch_pause_full*) ok=1 ;; *) ok=0 ;; esac
    [ "$ok" = 1 ] && green "$fn skips ticks during a full pause" || red "$fn ignores a full pause"
done
"$PAUSE" 10m --project "$P" >/dev/null
watch_pause_full "$SW" && red "quiet pause counted as full" || green "a quiet pause leaves the sweeps running"
"$PAUSE" 10m --full --project "$P" >/dev/null
watch_pause_full "$SW" && green "a full pause stops the sweeps" || red "full pause not seen"
"$PAUSE" --resume --project "$P" >/dev/null

echo "== Stop hook and waiter"
grep -q 'watch_pause_active "\$swarm"' "$ROOT/scripts/coord-hook.sh" && green "coord-hook.sh checks the pause before ringing" || red "hook"
grep -q 'watch_pause_active "\$swarm"' "$ROOT/scripts/coord-inbox-wait.sh" && green "coord-inbox-wait.sh checks the pause before ringing" || red "waiter"
echo "all watch-pause checks passed"
