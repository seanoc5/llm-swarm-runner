#!/usr/bin/env bash
# test-coord-inbox-batch.sh — issue #730: quiet wakes. Urgent vs batched inbox
# classification, the waiter and Stop hook holding batched items for
# COORD_INBOX_BATCH_SECS, an urgent item flushing the queue, the "Woke for:"
# suffix, the COORD_QUIET_WAKES=0 switch, and the coordinator prompt's
# quiet-reply / standing-list rules. No tmux, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT="$ROOT/scripts/coord-inbox-wait.sh"
HOOK="$ROOT/scripts/coord-hook.sh"
T="$(mktemp -d -t coord-inbox-batch-XXXXXX)"
P="$T/proj"; S="$P/.swarm"; IN="$S/coord-inbox"; mkdir -p "$IN"
pids=()
cleanup() { local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "${T:?}"; }
trap cleanup EXIT
# shellcheck source=../scripts/_coord-inbox-batch.sh
. "$ROOT/scripts/_coord-inbox-batch.sh"

clear_inbox() { rm -f "${IN:?}"/*.md; }
n=0
item() {   # item <kind> [body] -> path
    n=$((n + 1)); local f="$IN/20991231T0000$(printf %02d "$n")Z-$1-1-$n.md"
    printf '%b\n' "${2:-body}" > "$f"; printf '%s' "$f"
}
msg() {    # msg <kind> [extra text] -> outbox message path
    n=$((n + 1)); printf 'kind: %s\ntask_id: x\n---\n%s\n' "$1" "${2:-hello}" > "$T/msg$n.md"; printf '%s' "$T/msg$n.md"
}
urg() { coord_item_urgency "$1"; }

# ── classification ──────────────────────────────────────────────────────────
for k in deliver_stall stranded_brief worktree_vanished sidelined_worker sidelined_wake_failed stall mystery_kind cminder_answer; do
    check "$k is urgent" urgent "$(urg "$(item "$k")")"
done
for k in idle_capacity activity dispatch_pause_lifted stale_wait cminder_info; do
    check "$k is batched" batched "$(urg "$(item "$k")")"
done
check "ok outcome is batched" batched "$(urg "$(item outcome "wake\n\nTriggering outcome: issue=5 outcome=ok path=/x/done/a.ok.json")")"
check "failed outcome is urgent" urgent "$(urg "$(item outcome "Triggering outcome: issue=5 outcome=err path=/x/done/a.err.json")")"
check "outcome with an unreadable path is urgent" urgent "$(urg "$(item outcome "nothing useful")")"
check "fyi outbox is batched" batched "$(urg "$(item outbox "Triggering message: $(msg fyi)")")"
check "brief-draft outbox is batched" batched "$(urg "$(item outbox "Triggering message: $(msg brief-draft)")")"
check "decision-needed outbox is urgent" urgent "$(urg "$(item outbox "Triggering message: $(msg decision-needed)")")"
check "fyi outbox reporting red CI is urgent" urgent "$(urg "$(item outbox "Triggering message: $(msg fyi 'PR 12: CI is red on main')")")"
check "outbox whose message vanished is urgent" urgent "$(urg "$(item outbox "Triggering message: $T/gone.md")")"
# A handled message is archived to processed/ mid-turn; its fyi stays batched.
m="$(msg fyi)"; mkdir -p "$T/processed"; mv "$m" "$T/processed/"
check "fyi archived to processed/ stays batched" batched "$(urg "$(item outbox "Triggering message: $m")")"
m="$(msg decision-needed)"; mv "$m" "$T/processed/"
check "decision-needed archived to processed/ stays urgent" urgent "$(urg "$(item outbox "Triggering message: $m")")"
check "a file not named like an inbox item is urgent" urgent "$(urg "$IN/old-outcome.md")"
clear_inbox

# ── batching decision (pure) ────────────────────────────────────────────────
now=$(date +%s)
item idle_capacity >/dev/null
coord_inbox_scan "$IN" 0 1
check "scan: one batched, no urgent" "0 1" "$CIB_URGENT $CIB_BATCHED"
coord_should_ring $((now - 10)) "$now" && got=ring || got=hold
check "batched item inside the window is held" hold "$got"
coord_should_ring $((now - 901)) "$now" && got=ring || got=hold
check "batched item past the window rings" ring "$got"
item deliver_stall >/dev/null
coord_inbox_scan "$IN" 0 1
coord_should_ring $((now - 10)) "$now" && got=ring || got=hold
check "an urgent item rings inside the window" ring "$got"
check "woke-for names every queued kind" "1 idle capacity, 1 deliver stall" "$(coord_woke_for "$IN" 0)"
COORD_INBOX_BATCH_SECS=30 coord_batch_due $((now - 10)) "$now" && got=due || got=held
check "COORD_INBOX_BATCH_SECS is honoured" held "$got"
COORD_QUIET_WAKES=0 coord_batch_due $((now - 1)) "$now" && got=due || got=held
check "COORD_QUIET_WAKES=0: no batching" due "$got"
check "COORD_QUIET_WAKES=0: no woke-for suffix" "" "$(COORD_QUIET_WAKES=0 coord_woke_for "$IN" 0)"
clear_inbox

# ── the waiter ──────────────────────────────────────────────────────────────
export COORD_INBOX_WAITER_POLL_SECS=0.2
W=(env COORD_INBOX_WAITER=1 "$WAIT" "$P")
alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! kill -0 "$1" 2>/dev/null; }
wait_for() { local i=$(( $1 * 10 )); shift; while [ "$i" -gt 0 ]; do "$@" && return 0; sleep 0.1; i=$((i - 1)); done; return 1; }

echo "idle $(date +%s)" > "$S/coordinator-state"
echo "$(( $(date +%s) - 10 )) 0" > "$S/coord-hook-rang"     # rang 10s ago
"${W[@]}" > "$T/w1.out" & w1=$!; pids+=("$w1")
wait_for 3 test -f "$S/coord-inbox-waiter" || red "waiter never armed"
sleep 1.1
item idle_capacity >/dev/null
item outcome "Triggering outcome: issue=1 outcome=ok path=/x/a.ok.json" >/dev/null
sleep 1
check "waiter: batched items inside the window don't ring" alive "$(alive "$w1" && echo alive || echo rang)"
item deliver_stall >/dev/null
wait_for 3 dead "$w1" || red "urgent item never rang the waiter"
wait "$w1" || true
check "waiter: urgent item flushes the queue (counts all 3)" "yes" \
    "$(tail -n 1 "$T/w1.out" | grep -q '^Inbox: 3 item(s)' && echo yes || cat "$T/w1.out")"
check "waiter: nudge ends with the woke-for line" "yes" \
    "$(tail -n 1 "$T/w1.out" | grep -q 'Woke for: 1 idle capacity, 1 outcome, 1 deliver stall\.$' && echo yes || tail -n 1 "$T/w1.out")"

# A batched item that landed BEFORE the waiter armed (during a busy turn) still
# rings once the window has elapsed.
clear_inbox; rm -f "$S/coord-inbox-waiter"
item idle_capacity >/dev/null
touch -d '5 minutes ago' "$IN"/*.md
echo "$(( $(date +%s) - 1000 )) 0" > "$S/coord-hook-rang"
echo "idle $(date +%s)" > "$S/coordinator-state"
"${W[@]}" > "$T/w2.out" & w2=$!; pids+=("$w2")
wait_for 3 dead "$w2" || red "stale-but-unrung batched item never rang after the window"
wait "$w2" || true
check "waiter: pre-arming batched item rings after the window" "yes" \
    "$(tail -n 1 "$T/w2.out" | grep -q '^Inbox: 1 item(s)' && echo yes || cat "$T/w2.out")"

# An URGENT item that landed before the waiter armed (turn whose Stop hook was
# skipped) rings at once, not after the extended typed fallback.
clear_inbox; rm -f "$S/coord-inbox-waiter"
item deliver_stall >/dev/null
touch -d '5 minutes ago' "$IN"/*.md
echo "$(( $(date +%s) - 10 * 60 )) 0" > "$S/coord-hook-rang"   # rang before the item landed
echo "idle $(date +%s)" > "$S/coordinator-state"
"${W[@]}" > "$T/w2b.out" & w2b=$!; pids+=("$w2b")
wait_for 3 dead "$w2b" || red "pre-arming urgent item never rang"
wait "$w2b" || true
check "waiter: pre-arming urgent item rings at once" "yes" \
    "$(tail -n 1 "$T/w2b.out" | grep -q '^Inbox: 1 item(s)' && echo yes || cat "$T/w2b.out")"

# COORD_QUIET_WAKES=0 restores wake-per-item and drops the suffix.
clear_inbox; rm -f "$S/coord-inbox-waiter"
echo "$(( $(date +%s) - 10 )) 0" > "$S/coord-hook-rang"
echo "idle $(date +%s)" > "$S/coordinator-state"
env COORD_INBOX_WAITER=1 COORD_QUIET_WAKES=0 "$WAIT" "$P" > "$T/w3.out" & w3=$!; pids+=("$w3")
wait_for 3 test -f "$S/coord-inbox-waiter" || red "waiter never armed"
sleep 1.1
item idle_capacity >/dev/null
wait_for 3 dead "$w3" || red "COORD_QUIET_WAKES=0: batched item should ring at once"
wait "$w3" || true
check "COORD_QUIET_WAKES=0: plain nudge, no suffix" "1" \
    "$(tail -n 1 "$T/w3.out" | grep -c '^Inbox: 1 item(s) in .swarm/coord-inbox/ — read and triage them (see prompts/coordinator.md "Inbox").$')"

# ── the Stop hook ───────────────────────────────────────────────────────────
clear_inbox; rm -f "$S/coord-inbox-waiter"
hook() { printf '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE=1 COORD_INBOX_WAITER=0 "$HOOK" Stop; }
echo "$(( $(date +%s) - 10 )) 0" > "$S/coord-hook-rang"
item idle_capacity >/dev/null
check "hook: batched item inside the window stays silent" "" "$(hook)"
item sidelined_worker >/dev/null
check "hook: urgent item rings with the woke-for suffix" "yes" \
    "$(hook | jq -r .reason | grep -q 'Woke for: 1 idle capacity, 1 sidelined worker\.$' && echo yes || echo no)"

# ── Stop hook: no arm request when background tasks are off (issue #743) ────
clear_inbox; rm -f "$S/coord-waiter-asked" "$S/coord-inbox-waiter"
echo "$(( $(date +%s) - 10 )) 0" > "$S/coord-hook-rang"
item deliver_stall >/dev/null
hook_w() { printf '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE=1 COORD_INBOX_WAITER=1 "$@" "$HOOK" Stop; }
hook_w env CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 | jq -r .reason | grep -q 'Arm the inbox waiter' && got=asked || got=silent
check "hook: no arm request with background tasks disabled" silent "$got"
echo "$(( $(date +%s) - 10 )) 0" > "$S/coord-hook-rang"
hook_w env -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS | jq -r .reason | grep -q 'Arm the inbox waiter' && got=asked || got=silent
check "hook: still asks to arm when background tasks are allowed" asked "$got"

# ── the watcher's typed doorbell with no armed waiter (issue #743) ──────────
WATCH="$ROOT/scripts/coordinator-watch.sh"
clear_inbox; rm -f "$S/coord-waiter-asked" "$S/coord-inbox-waiter"
eval "$(sed -n '/^mtime_epoch() {/,/^}/p; /^coord_inbox_count() {/,/^}/p; /^coord_inbox_nudge_text() {/,/^}/p; /^coord_inbox_nudge_pattern() {/,/^}/p; /^coord_typed_batching() {/,/^}/p; /^coord_last_ring() {/,/^}/p; /^coord_batch_note_ring() {/,/^}/p; /^coord_batch_unnote_ring() {/,/^}/p; /^coord_inbox_waiter_armed() {/,/^}/p; /^coord_wake_hold_reason() {/,/^}/p; /^coord_batch_window_open() {/,/^}/p' "$WATCH")"
COORD_INBOX_DIR="$IN" COORD_HOOK_RANG_FILE="$S/coord-hook-rang" COORD_TYPED_RING_FILE="$S/coord-typed-ring" COORD_WAKE_PENDING_FILE="$S/pending.prompt"
COORD_INBOX_NUDGE_TEMPLATE='Inbox: %N item(s) in .swarm/coord-inbox/ — read and triage them (see prompts/coordinator.md "Inbox").'
COORD_HOOK_STATE=1 COORD_INBOX_WAITER=1 COORD_QUIET_WAKES=1 COORD_INBOX_BATCH_SECS=900
COORD_INBOX_WAITER_FILE="$S/coord-inbox-waiter" COORD_INBOX_WAITER_STALE_SECS=30
COORD_WAKE_BUSY_RETRY_SECS=0 WAKE_DEFER_ON_SWARM_BUSY=0
coord_human_present() { [ "${HUMAN:-0}" = 1 ]; }
worker_human_present() { return 1; }
wake_debounced() { return 1; }
HUMAN=0
now=$(date +%s)
echo "$((now - 10)) 0" > "$COORD_HOOK_RANG_FILE"
item idle_capacity >/dev/null
item outcome "Triggering outcome: issue=5 outcome=ok path=/x/a.ok.json" >/dev/null
check "watcher: all-non-urgent inside the window is held" batch_window "$(coord_wake_hold_reason)"
echo "$((now - 901)) 0" > "$COORD_HOOK_RANG_FILE"
check "watcher: window counted from the last ring; elapsed rings" "" "$(coord_wake_hold_reason)"
echo "$((now - 10)) 0" > "$COORD_HOOK_RANG_FILE"
item deliver_stall >/dev/null
check "watcher: an urgent item rings at once" "" "$(coord_wake_hold_reason)"
HUMAN=1
check "watcher: a present human still holds before batching" human_present "$(coord_wake_hold_reason)"
HUMAN=0
clear_inbox; item idle_capacity >/dev/null
echo "$((now - 10)) 0" > "$COORD_HOOK_RANG_FILE"
: > "$COORD_WAKE_PENDING_FILE"
check "watcher: an already-released (pending) doorbell is not re-held" "" "$(coord_wake_hold_reason)"
rm -f "$COORD_WAKE_PENDING_FILE"
echo 0 > "$COORD_HOOK_RANG_FILE"
check "watcher: no prior ring -> first item rings" "" "$(coord_wake_hold_reason)"
echo "$((now - 10)) 0" > "$COORD_HOOK_RANG_FILE"
COORD_QUIET_WAKES=0 COORD_INBOX_BATCH_SECS=0
check "watcher: COORD_QUIET_WAKES=0 -> no batching" "" "$(coord_wake_hold_reason)"
COORD_QUIET_WAKES=1 COORD_INBOX_BATCH_SECS=900
COORD_INBOX_WAITER=0
check "watcher: COORD_INBOX_WAITER unset -> exactly as before" "" "$(coord_wake_hold_reason)"
COORD_INBOX_WAITER=1

# nudge suffix + ring stamp
clear_inbox; item outcome "Triggering outcome: issue=5 outcome=ok path=/x/a.ok.json" >/dev/null; item idle_capacity >/dev/null
echo "$((now - 2000)) 0" > "$COORD_HOOK_RANG_FILE"
nudge="$(coord_inbox_nudge_text)"
case "$nudge" in
    "Inbox: 2 item(s) in"*" Woke for: 1 outcome, 1 idle capacity.") got=suffixed ;; *) got="[$nudge]" ;;
esac
check "watcher: typed nudge ends with Woke for" suffixed "$got"
nudge_re="^$(coord_inbox_nudge_pattern)\$"
[[ "$nudge" =~ $nudge_re ]] && got=match || got=nomatch
check "watcher: the suffixed nudge still matches its own pattern" match "$got"
# #497: operator text typed after (or inside) a suffixed nudge must not read as the watcher's own paste.
for extra in $'\n\nhelp me fix the build' ' and also help me' $'\nWoke for: 1 x.'; do
    [[ "$nudge$extra" =~ $nudge_re ]] && got=match || got=nomatch
    check "watcher: suffixed nudge + operator text does not match (#497): ${extra//$'\n'/|}" nomatch "$got"
done
COORD_INBOX_WAITER=0
nudge="$(coord_inbox_nudge_text)"
case "$nudge" in *"Woke for"*) got=suffixed ;; *) got=plain ;; esac
check "watcher: no suffix when COORD_INBOX_WAITER is unset" plain "$got"
COORD_INBOX_WAITER=1
before_hook_rang="$(cat "$COORD_HOOK_RANG_FILE")"
coord_batch_note_ring
check "watcher: a typed ring never touches the hook-rang file (a failed paste must not read as delivered)" "$before_hook_rang" "$(cat "$COORD_HOOK_RANG_FILE")"
check "watcher: coord_last_ring_at (hook/waiter side) sees the typed ring" "yes" "$([ "$(coord_last_ring_at "$S")" -ge "$now" ] && echo yes || echo no)"
check "watcher: ringing stamps the last-ring file" "yes" "$([ "$(coord_last_ring)" -ge "$now" ] && echo yes || echo no)"
sleep 1.1; item idle_capacity >/dev/null
check "watcher: a later non-urgent item is batched from that ring" batch_window "$(coord_wake_hold_reason)"

# issue #761: a failed wake gives back its ring stamp, so its items are announced again
rm -f "$COORD_TYPED_RING_FILE"; clear_inbox
item outcome "Triggering outcome: issue=5 outcome=ok path=/x/a.ok.json" >/dev/null
echo "$((now - 10)) 0" > "$COORD_HOOK_RANG_FILE"
coord_batch_note_ring
coord_batch_unnote_ring
check "watcher: a failed wake with no earlier typed ring removes the stamp" "no" "$([ -e "$COORD_TYPED_RING_FILE" ] && echo yes || echo no)"
printf "%s 3\n" "$((now - 500))" > "$COORD_TYPED_RING_FILE"
coord_batch_note_ring
coord_batch_unnote_ring
check "watcher: a failed wake restores the earlier typed ring" "$((now - 500)) 3" "$(cat "$COORD_TYPED_RING_FILE")"
rm -f "$COORD_TYPED_RING_FILE"; echo 0 > "$COORD_HOOK_RANG_FILE"
check "watcher: after a failed wake the item rings again (no prior ring)" "" "$(coord_wake_hold_reason)"
# every wake path that logs coord.wake.error undoes the stamp
errs=$(grep -c 'log_event coord.wake.error "\(issue=\$issue \)\?trigger=.*rc=\$wake_rc' "$WATCH")
undo=$(grep -c '^ *coord_batch_unnote_ring$' "$WATCH")
check "watcher: each wake error branch undoes the ring stamp (retry pass excluded)" "yes" "$([ "$undo" -ge $((errs - 1)) ] && [ "$undo" -ge 6 ] && echo yes || echo no)"
# a batch_window hold must not stamp the debounce clock
held=$(grep -c 'batch_window" ] || wake_clock_set "\$now"' "$WATCH")
bare=$(grep -c '^    wake_clock_set "\$now"$' "$WATCH" || true)
check "watcher: held wakes skip the debounce clock stamp (5 wake paths)" "5 0" "$held $bare"
# the 30s hold-retry tick also runs when only batching is on
grep -q 'COORD_INBOX_BATCH_SECS:-0}" -gt 0 ]; }; then' "$WATCH" && got=yes || got=no
check "watcher: tick fallback honours batch_window" yes "$got"

# ── prompt, env and docs ────────────────────────────────────────────────────
for needle in 'Woke for:' '.swarm/needs-you.md' 'Quiet reply' 'Your list unchanged'; do
    grep -qF "$needle" "$ROOT/prompts/coordinator.md" && got=yes || got=no
    check "coordinator.md carries '$needle'" yes "$got"
done
grep -q '^COORD_QUIET_WAKES=' "$ROOT/.env.example" && grep -q '^COORD_INBOX_BATCH_SECS=900' "$ROOT/.env.example" && got=yes || got=no
check ".env.example documents both settings" yes "$got"
[ -f "$ROOT/docs/quiet-wakes.md" ] && got=yes || got=no
check "docs/quiet-wakes.md exists" yes "$got"
echo "all quiet-wake checks passed"
