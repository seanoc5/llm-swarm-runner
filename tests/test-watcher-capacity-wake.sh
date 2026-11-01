#!/usr/bin/env bash
# shellcheck disable=SC2034  # knobs/paths are read by helpers eval'd from coordinator-watch.sh
# test-watcher-capacity-wake.sh — night-queue wakes in coordinator-watch.sh:
# the nightly dispatch-paused marker lifting writes one inbox note and rings
# the doorbell; the idle-capacity wake fires at most once per
# WATCH_IDLE_CAPACITY_WAKE_SECS, only with free slots and dispatchable
# issues, and never while the coordinator is busy or a fresh approval
# question is open. No tmux, no gh, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/scripts/coordinator-watch.sh"
T="$(mktemp -d -t capacity-wake-XXXXXX)"
trap 'rm -rf "$T"' EXIT

PROJECT_DIR="$T/proj"; mkdir -p "$PROJECT_DIR/.swarm"
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$PROJECT_DIR/.swarm/coord-inbox-self"
HOST_STATE_DIR="$T/host"; mkdir -p "$HOST_STATE_DIR"
DISPATCH_PAUSE_FILE="$HOST_STATE_DIR/dispatch-paused"
IDLE_CAPACITY_WAKE_FILE="$PROJECT_DIR/.swarm/idle-capacity-wake.last"
SWARM_PARKED_FILE="$PROJECT_DIR/.swarm/parked"
COORD_WAKE_LOCK="$T/wake.lock"
COORD_WAKE_LOCK_TIMEOUT_SECS=5
SESSION_NAME=llm-proj MAX_WORKERS=3 MAX_TMUX_WINDOWS=10
DRY_RUN=0 DEBOUNCE_SECS=0
WATCH_DISPATCH_PAUSE_WAKE=1
WATCH_IDLE_CAPACITY_WAKE_SECS=2700
WATCH_IDLE_CAPACITY_CHECK_SECS=0

eval "$(sed -n '/^coord_inbox_write() {/,/^}/p; /^coord_ring_doorbell() {/,/^}/p; /^dispatch_pause_active() {/,/^}/p; /^capacity_free_slots() {/,/^}/p; /^dispatchable_issue_counts() {/,/^}/p; /^dispatch_pause_wake_pass() {/,/^}/p; /^idle_capacity_wake_pass() {/,/^}/p; /^coord_pending_approval_age() {/,/^}/p' "$WATCH")"
for fn in coord_ring_doorbell dispatch_pause_wake_pass idle_capacity_wake_pass coord_pending_approval_age; do
    declare -F "$fn" >/dev/null || red "could not extract $fn from coordinator-watch.sh"
done
DISPATCH_PAUSE_SEEN=0 LAST_IDLE_CAPACITY_CHECK=0

# ── stubs ────────────────────────────────────────────────────────────────────
EV="$T/events"; : > "$EV"
log_event() { echo "$*" >> "$EV"; }
WINDOWS="coordinator
util
iss-1"
tmux() { [ "$1" = list-windows ] || return 1; printf '%s\n' "$WINDOWS"; }
HOLD=""; BUSY=0; APPROVAL_AGE=""
coord_wake_hold_reason() { printf '%s' "$HOLD"; }
coord_wake_pane_busy() { [ "$BUSY" = 1 ]; }
wake_debounced() { return 1; }
coord_wake_hold_mark_pending() { echo "held $1" >> "$EV"; }
coord_wake_set_pending() { :; }
coord_wake_clear_pending() { :; }
coord_wake_hold_clear_pending() { :; }
wake_clock_set() { :; }
maybe_auto_compact() { :; }
coord_inbox_nudge_text() { echo "Inbox: nudge"; }
own_worktree_dirs_for_scan() { printf '%s\n' "$T/wt-issue-11"; }
LLM_START="$T/llm-start"; RANG="$T/rang"
printf '#!/bin/sh\necho "$1" >> "%s"\n' "$RANG" > "$LLM_START"; chmod +x "$LLM_START"
AVAILABLE_ISSUES="$T/available"
cat > "$AVAILABLE_ISSUES" <<'EOF'
#!/bin/sh
cat "$AVAILABLE_JSON"
EOF
chmod +x "$AVAILABLE_ISSUES"
export AVAILABLE_JSON="$T/available.json"
echo '[{"number":10,"labels":[{"name":"night-ok"}]},{"number":11,"labels":[{"name":"night-ok"}]},{"number":12,"labels":[]}]' > "$AVAILABLE_JSON"

