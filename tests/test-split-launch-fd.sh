#!/usr/bin/env bash
# test-split-launch-fd.sh — issue #878 fix round: the split-mode launch lock and
# in-flight marker (coordinator-watch.sh). Unit-level: the functions are
# extracted from the watcher and run with stubs, no tmux and no claude.
#
#  1. A bare `exec {fd}>file 2>/dev/null` redirects the shell's stderr for good,
#     so the watcher lost every later ERROR:/>&2 line. After a non-idle tick, and
#     after coord_split_clear_inflight, stderr must still reach the real fd 2.
#  2. coord_split_clear_inflight only drops the marker that is its own pid's.
#  3. A failed marker write logs a WARN event instead of failing silently.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/scripts/coordinator-watch.sh"
T="$(mktemp -d -t split-launch-fd-XXXXXX)"
trap 'rm -rf "$T"' EXIT

extract_fn() { sed -n "/^${1}() {/,/^}/p" "$WATCH"; }
for fn in coord_split_tick coord_split_clear_inflight coord_split_launch_inflight coord_split_start_run; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract $fn from $WATCH — renamed?"
    eval "$body"
done

# issue #457: coord_split_tick consults the pause sentinel under $PROJECT_DIR/.swarm
. "$ROOT/scripts/_watch-pause.sh"; PROJECT_DIR="$T"
export COORD_WORK_RUN_DIR="$T/work-run" COORD_INBOX_DIR="$T/inbox" DRY_RUN=0
COORD_SPLIT_LOCK_FD=""; COORD_SPLIT_RUN_PID=""; COORD_SPLIT_LAUNCH_LOCK_SECS=5
mkdir -p "$COORD_WORK_RUN_DIR" "$COORD_INBOX_DIR"
EVENTS="$T/events"; : > "$EVENTS"
log_event() { echo "$*" >> "$EVENTS"; }

# --- 1. stderr survives a non-idle tick and a clear_inflight -----------------
coord_split_active() { return 0; }
coord_split_decide() { SPLIT_TRIGGER="$1"; SPLIT_SINCE=0; return 0; }   # a run is due
coord_split_start_run() { echo "start-run-ran" >> "$T/started"; return 0; }
ERR="$T/stderr"
(
    exec 2>"$ERR"
    coord_split_tick tick
    echo "STDERR-AFTER-TICK" >&2
    coord_split_clear_inflight 99999
    echo "STDERR-AFTER-CLEAR" >&2
) || red "1: tick returned non-zero"
[ -s "$T/started" ] || red "1: the tick did not reach the launch (test setup is not a non-idle tick)"
grep -q STDERR-AFTER-TICK "$ERR" || red "1: stderr was swallowed after a non-idle tick"
grep -q STDERR-AFTER-CLEAR "$ERR" || red "1: stderr was swallowed after coord_split_clear_inflight"
green "1: stderr still reaches fd 2 after a non-idle tick and after clear_inflight"

# --- 2. clear_inflight leaves another launch's marker alone ------------------
M="$COORD_WORK_RUN_DIR/launch-inflight"
echo "4242 $(date +%s)" > "$M"
coord_split_clear_inflight 1111
[ -f "$M" ] && [ "$(cut -d' ' -f1 "$M")" = 4242 ] || red "2: another pid's marker was removed"
coord_split_clear_inflight 4242
[ ! -e "$M" ] || red "2: the caller's own marker was not removed"
green "2: clear_inflight keeps a marker owned by another pid and removes its own"

# --- 3. a failed marker write logs a warning ---------------------------------
unset -f coord_split_start_run; eval "$(extract_fn coord_split_start_run)"
coord_split_tick() { :; }   # the launch subshell's exit recheck must not chain another launch
coord_inbox_count() { echo 0; }
coord_woke_for() { :; }
wake_clock_set() { :; }
COORD_INBOX_NUDGE_TEMPLATE="n=%N"; COORD_WORK_RUN=/bin/true; PROJECT_DIR="$T"
COORD_WORK_RUN_MAX_RETRIES=3; CIB_URGENT=0; CIB_BATCHED=0
rm -rf "$M"; mkdir "$M"          # a directory at the marker path: the write fails
: > "$EVENTS"
coord_split_start_run tick 0 2>"$T/err3"
wait "$COORD_SPLIT_RUN_PID" 2>/dev/null || true
grep -q 'coord.workrun.warn reason=inflight_marker_write_failed' "$EVENTS" || red "3: no WARN event for a failed marker write (events: $(cat "$EVENTS"))"
green "3: a failed in-flight marker write logs coord.workrun.warn"
echo; green "all split-launch-fd tests passed"
