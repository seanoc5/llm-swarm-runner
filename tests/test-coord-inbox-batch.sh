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
for k in deliver_stall stranded_brief worktree_vanished sidelined_worker sidelined_wake_failed stall mystery_kind; do
    check "$k is urgent" urgent "$(urg "$(item "$k")")"
done
for k in idle_capacity activity dispatch_pause_lifted stale_wait; do
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