notes() { find "$COORD_INBOX_DIR" -maxdepth 1 -name "*-$1-*.md" 2>/dev/null | wc -l | tr -d ' '; }
rings() { [ -f "$RANG" ] && wc -l < "$RANG" | tr -d ' ' || echo 0; }
reset() { rm -rf "$COORD_INBOX_DIR" "$RANG" "$IDLE_CAPACITY_WAKE_FILE"; : > "$EV"; LAST_IDLE_CAPACITY_CHECK=0; HOLD=""; BUSY=0; APPROVAL_AGE=""; }

# ── helpers ──────────────────────────────────────────────────────────────────
check "free slots = min(MAX_WORKERS - iss windows, MAX_TMUX_WINDOWS - windows)" "2" "$(capacity_free_slots)"
check "dispatchable counts skip issues with an own worktree" "2 1" "$(dispatchable_issue_counts)"

# ── dispatch pause lifted ────────────────────────────────────────────────────
reset
dispatch_pause_wake_pass
check "no marker ever seen: nothing written" "0" "$(notes dispatch_pause_lifted)"
echo "$(( $(date +%s) + 600 )) nightly full-test run" > "$DISPATCH_PAUSE_FILE"
dispatch_pause_wake_pass
check "marker present: nothing written yet" "0" "$(notes dispatch_pause_lifted)"
rm -f "$DISPATCH_PAUSE_FILE"
dispatch_pause_wake_pass
check "marker removed: one dispatch_pause_lifted note" "1" "$(notes dispatch_pause_lifted)"
grep -q "2 worker slot(s) free" "$COORD_INBOX_DIR"/*-dispatch_pause_lifted-*.md && got=yes || got=no
check "note names the free slots" "yes" "$got"
check "doorbell rung once" "1" "$(rings)"
grep -q "coord.wake trigger=dispatch_pause_lifted slots=2" "$EV" && got=yes || got=no
check "coord.wake logged with trigger=dispatch_pause_lifted" "yes" "$got"
dispatch_pause_wake_pass
check "lift reported once, not every tick" "1" "$(notes dispatch_pause_lifted)"

reset
echo "$(( $(date +%s) - 5 )) expired" > "$DISPATCH_PAUSE_FILE"
DISPATCH_PAUSE_SEEN=1
dispatch_pause_wake_pass
check "an expired marker counts as lifted" "1" "$(notes dispatch_pause_lifted)"
rm -f "$DISPATCH_PAUSE_FILE"

reset; HOLD=human_present
echo "$(( $(date +%s) + 600 )) x" > "$DISPATCH_PAUSE_FILE"; dispatch_pause_wake_pass; rm -f "$DISPATCH_PAUSE_FILE"
dispatch_pause_wake_pass
check "held doorbell: note still written" "1" "$(notes dispatch_pause_lifted)"
check "held doorbell: not typed" "0" "$(rings)"
grep -q "held human_present" "$EV" && got=yes || got=no
check "held doorbell marked pending for the retry pass" "yes" "$got"

reset; WINDOWS="coordinator
iss-1
iss-2
iss-3"
echo "$(( $(date +%s) + 600 )) x" > "$DISPATCH_PAUSE_FILE"; dispatch_pause_wake_pass; rm -f "$DISPATCH_PAUSE_FILE"
dispatch_pause_wake_pass
check "no free slot: no note" "0" "$(notes dispatch_pause_lifted)"
grep -q "capacity.pause_lifted slots=0 reason=no_free_slots" "$EV" && got=yes || got=no
check "no free slot: logged" "yes" "$got"

reset; WATCH_DISPATCH_PAUSE_WAKE=0; WINDOWS="coordinator
iss-1"
echo "$(( $(date +%s) + 600 )) x" > "$DISPATCH_PAUSE_FILE"; dispatch_pause_wake_pass; rm -f "$DISPATCH_PAUSE_FILE"
dispatch_pause_wake_pass
check "WATCH_DISPATCH_PAUSE_WAKE=0: off" "0" "$(notes dispatch_pause_lifted)"
WATCH_DISPATCH_PAUSE_WAKE=1

# ── idle capacity ────────────────────────────────────────────────────────────
coord_pending_approval_age() { [ -n "$APPROVAL_AGE" ] && echo "$APPROVAL_AGE"; }

reset
idle_capacity_wake_pass
check "free slots + dispatchable issues: one idle_capacity note" "1" "$(notes idle_capacity)"
grep -q "2 open issue(s).*(1 labelled night-ok)" "$COORD_INBOX_DIR"/*-idle_capacity-*.md && got=yes || got=no
check "note counts ready and night-ok issues" "yes" "$got"
check "idle capacity rings the doorbell" "1" "$(rings)"
mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
idle_capacity_wake_pass
check "at most one note per interval" "0" "$(notes idle_capacity)"
echo "$(( $(date +%s) - 2700 ))" > "$IDLE_CAPACITY_WAKE_FILE"
idle_capacity_wake_pass
check "fires again once the interval has passed" "1" "$(notes idle_capacity)"
rm -f "$IDLE_CAPACITY_WAKE_FILE"
idle_capacity_wake_pass
check "an unprocessed idle_capacity note blocks another" "1" "$(notes idle_capacity)"

reset; BUSY=1
idle_capacity_wake_pass
check "coordinator busy: no note" "0" "$(notes idle_capacity)"

reset; APPROVAL_AGE=600
idle_capacity_wake_pass
check "approval question open < interval: no note" "0" "$(notes idle_capacity)"
reset; APPROVAL_AGE=3000
idle_capacity_wake_pass
check "approval question open >= interval: note" "1" "$(notes idle_capacity)"

reset; touch "$SWARM_PARKED_FILE"
idle_capacity_wake_pass
check "parked swarm: no note" "0" "$(notes idle_capacity)"
rm -f "$SWARM_PARKED_FILE"

reset; echo "$(( $(date +%s) + 600 )) x" > "$DISPATCH_PAUSE_FILE"
idle_capacity_wake_pass
check "dispatch paused: no note" "0" "$(notes idle_capacity)"
rm -f "$DISPATCH_PAUSE_FILE"

reset; WINDOWS="coordinator
iss-1
iss-2
iss-3"
idle_capacity_wake_pass
check "no free slot: no note" "0" "$(notes idle_capacity)"
WINDOWS="coordinator
iss-1"

reset; echo '[{"number":11,"labels":[]}]' > "$AVAILABLE_JSON"
idle_capacity_wake_pass
check "nothing dispatchable: no note" "0" "$(notes idle_capacity)"
grep -q "capacity.idle_check slots=2 ready=0 reason=nothing_dispatchable" "$EV" && got=yes || got=no
check "nothing dispatchable: logged" "yes" "$got"

reset; WATCH_IDLE_CAPACITY_WAKE_SECS=0
echo '[{"number":12,"labels":[]}]' > "$AVAILABLE_JSON"
idle_capacity_wake_pass
check "WATCH_IDLE_CAPACITY_WAKE_SECS=0: off" "0" "$(notes idle_capacity)"
WATCH_IDLE_CAPACITY_WAKE_SECS=2700

reset; WATCH_IDLE_CAPACITY_CHECK_SECS=600
idle_capacity_wake_pass; rm -rf "$COORD_INBOX_DIR" "$IDLE_CAPACITY_WAKE_FILE"
idle_capacity_wake_pass
check "gh query rate-limited by WATCH_IDLE_CAPACITY_CHECK_SECS" "0" "$(notes idle_capacity)"
WATCH_IDLE_CAPACITY_CHECK_SECS=0

# ── coord_pending_approval_age (real) ────────────────────────────────────────
eval "$(sed -n '/^coord_pending_approval_age() {/,/^}/p' "$WATCH")"
HAVE_JQ=1 COORD_HUMAN_PASTE_GRACE_SECS=15
transcript_dir_for() { echo "$T"; }
coord_paste_epochs() { :; }
TYPED=1
human_typed_since() { [ "$TYPED" = 1 ]; }
coord_last_assistant_turn() { COORD_LAST_ASSISTANT_EPOCH=$(( $(date +%s) - 100 )); COORD_LAST_ASSISTANT_TEXT="$LAST_TEXT"; }
LAST_TEXT="All done. Nothing needed from you right now"; TYPED=0
check "no approval question: not pending" "none" "$(coord_pending_approval_age || echo none)"
LAST_TEXT="Pending your approval: merge PR #9 (yes/no)"
age="$(coord_pending_approval_age)"
[ "$age" -ge 100 ] && [ "$age" -lt 110 ] && got=yes || got="$age"
check "open approval question: echoes its age" "yes" "$got"
TYPED=1
check "answered approval question: not pending" "none" "$(coord_pending_approval_age || echo none)"

# ── knob validation ──────────────────────────────────────────────────────────
out="$(WATCH_IDLE_CAPACITY_WAKE_SECS=abc "$WATCH" "$PROJECT_DIR" 2>&1)" && rc=0 || rc=$?
case "$out" in *"WATCH_IDLE_CAPACITY_WAKE_SECS must be a non-negative integer"*) got="$rc" ;; *) got="rc=$rc $out" ;; esac
check "non-integer WATCH_IDLE_CAPACITY_WAKE_SECS is refused" "1" "$got"

green "all capacity-wake tests passed"
