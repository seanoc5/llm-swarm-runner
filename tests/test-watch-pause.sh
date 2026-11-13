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

echo "== Stop hook and waiter, run for real"
HP="$T/hp"; HS="$HP/.swarm"; mkdir -p "$HS/coord-inbox"
HOOK="$ROOT/scripts/coord-hook.sh"; WAIT="$ROOT/scripts/coord-inbox-wait.sh"
hook_out() { printf '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$HP" COORD_HOOK_STATE=1 COORD_INBOX_WAITER=0 "$HOOK" Stop; }
echo "$(( $(date +%s) - 3600 ))" > "$HS/coord-hook-rang"
echo "stall" > "$HS/coord-inbox/20991231T000000Z-stall-1-1.md"   # urgent kind, newer than the last ring
"$PAUSE" 10m --project "$HP" >/dev/null
out="$(hook_out)"
check "paused: Stop hook does not ring" "" "$out"
"$PAUSE" --resume --project "$HP" >/dev/null
case "$(hook_out | jq -r .reason 2>/dev/null)" in Inbox:*) got=rang ;; *) got=silent ;; esac
check "resumed: the same Stop hook rings" "rang" "$got"

echo "$(( $(date +%s) - 3600 ))" > "$HS/coord-hook-rang"
rm -f "$HS/coordinator-state"   # the hook's ring above marked the coordinator busy; the waiter waits that out
"$PAUSE" 10m --project "$HP" >/dev/null
COORD_INBOX_WAITER_POLL_SECS=0.2 COORD_INBOX_WAITER=1 "$WAIT" "$HP" > "$T/wait.out" 2>&1 & wpid=$!
sleep 1.5
kill -0 "$wpid" 2>/dev/null && got=waiting || got=rang
check "paused: the waiter holds its ring" "waiting" "$got"
"$PAUSE" --resume --project "$HP" >/dev/null
n=40; while [ "$n" -gt 0 ] && kill -0 "$wpid" 2>/dev/null; do sleep 0.1; n=$((n - 1)); done
kill -0 "$wpid" 2>/dev/null && { kill "$wpid" 2>/dev/null || true; got=still-waiting; } || got=rang
check "resumed: the waiter rings with the live count" "rang" "$got"
grep -q '^Inbox: 1 item' "$T/wait.out" && green "waiter nudge carries the true item count" || red "waiter output: $(cat "$T/wait.out")"

echo "== retry pass after a pause, run for real (one nudge, true count, fresh hold)"
# Real coord_wake_hold_retry_pass / hold_reason / mark+clear / count / nudge text,
# only the outside world (llm-start, pane state, transcript checks) is stubbed.
eval "$(for fn in coord_wake_hold_retry_pass coord_wake_hold_reason coord_wake_hold_mark_pending coord_wake_hold_clear_pending \
                  coord_inbox_count coord_inbox_nudge_text coord_typed_batching mtime_epoch; do sed -n "/^${fn}() {/,/^}/p" "$WATCH"; done)"
for fn in coord_wake_hold_retry_pass coord_wake_hold_mark_pending coord_inbox_nudge_text mtime_epoch; do declare -F "$fn" >/dev/null || red "could not extract $fn"; done
coord_hook_rang_since() { return 1; }; coord_wake_already_submitted() { return 1; }; coord_hook_state() { echo idle; }
coord_wake_pane_busy() { [ -e "$T/pane-busy" ]; }
coord_batch_window_open() { return 1; }; wake_debounced() { return 1; }; swarm_busy() { return 1; }
coord_wake_set_pending() { :; }; wake_clock_set() { :; }; coord_batch_note_ring() { :; }; coord_batch_unnote_ring() { :; }
log_event() { echo "$*" >> "$T/wev"; }
COORD_WAKE_HOLD_PENDING_FILE="$SW/coord-wake-busy-pending"; COORD_INBOX_DIR="$SW/coord-inbox-r"; mkdir -p "$COORD_INBOX_DIR"
COORD_INBOX_NUDGE_TEMPLATE="Inbox: %N item(s)"; COORD_WAKE_BUSY_CEILING_SECS=600; COORD_WAKE_BUSY_RETRY_SECS=30
LLM_START="$T/llm-start-r"; RANG="$T/rang-r"; : > "$RANG"
printf '#!/bin/sh\necho "$1" >> "%s"\n' "$RANG" > "$LLM_START"; chmod +x "$LLM_START"
rm -f "$SW/watch-paused" "$SW/watch-paused-ended" "$T/pane-busy"; : > "$T/wev"

