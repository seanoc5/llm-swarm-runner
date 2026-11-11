#!/usr/bin/env bash
#
# test-scoreboard-night.sh — shape test for `swarm-scoreboard.sh --night`
# (issue #900, ADR-0008 D8): per-hour overnight row plus the dropped-wake
# canary. A fixture reproducing the 2026-10-14 night (composer_dirty skips,
# 0 wakes delivered) must show the canary line; a normal night must not.
# TZ is pinned to UTC so local == log hours. No network.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOREBOARD="$SCRIPT_DIR/../scripts/swarm-scoreboard.sh"
[ -x "$SCOREBOARD" ] || red "not executable: $SCOREBOARD"
export TZ=UTC

TEST_DIR=$(mktemp -d -t scoreboard-night-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

# --- bad night: 10-14, wakes dropped, nothing delivered, nothing started
BAD="$TEST_DIR/bad.log"
{
    for m in 00 10 20 30 40 50; do
        echo "2026-10-14T03:${m}:00Z  coord.wake.skip reason=composer_dirty trigger=retry age=60s"
    done
    echo "2026-10-14T04:05:00Z  coord.wake.skip reason=composer_dirty trigger=retry age=60s"
    echo "2026-10-14T04:06:00Z  coord.wake.skip reason=debounce"
    echo "2026-10-14T05:00:00Z  coord.wake.skip reason=inbox_empty trigger=retry age=5s"
    echo "2026-10-14T12:00:00Z  coord.wake"
} > "$BAD"

OUT=$("$SCOREBOARD" --night 2026-10-14 "$BAD")
printf '%s\n' "$OUT" | head -1 | grep -q '^CANARY: .*03:00, 04:00' \
    || { printf '%s\n' "$OUT"; red "bad night: canary line missing or wrong hours (want 03:00 and 04:00, not 05:00)"; }
printf '%s\n' "$OUT" | grep -q 'composer_dirty=6' || red "bad night: composer_dirty=6 missing in 03:00 row"
green "bad night: canary on first line, hours 03:00 and 04:00 only (inbox_empty-only 05:00 is not a canary)"

JSON=$("$SCOREBOARD" --night 2026-10-14 --json "$BAD")
printf '%s' "$JSON" | jq -e '.canary == true and (.hours | length) == 9
    and .hours[3].skipped_total == 6 and .hours[3].delivered == 0 and .hours[3].starts == 0
    and .hours[5].canary == false' >/dev/null || { printf '%s\n' "$JSON"; red "bad night json wrong"; }
green "bad night --json: 9 hourly rows, counts right"

# --- normal night: wakes delivered, workers started, PRs seen, one stray skip alongside a delivery
GOOD="$TEST_DIR/good.log"
cat > "$GOOD" <<'LOG'
2026-11-10T02:00:00Z  coord.wake.waiter_rang items=2 urgent=0 batched=2
2026-11-10T02:10:00Z  coord.wake.skip reason=debounce
2026-11-10T02:15:00Z  worker.start issue=5 task_id=t5 window=w5
2026-11-10T04:00:00Z  coord.wake
2026-11-10T04:30:00Z  watch.pr_poll reason=terminal_pr_detected issue=5 pr=77 state=OPEN
2026-11-10T04:40:00Z  watch.pr_poll reason=terminal_pr_detected issue=5 pr=77 state=OPEN
2026-11-10T06:00:00Z  coord.wake.skip reason=inbox_empty
2026-11-10T10:00:00Z  coord.wake.skip reason=composer_dirty
LOG
OUT=$("$SCOREBOARD" --night 2026-11-10 "$GOOD")
printf '%s\n' "$OUT" | head -1 | grep -q '^Canary: clear' \
    || { printf '%s\n' "$OUT"; red "normal night: canary falsely raised"; }
printf '%s\n' "$OUT" | grep -q 'CANARY' && red "normal night: CANARY text present"
JSON=$("$SCOREBOARD" --night 2026-11-10 --json "$GOOD")
printf '%s' "$JSON" | jq -e '.canary == false and .hours[2].delivered == 1 and .hours[2].starts == 1
    and .hours[4].prs == 1 and .hours[4].delivered == 1' >/dev/null \
    || { printf '%s\n' "$JSON"; red "normal night json wrong (PR dedupe / 09:00+ exclusion?)"; }
green "normal night: no canary, PR counted once, 10:00 skip outside window ignored"
