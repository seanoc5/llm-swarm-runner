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
DISPATCH_PAUSE_SEEN_FILE="$PROJECT_DIR/.swarm/dispatch-pause-seen"
HOST_LOAD_REFUSED_FILE="$PROJECT_DIR/.swarm/host-load-refused"; HOST_LOADAVG_FILE="$T/loadavg"
SWARM_PARKED_FILE="$PROJECT_DIR/.swarm/parked"
COORD_WAKE_LOCK="$T/wake.lock"
COORD_WAKE_LOCK_TIMEOUT_SECS=5
SESSION_NAME=llm-proj MAX_WORKERS=3 MAX_TMUX_WINDOWS=10
DRY_RUN=0 DEBOUNCE_SECS=0
WATCH_DISPATCH_PAUSE_WAKE=1
WATCH_IDLE_CAPACITY_WAKE_SECS=2700
WATCH_IDLE_CAPACITY_CHECK_SECS=0
WATCH_IDLE_CAPACITY_REPEAT_SECS=21600
IDLE_CAPACITY_SET_FILE="$PROJECT_DIR/.swarm/idle-capacity-set.last"
IDLE_CAPACITY_OUTCOME_FILE="$PROJECT_DIR/.swarm/idle-capacity-outcome.pending"
CI_FAILING_RING_DIR="$PROJECT_DIR/.swarm/ci-failing-ring-pending"
WATCH_STALE_WAIT_CHECK=1; declare -A STALE_WAIT_NOTED=() CI_FAILING_NOTED=()

eval "$(sed -n '/^coord_inbox_write() {/,/^}/p; /^coord_ring_doorbell() {/,/^}/p; /^dispatch_pause_active() {/,/^}/p; /^capacity_free_slots() {/,/^}/p; /^dispatchable_issue_counts() {/,/^}/p; /^dispatch_pause_wake_pass() {/,/^}/p; /^host_load_wake_pass() {/,/^}/p; /^idle_capacity_outcome_pass() {/,/^}/p; /^idle_capacity_wake_pass() {/,/^}/p; /^ci_failing_ring_pass() {/,/^}/p; /^ready_sweep_pass() {/,/^}/p; /^coord_pending_approval_age() {/,/^}/p' "$WATCH")"
for fn in coord_ring_doorbell dispatch_pause_wake_pass host_load_wake_pass idle_capacity_outcome_pass idle_capacity_wake_pass ci_failing_ring_pass ready_sweep_pass coord_pending_approval_age; do
    declare -F "$fn" >/dev/null || red "could not extract $fn from coordinator-watch.sh"
done
LAST_IDLE_CAPACITY_CHECK=0

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
SPLIT=0; RUNBUSY=0
coord_split_active() { [ "$SPLIT" = 1 ]; }
coord_split_run_busy() { [ "$RUNBUSY" = 1 ]; }
wake_debounced() { return 1; }
coord_wake_hold_mark_pending() { echo "held $1" >> "$EV"; }
coord_wake_set_pending() { :; }
coord_wake_clear_pending() { :; }
coord_wake_hold_clear_pending() { :; }
wake_clock_set() { :; }
maybe_auto_compact() { :; }
coord_inbox_nudge_text() { echo "Inbox: nudge"; }
coord_batch_note_ring() { :; }
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
reset() { rm -rf "$CI_FAILING_RING_DIR" "$COORD_INBOX_DIR" "$RANG" "$IDLE_CAPACITY_WAKE_FILE" "$IDLE_CAPACITY_SET_FILE" "$IDLE_CAPACITY_OUTCOME_FILE" "$DISPATCH_PAUSE_SEEN_FILE" "$HOST_LOAD_REFUSED_FILE"; : > "$EV"; LAST_IDLE_CAPACITY_CHECK=0; HOLD=""; BUSY=0; APPROVAL_AGE=""; }

# ── helpers ──────────────────────────────────────────────────────────────────
check "free slots = min(MAX_WORKERS - iss windows, MAX_TMUX_WINDOWS - windows)" "2" "$(capacity_free_slots)"
check "dispatchable counts skip issues with an own worktree" "2 1" "$(dispatchable_issue_counts | cut -d' ' -f1,2)"

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
: > "$DISPATCH_PAUSE_SEEN_FILE"   # left by an earlier watcher process (respawn)
dispatch_pause_wake_pass
check "an expired marker counts as lifted" "1" "$(notes dispatch_pause_lifted)"
rm -f "$DISPATCH_PAUSE_FILE"

