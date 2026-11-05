#!/usr/bin/env bash
#
# test-scoreboard-wakes.sh — shape test for `swarm-scoreboard.sh --wakes`
# (issue #738): per-day wake counts from events.log, counting the same set
# as docs/quiet-wakes.md, with bookkeeping lines excluded and an explicit
# note that quiet-vs-full replies cannot be derived. No network.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOREBOARD="$SCRIPT_DIR/../scripts/swarm-scoreboard.sh"
[ -x "$SCOREBOARD" ] || red "not executable: $SCOREBOARD"

TEST_DIR=$(mktemp -d -t scoreboard-wakes-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/proj/.swarm"
cat > "$TEST_DIR/proj/.swarm/events.log" <<'LOG'
2026-11-03T10:00:00Z  coord.wake
2026-11-03T10:05:00Z  coord.wake.skip reason=debounce
2026-11-03T11:00:00Z  coord.wake.waiter_rang items=3 urgent=1 batched=2
2026-11-04T09:00:00Z  coord.wake.hook_rang items=2 urgent=0 batched=2
2026-11-04T09:30:00Z  coord.wake.deferred reason=composer_dirty
2026-11-04T12:00:00Z  coord.wake extra=1
2026-11-04T12:01:00Z  worker.started id=x
LOG

JSON=$("$SCOREBOARD" --wakes --json "$TEST_DIR/proj")
printf '%s' "$JSON" | jq -e '
    .total_wakes == 4
    and (.days | length) == 2
    and .days[0].day == "2026-11-03" and .days[0].wakes == 2
    and .days[0].typed == 1 and .days[0].waiter == 1
    and .days[0].items == 3 and .days[0].urgent == 1 and .days[0].batched == 2
    and .days[1].day == "2026-11-04" and .days[1].wakes == 2
    and .days[1].hook == 1 and .days[1].typed == 1
    and (.quiet_vs_full | startswith("not derivable"))
' >/dev/null || { printf '%s\n' "$JSON"; red "--wakes --json counts wrong"; }
green "--wakes --json: 4 wakes over 2 days, skip/deferred/other lines excluded"

OUT=$("$SCOREBOARD" --wakes "$TEST_DIR/proj/.swarm/events.log")
printf '%s' "$OUT" | grep -q "2026-11-04" || red "table missing day row"
printf '%s' "$OUT" | grep -q "TOTAL" || red "table missing TOTAL row"
printf '%s' "$OUT" | grep -q "Quiet vs full replies: not derivable" \
    || red "table missing quiet-vs-full explanation"
green "--wakes table: day rows, TOTAL, quiet-vs-full note"
