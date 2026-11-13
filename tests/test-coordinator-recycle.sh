#!/usr/bin/env bash
#
# test-coordinator-recycle.sh — coordinator-watch.sh's COORD_RECYCLE (issue
# #717, part A2): coord_recycle_pass decides when to /clear the coordinator
# and re-run the startup checklist. Functions are extracted verbatim from the
# real script; tmux, the pane gates and llm-start.sh are stubbed so each case
# only exercises the decision logic.
# shellcheck disable=SC2034  # vars below are read by the eval-extracted functions
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
T=$(mktemp -d -t coord-recycle-XXXXXX)
trap 'rm -rf "$T"' EXIT

for fn in coord_recycle_last_epoch coord_recycle_compact_since coord_recycle_pass log_event; do
    body="$(sed -n "/^${fn}() {/,/^}/p" "$WATCH")"
    [ -n "$body" ] || red "could not extract $fn from $WATCH"
    eval "$body"
done

EVENTS_LOG="$T/events.log"; COORD_RECYCLE_STATE="$T/recycle-at"
AUTO_COMPACT_LOCK="$T/lock"; COORD_WAKE_LOCK="$T/wake.lock"
COORD_WAKE_LOCK_TIMEOUT_SECS=5; COMPACT_SUBMIT_SETTLE_SECS=0
AUTO_COMPACT_BUSY_PATTERN='esc to interrupt'
SESSION_NAME=t PROJECT_DIR="$T" DRY_RUN=0
COORD_RECYCLE=1 COORD_RECYCLE_HOURS=12 COORD_RECYCLE_MIN_GAP_SECS=3600
COORD_RECYCLE_PROMPT="Execute the Initial Startup Checklist."
LLM_START="$T/llm-start-stub"
printf '#!/usr/bin/env bash\necho "$1" >> "%s/prompts"\n' "$T" > "$LLM_START"; chmod +x "$LLM_START"

# Stubs. Gate state comes from variables a case sets.
G_STATE=cli G_BUSY=1 G_HUMAN=1 G_APPROVAL=1 G_DIRTY=0 G_AGE=50000 G_CONFIRM=0
coord_split_active() { return 1; }
coordinator_pane_state() { echo "$G_STATE"; }
coordinator_pane_busy() { return "$G_BUSY"; }       # rc 1 = idle
coord_human_present() { return "$G_HUMAN"; }
coord_pending_approval_age() { return "$G_APPROVAL"; }
compact_composer_clear() { return "$G_DIRTY"; }     # rc 0 = empty
compact_confirm_submitted() { return "$G_CONFIRM"; }
compact_retract_queued() { return 0; }
coord_proc_age_secs() { echo "$G_AGE"; }
tmux() { printf '%s\n' "$*" >> "$T/tmux.log"; }

reset() {
    : > "$EVENTS_LOG"; : > "$T/prompts"; : > "$T/tmux.log"; rm -f "$COORD_RECYCLE_STATE"
    G_STATE=cli G_BUSY=1 G_HUMAN=1 G_APPROVAL=1 G_DIRTY=0 G_AGE=50000 G_CONFIRM=0
}
expect() { # desc, grep-pattern-in-events (or '-' for none), expected prompt count
    local desc="$1" pat="$2" n="$3" got
    got=$(grep -c . "$T/prompts" || true)
    [ "$got" = "$n" ] || red "$desc: expected $n checklist prompt(s), got $got ($(cat "$EVENTS_LOG"))"
    if [ "$pat" != "-" ]; then grep -qE "$pat" "$EVENTS_LOG" || red "$desc: events.log lacks /$pat/: $(cat "$EVENTS_LOG")"; fi
    green "$desc"
}

reset; COORD_RECYCLE=0; coord_recycle_pass; COORD_RECYCLE=1
expect "disabled: no action" - 0

reset; G_AGE=3600; coord_recycle_pass
expect "young session, no compaction: nothing" - 0

reset; coord_recycle_pass
expect "old session recycles: /clear then the checklist" 'coord\.recycle  .*trigger=age' 1
grep -q 'send-keys -t t:coordinator.0 Enter' "$T/tmux.log" || red "Enter not sent"
[ -s "$COORD_RECYCLE_STATE" ] || red "state file not written"

coord_recycle_pass
expect "second pass inside the min gap: no second recycle" - 1

reset; G_AGE=60; printf '%s  coord.compact.done  waited=40s trigger=poll\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$EVENTS_LOG"
echo $(( $(date +%s) - 100 )) > "$COORD_RECYCLE_STATE"; COORD_RECYCLE_MIN_GAP_SECS=10
coord_recycle_pass
expect "compaction newer than last recycle recycles" 'coord\.recycle  .*trigger=after_compact' 1
COORD_RECYCLE_MIN_GAP_SECS=3600

reset; G_AGE=60; printf '%s  coord.compact.done  waited=40s trigger=poll\n' "2020-01-01T00:00:00Z" > "$EVENTS_LOG"
echo $(( $(date +%s) - 100000 )) > "$COORD_RECYCLE_STATE"
coord_recycle_pass
expect "compaction older than last recycle: nothing" - 0

reset; G_AGE=60; printf '%s  coord.compact.done  waited=40s trigger=poll\n' "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" > "$EVENTS_LOG"
coord_recycle_pass
expect "no marker, compaction from before this process started: nothing" - 0

reset; G_BUSY=0; coord_recycle_pass;      expect "busy pane waits"          'skip .*reason=pane_busy' 0
reset; G_HUMAN=0; coord_recycle_pass;     expect "operator present waits"   'skip .*reason=human_present' 0
reset; G_APPROVAL=0; coord_recycle_pass;  expect "open approval waits"      'skip .*reason=pending_approval' 0
reset; G_DIRTY=1; coord_recycle_pass;     expect "draft in composer waits"  'skip .*reason=composer_dirty' 0
reset; G_STATE=shell; coord_recycle_pass; expect "no live CLI waits"        'skip .*reason=not_cli' 0
reset; G_CONFIRM=1; coord_recycle_pass
expect "/clear not taken: checklist not sent, no state written" 'skip .*reason=clear_not_submitted' 0
[ ! -e "$COORD_RECYCLE_STATE" ] || red "state written despite failed /clear"

reset; DRY_RUN=1; coord_recycle_pass; DRY_RUN=0
[ ! -s "$T/tmux.log" ] || red "dry run touched tmux"
expect "dry run: no keystrokes, no prompt" - 0

grep -q '^run_coord_recycle_loop() {' "$WATCH" || red "loop function missing"
green "all coordinator-recycle tests passed"