"$PAUSE" 30m --project "$P" >/dev/null
for i in 1 2 3; do echo "outcome $i" > "$COORD_INBOX_DIR/20990101T00000${i}Z-outcome-$i.md"; done
coord_wake_hold_mark_pending paused
touch -d '2 hours ago' "$COORD_WAKE_HOLD_PENDING_FILE"   # held far longer than the 600s ceiling
coord_wake_hold_retry_pass >/dev/null
check "paused: retry pass delivers nothing" "0" "$(wc -l < "$RANG" | tr -d ' ')"
[ -e "$COORD_WAKE_HOLD_PENDING_FILE" ] && green "paused: the held wake is kept" || red "hold marker lost during pause"
echo "outcome 4" > "$COORD_INBOX_DIR/20990101T000004Z-outcome-4.md"   # arrives mid-pause
printf 'until=%s\nmode=quiet\nsince=%s\n' "$(( $(date +%s) - 2 ))" "$(( $(date +%s) - 7200 ))" > "$SW/watch-paused"   # pause just expired
: > "$T/pane-busy"
coord_wake_hold_retry_pass >/dev/null
check "just resumed, pane busy: paused time does not trip the ceiling" "0" "$(wc -l < "$RANG" | tr -d ' ')"
grep -q 'defer_ceiling' "$T/wev" && red "ceiling fired on paused time" || green "no defer_ceiling logged"
rm -f "$T/pane-busy"
coord_wake_hold_retry_pass >/dev/null
check "resumed, pane idle: exactly one nudge" "1" "$(wc -l < "$RANG" | tr -d ' ')"
check "the nudge carries the true count (3 queued + 1 arrived mid-pause)" "Inbox: 4 item(s)" "$(cat "$RANG")"
[ ! -e "$COORD_WAKE_HOLD_PENDING_FILE" ] && green "hold marker cleared after delivery" || red "hold marker left behind"
coord_wake_hold_retry_pass >/dev/null
check "a further pass sends nothing more" "1" "$(wc -l < "$RANG" | tr -d ' ')"

# Manual --resume: same fresh-hold behavior.
: > "$RANG"; : > "$T/wev"
"$PAUSE" 30m --project "$P" >/dev/null
coord_wake_hold_mark_pending paused; touch -d '2 hours ago' "$COORD_WAKE_HOLD_PENDING_FILE"
"$PAUSE" --resume --project "$P" >/dev/null
: > "$T/pane-busy"; coord_wake_hold_retry_pass >/dev/null
check "manual resume, pane busy: not force-delivered" "0" "$(wc -l < "$RANG" | tr -d ' ')"
# A wake that was already over the ceiling long after the pause ended is still forced.
echo "$(( $(date +%s) - 700 ))" > "$SW/watch-paused-ended"
coord_wake_hold_retry_pass >/dev/null
check "ceiling still applies once the post-pause hold is old enough" "1" "$(wc -l < "$RANG" | tr -d ' ')"
rm -f "$T/pane-busy"

echo "== watcher hands the terminal back on exit"
body="$(sed -n '/^cleanup_on_exit() {/,/^}/p' "$WATCH")"
case "$body" in *'stty "$WATCHER_STTY_SAVED"'*) green "EXIT trap restores the saved stty" ;; *) red "cleanup_on_exit does not restore stty" ;; esac
grep -q 'WATCHER_STTY_SAVED="$(stty -g' "$WATCH" && green "stty is saved before susp is undefined" || red "stty not saved"
[ "$(grep -n 'stty -g' "$WATCH" | head -1 | cut -d: -f1)" -lt "$(grep -n 'stty susp undef' "$WATCH" | head -1 | cut -d: -f1)" ] && green "saved before changed" || red "order"

echo "all watch-pause checks passed"

echo "== Ctrl-Z guard only touches the tty from the foreground process group"
grep -q 'ps -o tpgid= -p \$\$' "$WATCH" && grep -q 'ps -o pgid= -p \$\$' "$WATCH" \
    && green "foreground check compares tpgid with pgid" || red "no tpgid/pgid comparison"
grep -Eq 'if \[ -t 0 \] && \[ -r /dev/tty \] && watcher_in_tty_foreground; then' "$WATCH" \
    && green "stty/reader block is gated on the foreground check" || red "stty block not gated"
# Behavioural: extract the function and check it is false for a background job and
# never errors when ps has no tty (no controlling terminal => tpgid -1 != pgid).
fn="$(sed -n '/^watcher_in_tty_foreground() {/,/^}/p' "$WATCH")"
[ -n "$fn" ] || red "function not found"
if setsid bash -c "$fn"$'\n''watcher_in_tty_foreground' </dev/null; then red "reported foreground with no controlling tty"; else green "no controlling tty => not foreground"; fi
