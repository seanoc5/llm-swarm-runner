#!/usr/bin/env bash
#
# test-shape-stale-wait-note.sh — Non-LLM shape test for issue #635's
# stale-wait handling in coordinator-watch.sh's ready_sweep_pass.
#
# ready-sweep.sh prints "#P stale-wait: waiting on #N, which merged at <ts>"
# for a draft whose **Next:** line still waits on an already-merged PR
# (fand-etl #1477 sat 16h that way). ready_sweep_pass must turn each P:N
# pair into exactly ONE coord-inbox note, stay silent when no stale-wait line
# is reported (an open trigger), and note again only after the pair has
# cleared and come back. The functions are extracted verbatim (sed) from
# coordinator-watch.sh; ready-sweep.sh is replaced by a fake via READY_SWEEP.
# shellcheck disable=SC2034  # globals are read by the extracted watcher functions
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -r "$WATCH" ] || red "coordinator-watch.sh not readable: $WATCH"

TEST_DIR=$(mktemp -d -t shape-stale-wait-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

extract_fn() { sed -n "/^${1}() {/,/^}/p" "$WATCH"; }

PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR"
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$COORD_INBOX_DIR/.self"
DRY_RUN=0
WATCH_STALE_WAIT_CHECK=1
SWEEP_OUT="$TEST_DIR/sweep-out.txt"
READY_SWEEP="$TEST_DIR/fake-ready-sweep.sh"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$SWEEP_OUT" > "$READY_SWEEP"
chmod +x "$READY_SWEEP"
log_event() { :; }
declare -A STALE_WAIT_NOTED=()

# shellcheck source=/dev/null
. <(extract_fn coord_inbox_write; extract_fn ready_sweep_pass)
declare -F ready_sweep_pass >/dev/null || red "ready_sweep_pass not extracted"

notes() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-stale_wait-*.md' 2>/dev/null | wc -l | tr -d ' '; }
MERGED='#21 stale-wait: waiting on #1461, which merged at 2026-10-15T06:52:00Z'

heading "Test 1: a merged-trigger line writes one coord-inbox note"
printf '#11 ci-pending: readied\n%s\n' "$MERGED" > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(notes)" = "1" ] || red "expected 1 note, got $(notes)"
grep -q "PR #21's \*\*Next:\*\* line is still waiting on #1461 to merge, but #1461 merged at 2026-10-15T06:52:00Z" "$COORD_INBOX_DIR"/*-stale_wait-*.md \
    || red "unexpected note text: $(cat "$COORD_INBOX_DIR"/*-stale_wait-*.md)"
green "note names the PR, the trigger and when it merged"

heading "Test 2: the same stale wait on the next sweep is deduped"
ready_sweep_pass >/dev/null
[ "$(notes)" = "1" ] || red "expected still 1 note, got $(notes)"
green "one note per PR:trigger pair"

heading "Test 3: no stale-wait line (trigger still open) writes nothing and clears the dedup"
printf '#22 ci-pending: still draft (exit 4)\n' > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(notes)" = "1" ] || red "expected no new note, got $(notes)"
[ "${#STALE_WAIT_NOTED[@]}" = "0" ] || red "expected dedup cleared, got: ${!STALE_WAIT_NOTED[*]}"
green "silent while the trigger is open"

heading "Test 4: a stale wait that comes back after clearing notes again"
printf '%s\n' "$MERGED" > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(notes)" = "2" ] || red "expected a second note, got $(notes)"
green "re-occurrence isn't permanently suppressed"

green "ALL TESTS PASSED"
