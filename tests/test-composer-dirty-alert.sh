#!/usr/bin/env bash
# test-composer-dirty-alert.sh — issue #973: a dirty coordinator composer that
# holds wakes past COMPOSER_DIRTY_ALERT_SECS files one needs-you item and one
# coord.wake.blocked state=start event, retries back off, and clearing the
# pending wake emits state=clear and closes the item. No tmux, no gh, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }
command -v jq >/dev/null 2>&1 || { echo "jq not found — skipping"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/scripts/coordinator-watch.sh"
SCRIPT_DIR="$ROOT/scripts"
T="$(mktemp -d -t composer-alert-XXXXXX)"
trap 'rm -rf "$T"' EXIT

PROJECT_DIR="$T/demo-proj"; mkdir -p "$PROJECT_DIR/.swarm"
SESSION_NAME=llm-demo-proj DRY_RUN=0
COORD_WAKE_BLOCKED_FILE="$PROJECT_DIR/.swarm/coord-wake-blocked"
COMPOSER_DIRTY_ALERT_SECS=900 COMPOSER_DIRTY_BACKOFF_SECS=120 COORD_WAKE_RETRY_SECS=15
EV="$T/events"; : > "$EV"
log_event() { echo "$*" >> "$EV"; }
eval "$(sed -n '/^coord_composer_blocked_note_dirty() {/,/^}/p; /^coord_composer_blocked_clear() {/,/^}/p; /^coord_wake_retry_interval() {/,/^}/p' "$WATCH")"
for fn in coord_composer_blocked_note_dirty coord_composer_blocked_clear coord_wake_retry_interval; do
    declare -F "$fn" >/dev/null || red "could not extract $fn"
done
open_count() { "$SCRIPT_DIR/needs-you.sh" render --json --project "$PROJECT_DIR" | jq 'length'; }
backdate() { sed -i "s/^since=.*/since=$(( $(date +%s) - $1 ))/" "$COORD_WAKE_BLOCKED_FILE"; }

coord_composer_blocked_note_dirty >/dev/null
[ -e "$COORD_WAKE_BLOCKED_FILE" ] || red "first dirty retry should stamp the episode"
check "first dirty retry only stamps: no event" "0" "$(grep -c blocked "$EV" || true)"
backdate 600; coord_composer_blocked_note_dirty >/dev/null
check "under the threshold: still no event" "0" "$(grep -c blocked "$EV" || true)"
check "under the threshold: normal retry cadence" "15" "$(coord_wake_retry_interval)"

backdate 1000; coord_composer_blocked_note_dirty >/dev/null
grep -q 'coord.wake.blocked.*state=start.*project=demo-proj' "$EV" \
    && green "past the threshold: state=start event names the project" || red "no state=start event: $(cat "$EV")"
check "past the threshold: one needs-you item open" "1" "$(open_count)"
RENDERED="$("$SCRIPT_DIR/needs-you.sh" render --project "$PROJECT_DIR")"
grep -q "demo-proj coordinator" <<<"$RENDERED" \
    && green "needs-you item names the project" || red "item does not name the project"
check "alerted: retries back off" "120" "$(coord_wake_retry_interval)"

coord_composer_blocked_note_dirty >/dev/null
check "a repeat dirty retry does not re-alert" "1" "$(grep -c 'state=start' "$EV")"
check "a repeat dirty retry does not file a second item" "1" "$(open_count)"

coord_composer_blocked_clear
grep -q 'state=clear.*blocked=10[0-9][0-9]s' "$EV" \
    && green "clear: state=clear event carries the hold time" || red "no state=clear event: $(cat "$EV")"
check "clear: needs-you item closed" "0" "$(open_count)"
[ ! -e "$COORD_WAKE_BLOCKED_FILE" ] && green "clear: episode state removed" || red "episode file left behind"
check "cleared: normal retry cadence again" "15" "$(coord_wake_retry_interval)"

: > "$EV"
coord_composer_blocked_note_dirty >/dev/null; coord_composer_blocked_clear
check "a short episode clears silently" "0" "$(grep -c blocked "$EV" || true)"
coord_composer_blocked_clear
check "clear with no episode is a no-op" "0" "$(grep -c blocked "$EV" || true)"

COMPOSER_DIRTY_ALERT_SECS=0
coord_composer_blocked_note_dirty >/dev/null
[ ! -e "$COORD_WAKE_BLOCKED_FILE" ] && green "COMPOSER_DIRTY_ALERT_SECS=0 disables the alert" || red "disabled alert still stamped"
green "All composer-dirty alert tests passed."