# Respawn mid-pause (#688): the first watcher saw the pause and died; the
# second never ticked while it was active, so only the on-disk marker
# remembers. A pause-lift while no marker exists stays silent.
reset
echo "$(( $(date +%s) + 600 )) nightly" > "$DISPATCH_PAUSE_FILE"
dispatch_pause_wake_pass
[ -e "$DISPATCH_PAUSE_SEEN_FILE" ] && got=yes || got=no
check "active pause persists a seen-marker on disk" "yes" "$got"
rm -f "$DISPATCH_PAUSE_FILE"
# "respawn": the new process starts with no in-memory state, only the file.
unset DISPATCH_PAUSE_SEEN
dispatch_pause_wake_pass
check "respawned watcher still fires the lift wake" "1" "$(notes dispatch_pause_lifted)"
[ -e "$DISPATCH_PAUSE_SEEN_FILE" ] && got=yes || got=no
check "seen-marker cleared once the lift is reported" "no" "$got"

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

# ── host-load refusal cleared (#803) ─────────────────────────────────────────
# provision-worker.sh leaves "<epoch> <max> <issue>"; the pass fires once both
# load1 and load5 are at or under max, even though the ready set never changed.
reset
host_load_wake_pass
check "no refusal marker: nothing written" "0" "$(notes host_load_cleared)"
echo "$(date +%s) 48 2244" > "$HOST_LOAD_REFUSED_FILE"
printf '68.47 60.00 50.00 1/1 1\n' > "$HOST_LOADAVG_FILE"
host_load_wake_pass
check "load1 still over max: no note, marker kept" "0:yes" "$(notes host_load_cleared):$([ -e "$HOST_LOAD_REFUSED_FILE" ] && echo yes || echo no)"
printf '40.00 55.00 50.00 1/1 1\n' > "$HOST_LOADAVG_FILE"
host_load_wake_pass
check "load1 under but load5 over max (swinging load): no note" "0" "$(notes host_load_cleared)"
printf '40.00 44.90 50.00 1/1 1\n' > "$HOST_LOADAVG_FILE"
host_load_wake_pass
check "load1 and load5 under max: one host_load_cleared note" "1" "$(notes host_load_cleared)"
grep -q "issue #2244" "$COORD_INBOX_DIR"/*-host_load_cleared-*.md && got=yes || got=no
check "note names the refused issue" "yes" "$got"
check "doorbell rung once" "1" "$(rings)"
grep -q "coord.wake trigger=host_load_cleared slots=2" "$EV" && got=yes || got=no
check "coord.wake logged with trigger=host_load_cleared" "yes" "$got"
check "marker consumed" "no" "$([ -e "$HOST_LOAD_REFUSED_FILE" ] && echo yes || echo no)"
host_load_wake_pass
check "cleared once, not every tick" "1" "$(notes host_load_cleared)"
check "idle-capacity clock reset so no idle_capacity note stacks on it" "yes" "$([ -s "$IDLE_CAPACITY_WAKE_FILE" ] && echo yes || echo no)"

reset
echo "$(date +%s) 48 2244" > "$HOST_LOAD_REFUSED_FILE"
touch "$SWARM_PARKED_FILE"
host_load_wake_pass
check "parked swarm: marker dropped, no note" "0:no" "$(notes host_load_cleared):$([ -e "$HOST_LOAD_REFUSED_FILE" ] && echo yes || echo no)"
rm -f "$SWARM_PARKED_FILE"
reset
echo "$(date +%s) 48 2244" > "$HOST_LOAD_REFUSED_FILE"
echo "$(( $(date +%s) + 600 )) x" > "$DISPATCH_PAUSE_FILE"
host_load_wake_pass
check "dispatch paused: marker dropped, no note" "0:no" "$(notes host_load_cleared):$([ -e "$HOST_LOAD_REFUSED_FILE" ] && echo yes || echo no)"
rm -f "$DISPATCH_PAUSE_FILE"
reset
: > "$HOST_LOAD_REFUSED_FILE"   # mid-write empty read must not lose the retry
host_load_wake_pass
check "empty marker (mid-write): kept for the next tick" "0:yes" "$(notes host_load_cleared):$([ -e "$HOST_LOAD_REFUSED_FILE" ] && echo yes || echo no)"
reset
echo "$(date +%s) 48 2244" > "$HOST_LOAD_REFUSED_FILE"
DRY_RUN=1 host_load_wake_pass
check "dry run: marker not consumed" "yes" "$([ -e "$HOST_LOAD_REFUSED_FILE" ] && echo yes || echo no)"
reset
echo "$(date +%s) 48 2244" > "$HOST_LOAD_REFUSED_FILE"
WINDOWS="coordinator
iss-1
iss-2
iss-3"
host_load_wake_pass
check "no free slot: marker dropped, no note" "0:no" "$(notes host_load_cleared):$([ -e "$HOST_LOAD_REFUSED_FILE" ] && echo yes || echo no)"
WINDOWS="coordinator
util
iss-1"
reset

# ── idle capacity ────────────────────────────────────────────────────────────
coord_pending_approval_age() { [ -n "$APPROVAL_AGE" ] && echo "$APPROVAL_AGE"; }

reset
idle_capacity_wake_pass
check "free slots + dispatchable issues: one idle_capacity note" "1" "$(notes idle_capacity)"
grep -q "2 open issue(s).*(1 of them labelled night-ok" "$COORD_INBOX_DIR"/*-idle_capacity-*.md && got=yes || got=no
check "note counts ready and night-ok issues" "yes" "$got"
check "idle capacity rings the doorbell" "1" "$(rings)"
mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
idle_capacity_wake_pass
check "at most one note per interval" "0" "$(notes idle_capacity)"
echo "$(( $(date +%s) - 2700 ))" > "$IDLE_CAPACITY_WAKE_FILE"
rm -f "$IDLE_CAPACITY_SET_FILE"   # repeat suppression is covered below
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

# night-ok issues are already inside AVAILABLE (#688), so ready=0 must never
# wake. Drive the REAL available-issues.sh through a gh stub that applies its
# -label:/assignee filters: a demo-labelled night-ok issue and a night-ok issue
# assigned to someone else are exactly the ones it drops and the swarm must not
# take, so neither may produce an idle_capacity note.
GHBIN="$T/ghbin"; mkdir -p "$GHBIN"
export GH_ISSUES_JSON="$T/gh-issues.json"
cat > "$GHBIN/gh" <<'GHEOF'
#!/bin/bash
if [ "$1 $2" = "api user" ]; then echo me; exit 0; fi
assignee="" search=""
while [ $# -gt 0 ]; do
    case "$1" in --assignee) assignee="$2"; shift;; --search) search="$2"; shift;; esac
    shift
done
jq --arg a "$assignee" --arg s "$search" '
    ($s | split(" ") | map(select(startswith("-label:")) | ltrimstr("-label:"))) as $stop
    | [.[] | select(([.labels[].name] | any(. as $l | $stop | index($l))) | not)
           | select(if $a != "" then any(.assignees[]?; .login == $a)
                    elif ($s | contains("no:assignee")) then (.assignees | length) == 0
                    else true end)]' "$GH_ISSUES_JSON"
GHEOF
chmod +x "$GHBIN/gh"
SAVED_AVAILABLE_ISSUES="$AVAILABLE_ISSUES"; SAVED_PATH="$PATH"
AVAILABLE_ISSUES="$(cd "$(dirname "$0")/.." && pwd)/scripts/available-issues.sh"
PATH="$GHBIN:$PATH"

reset
echo '[{"number":30,"labels":[{"name":"night-ok"},{"name":"demo"}],"assignees":[]},
      {"number":31,"labels":[{"name":"night-ok"}],"assignees":[{"login":"someone-else"}]}]' > "$GH_ISSUES_JSON"
idle_capacity_wake_pass
check "demo night-ok + other-assignee night-ok only: no wake note" "0" "$(notes idle_capacity)"
grep -q "capacity.idle_check slots=2 ready=0 reason=nothing_dispatchable" "$EV" && got=yes || got=no
check "demo/other-assignee night-ok: logged as nothing_dispatchable" "yes" "$got"

reset
echo '[{"number":30,"labels":[{"name":"night-ok"},{"name":"demo"}],"assignees":[]},
      {"number":32,"labels":[{"name":"night-ok"}],"assignees":[]}]' > "$GH_ISSUES_JSON"
check "an ordinary night-ok issue is counted inside ready" "1 1" "$(dispatchable_issue_counts | cut -d" " -f1,2)"
idle_capacity_wake_pass
check "ordinary night-ok issue: one wake note" "1" "$(notes idle_capacity)"

PATH="$SAVED_PATH"; AVAILABLE_ISSUES="$SAVED_AVAILABLE_ISSUES"

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

# issue #823: a zero tick (0, 0.0, 0.00) would spin the timer loop; each falls back to the default with a log line.
# A later bad knob makes the watcher exit right after validation, so no real watch starts.
for z in 0 0.0 0.00; do
    out="$(WATCH_TIMER_TICK_SECS=$z WATCH_IDLE_CAPACITY_WAKE_SECS=abc "$WATCH" "$PROJECT_DIR" 2>&1)" || true
    case "$out" in *"WATCH_TIMER_TICK_SECS must be a positive number (got: $z); using default 2"*) got=warned ;; *) got="$out" ;; esac
    check "WATCH_TIMER_TICK_SECS=$z falls back to the default with a log line" "warned" "$got"
done

green "all capacity-wake tests passed"

# ── repeat suppression (#718) ────────────────────────────────────────────────
reset
idle_capacity_wake_pass
mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
echo "$(( $(date +%s) - 2700 ))" > "$IDLE_CAPACITY_WAKE_FILE"
idle_capacity_wake_pass
check "unchanged issue set inside the repeat window: no note" "0" "$(notes idle_capacity)"
grep -q "reason=unchanged_set" "$EV" && got=yes || got=no
check "unchanged set: logged" "yes" "$got"
echo '[{"number":10,"labels":[]},{"number":11,"labels":[]},{"number":12,"labels":[]},{"number":13,"labels":[]}]' > "$AVAILABLE_JSON"
idle_capacity_wake_pass
check "a new issue number notes again at the next gated pass" "1" "$(notes idle_capacity)"
mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
echo "$(( $(date +%s) - 2700 ))" > "$IDLE_CAPACITY_WAKE_FILE"
idle_capacity_wake_pass
check "same set again: still suppressed" "0" "$(notes idle_capacity)"
echo '[{"number":10,"labels":[]},{"number":11,"labels":[]},{"number":12,"labels":[{"name":"night-ok"}]},{"number":13,"labels":[]}]' > "$AVAILABLE_JSON"
idle_capacity_wake_pass
check "night-ok added to an already-listed issue notes again (#728)" "1" "$(notes idle_capacity)"
mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
echo "$(( $(date +%s) - 2700 ))" > "$IDLE_CAPACITY_WAKE_FILE"
echo "$(cut -d' ' -f1 "$IDLE_CAPACITY_SET_FILE") $(( $(date +%s) - 21600 ))" > "$IDLE_CAPACITY_SET_FILE"
idle_capacity_wake_pass
check "unchanged set past the repeat window: notes again" "1" "$(notes idle_capacity)"

reset; echo '[{"number":21,"title":"epic: big thing","labels":[]},{"number":12,"title":"Tracking: stuff","labels":[]},{"number":13,"title":"FYI - note","labels":[]},{"number":14,"title":"Fix bug","labels":[]},{"number":15,"title":"Tracking pixel broken","labels":[]},{"number":16,"title":"Tracker UI crash","labels":[]},{"number":17,"title":"FYI update","labels":[]},{"number":18,"title":"Tracking – stuff","labels":[]}]' > "$AVAILABLE_JSON"
check "epic/tracking/FYI titles are not counted (real bugs are)" "4 0" "$(dispatchable_issue_counts | cut -d' ' -f1,2)"

# ── issue #729: ci_failing rings come from the capacity loop, not the sweep ──
reset; CI_FAILING_NOTED=()
FAKE_SWEEP="$T/fake-sweep"; READY_SWEEP="$T/ready-sweep"
printf '#!/bin/sh\ncat "%s"\n' "$FAKE_SWEEP" > "$READY_SWEEP"; chmod +x "$READY_SWEEP"
echo '#31 ci-failing: needs a fix push (sha=deadbeef)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
check "sweep pass writes the ci_failing inbox note" "1" "$(notes ci_failing)"
check "sweep pass itself never rings (real coord_ring_doorbell, llm-start stub)" "0" "$(rings)"
ci_failing_ring_pass
check "capacity-loop pass rings llm-start once for the queued note" "1" "$(rings)"
grep -q "trigger=ci_failing pr=31 sha=deadbeef" "$EV" && got=yes || got=no
check "coord.wake event carries trigger, pr and sha" "yes" "$got"
ci_failing_ring_pass
check "queue is consumed: a second pass does not ring again" "1" "$(rings)"
ready_sweep_pass >/dev/null
ci_failing_ring_pass
check "deduped sweep repeat queues nothing, no second ring" "1" "$(rings)"
printf '%s\n%s\n' '#31 ci-failing: needs a fix push (sha=deadbeef)' '#32 ci-failing: needs a fix push (sha=cafe1234)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
ci_failing_ring_pass
check "two new notes in one sweep: one ring for the batch" "2" "$(rings)"
reset; CI_FAILING_NOTED=()
echo '#31 ci-failing: needs a fix push (sha=deadbeef)' > "$FAKE_SWEEP"
HOLD=pane_busy
ready_sweep_pass >/dev/null; ci_failing_ring_pass
grep -q "held pane_busy" "$EV" && got=yes || got=no
check "held coordinator: ring is deferred and marked pending, not pasted" "yes" "$got"
check "held coordinator: llm-start not called" "0" "$(rings)"

# ── issue #739: a failed CI read between two red sweeps keeps the dedup key ──
reset; CI_FAILING_NOTED=()
echo '#33 ci-failing: needs a fix push (sha=abc12345)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
echo '#33 ci-failing-unconfirmed: live head not verifiably red (sha=abc12345)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
echo '#33 ci-failing: needs a fix push (sha=abc12345)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
check "failed read between two red sweeps: still ONE note for the sha" "1" "$(notes ci_failing)"
: > "$FAKE_SWEEP"; ready_sweep_pass >/dev/null
echo '#33 ci-failing: needs a fix push (sha=abc12345)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
check "PR leaving the list clears the key (re-listed sha notes again)" "2" "$(notes ci_failing)"
echo '#33 ci-failing: needs a fix push (sha=def67890)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
check "new head notes again" "3" "$(notes ci_failing)"
# issue #869: the unconfirmed line is echoed but never logged as a watch.ready_sweep event (it repeats every sweep)
reset; CI_FAILING_NOTED=()
echo '#34 ci-failing-unconfirmed: live head not verifiably red (sha=beef0001)' > "$FAKE_SWEEP"
out="$(ready_sweep_pass)"
case "$out" in *"ci-failing-unconfirmed"*"beef0001"*) got=yes ;; *) got=no ;; esac
check "unconfirmed line is still echoed" "yes" "$got"
grep -q "watch.ready_sweep" "$EV" && got=logged || got=silent
check "unconfirmed line logs no watch.ready_sweep event" "silent" "$got"
echo '#34 ci-failing: needs a fix push (sha=beef0001)' > "$FAKE_SWEEP"
ready_sweep_pass >/dev/null
grep -q 'watch.ready_sweep result="#34 ci-failing:' "$EV" && got=logged || got=silent
check "a real ci-failing line is still logged" "logged" "$got"

# ── issue #869: the real coord_ring_doorbell's exit status (it is stubbed in the retry test below) ──
doorbell_rc() { local rc=0; coord_ring_doorbell ci_failing "pr=1 sha=abc" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
LLM_START_OK="$LLM_START"
printf '#!/bin/sh\nexit 1\n' > "$T/llm-start-fail"; chmod +x "$T/llm-start-fail"
printf '#!/bin/sh\nexit 3\n' > "$T/llm-start-dirty"; chmod +x "$T/llm-start-dirty"
reset; LLM_START="$T/llm-start-fail"
check "failed wake (llm-start exits 1): doorbell returns nonzero" "1" "$(doorbell_rc)"
reset; LLM_START="$T/llm-start-dirty"
check "composer-dirty (llm-start exits 3): doorbell returns 0" "0" "$(doorbell_rc)"
reset; LLM_START="$LLM_START_OK"
check "successful wake: doorbell returns 0" "0" "$(doorbell_rc)"
reset; LLM_START="$T/llm-start-fail"; HOLD=pane_busy
check "held doorbell returns 0 even with a failing llm-start" "0" "$(doorbell_rc)"
reset; wake_debounced() { return 0; }
check "debounced doorbell returns 0" "0" "$(doorbell_rc)"
wake_debounced() { return 1; }
LLM_START="$LLM_START_OK"; reset

# ── issue #739: a failed ring is retried, then given up after the cap ──
reset; CI_FAILING_NOTED=(); rm -rf "$CI_FAILING_RING_DIR"
mkdir -p "$CI_FAILING_RING_DIR"; : > "$CI_FAILING_RING_DIR/41-feedbeef"
coord_ring_doorbell() { return 1; }
ci_failing_ring_pass
[ -e "$CI_FAILING_RING_DIR/41-feedbeef" ] && got=yes || got=no
check "failed ring re-queues the note for the next pass" "yes" "$got"
ci_failing_ring_pass; ci_failing_ring_pass
[ -e "$CI_FAILING_RING_DIR/41-feedbeef" ] && got=yes || got=no
check "after CI_FAILING_RING_MAX_TRIES (3) failures the note is dropped" "no" "$got"
grep -q "coord.wake.giveup trigger=ci_failing note=41-feedbeef" "$EV" && got=yes || got=no
check "giveup is logged" "yes" "$got"

# ── issue #901: wake text and prompts share one rule; idle wakes that start nothing are logged ──
RULE='dispatch AVAILABLE work without asking (`night-ok` first); `night_ok=0` is not "nothing to do"'
printf '#!/bin/sh\necho "$1" >> "%s"\n' "$RANG" > "$LLM_START"; chmod +x "$LLM_START"
WATCH_IDLE_CAPACITY_WAKE_SECS=2700; WATCH_IDLE_CAPACITY_CHECK_SECS=0
echo '[{"number":10,"labels":[{"name":"night-ok"}]},{"number":11,"labels":[{"name":"night-ok"}]},{"number":12,"labels":[]}]' > "$AVAILABLE_JSON"
for f in prompts/coordinator.md prompts/coordinator-work.md; do
    grep -qF -- "$RULE" "$ROOT/$f" && got=yes || got=no
    check "$f states the shared dispatch rule" "yes" "$got"
done
reset
idle_capacity_wake_pass || true
grep -qiF -- "${RULE/#d/D}" "$COORD_INBOX_DIR"/*-idle_capacity-*.md && got=yes || got=no
check "idle_capacity wake text uses the same rule wording" "yes" "$got"
check "wake leaves an outcome snapshot" "yes" "$([ -s "$IDLE_CAPACITY_OUTCOME_FILE" ] && echo yes || echo no)"
idle_capacity_outcome_pass
check "note unread, young: nothing logged yet" "0" "$(grep -c dispatch.idle_none "$EV" || true)"
mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
BUSY=1; idle_capacity_outcome_pass
check "coordinator still mid-turn: nothing logged" "0" "$(grep -c dispatch.idle_none "$EV" || true)"
SPLIT=1; RUNBUSY=1; idle_capacity_outcome_pass
check "split mode, work run still going: nothing logged" "0" "$(grep -c dispatch.idle_none "$EV" || true)"
RUNBUSY=0; SPLIT=0
BUSY=0; idle_capacity_outcome_pass
grep -q "dispatch.idle_none reason=none_started slots=2 ready=2 night_ok=1" "$EV" && got=yes || got=no
check "turn consumed note, no worker started: dispatch.idle_none logged" "yes" "$got"
check "snapshot cleared after logging" "no" "$([ -e "$IDLE_CAPACITY_OUTCOME_FILE" ] && echo yes || echo no)"

reset
echo '[{"number":12,"labels":[]}]' > "$AVAILABLE_JSON"
idle_capacity_wake_pass || true; mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
idle_capacity_outcome_pass
grep -q "dispatch.idle_none reason=none_started slots=[0-9]* ready=[0-9]* night_ok=0" "$EV" && got=yes || got=no
check "night_ok=0 and nothing started: reason=none_started with night_ok=0 field" "yes" "$got"

reset
echo '[{"number":10,"labels":[{"name":"night-ok"}]}]' > "$AVAILABLE_JSON"
idle_capacity_wake_pass || true; mv "$COORD_INBOX_DIR"/*-idle_capacity-*.md "$T/"
SAVED_WINDOWS="$WINDOWS"; WINDOWS="$WINDOWS
iss-10"
idle_capacity_outcome_pass
check "a new iss window appeared: no dispatch.idle_none" "0" "$(grep -c dispatch.idle_none "$EV" || true)"
check "snapshot cleared when a worker started" "no" "$([ -e "$IDLE_CAPACITY_OUTCOME_FILE" ] && echo yes || echo no)"
WINDOWS="$SAVED_WINDOWS"

green "all capacity-wake checks passed"
