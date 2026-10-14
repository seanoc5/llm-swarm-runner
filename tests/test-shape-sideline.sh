#!/usr/bin/env bash
#
# test-shape-sideline.sh — shape tests for issue #622: sidelining idle
# workers to free their slots, and waking them when a new brief arrives.
#
# Part 1: scripts/sideline-worker.sh against stub tmux/docker (refuses with
#         a queued brief; otherwise saves scrollback, moves the claimed
#         brief aside, writes the marker, kills window + container, logs).
# Part 2: provision-worker.sh --wake against the stub harness from
#         test-shape-host-admission.sh (no issue fetch, no new brief, caps
#         still apply, a refusal keeps brief + marker, success clears the
#         marker and logs worker.start wake=1 + worker.wake).
# Part 3: coordinator-watch.sh's sideline_idle_pass / sideline_wake_pass and
#         the stranded-brief skip, extracted verbatim (sed) as in
#         test-shape-stranded-brief-sweep.sh, with tmux as a shell function
#         and stub SIDELINE_WORKER / PROVISION_WORKER scripts.
# Part 3 sets globals the eval'd watcher functions read.
# shellcheck disable=SC2034
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/.."
WATCH="$REPO/scripts/coordinator-watch.sh"

TEST_DIR=$(mktemp -d -t shape-sideline-XXXXXX)
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/host-state"

PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR/.swarm"
git -C "$PROJECT_DIR" init -q -b master
git -C "$PROJECT_DIR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git clone -q --bare "$PROJECT_DIR" "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" remote add origin "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" fetch -q origin
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-5 "$TEST_DIR/wt-issue-5" master
WT="$TEST_DIR/wt-issue-5"
mkdir -p "$WT"/.swarm/tasks/{inbox,processing,done,status,outbox}
EVENTS="$PROJECT_DIR/.swarm/events.log"

cat > "$TEST_DIR/bin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TEST_DIR/gh.log"
[ "\${1:-}" = issue ] && [ "\${2:-}" = view ] && { echo "FAKE issue body"; exit 0; }
exit 1
STUB
cat > "$TEST_DIR/bin/tmux" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TEST_DIR/tmux.log"
case "\${1:-}" in
    has-session)  exit 0 ;;
    list-windows) cat "$TEST_DIR/windows.txt" 2>/dev/null ;;
    capture-pane) echo "worker scrollback line" ;;
esac
exit 0
STUB
cat > "$TEST_DIR/bin/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TEST_DIR/docker.log"
exit 0
STUB
chmod +x "$TEST_DIR"/bin/*
export PATH="$TEST_DIR/bin:$PATH"
export HOST_STATE_DIR="$TEST_DIR/host-state"
export LLM_SWARM_DIR="$TEST_DIR/sandbox"
mkdir -p "$LLM_SWARM_DIR/scripts"
: > "$LLM_SWARM_DIR/.env.example"
cp "$REPO/sandbox.sh" "$LLM_SWARM_DIR/"
for s in _load-env.sh _window-flags.sh provision-worker.sh sideline-worker.sh lint-brief.sh; do
    cp "$REPO/scripts/$s" "$LLM_SWARM_DIR/scripts/" 2>/dev/null || true
done
SIDELINE="$LLM_SWARM_DIR/scripts/sideline-worker.sh"
PROVISION="$LLM_SWARM_DIR/scripts/provision-worker.sh"
printf 'coordinator\nutil\niss-5\n' > "$TEST_DIR/windows.txt"

# ============================================================================
heading "Part 1: sideline-worker.sh"
# ============================================================================
echo "queued" > "$WT/.swarm/tasks/inbox/q.md"
set +e; ( cd "$PROJECT_DIR" && "$SIDELINE" 5 ) >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 3 ] || red "queued brief should refuse with exit 3, got $rc"
[ ! -e "$WT/.swarm/sidelined" ] || red "refusal must not write the marker"
grep -q kill-window "$TEST_DIR/tmux.log" 2>/dev/null && red "refusal must not kill the window"
rm "$WT/.swarm/tasks/inbox/q.md"
green "a queued brief refuses (exit 3), nothing touched"

echo "claimed task" > "$WT/.swarm/tasks/processing/t1.md"
( cd "$PROJECT_DIR" && "$SIDELINE" 5 --reason stalled ) >/dev/null
[ -f "$WT/.swarm/sidelined" ] || red "marker missing"
grep -q '^reason=stalled$' "$WT/.swarm/sidelined" || red "marker reason: $(cat "$WT/.swarm/sidelined")"
[ -f "$WT/.swarm/tasks/sidelined/t1.md" ] || red "claimed brief not moved to tasks/sidelined/"
[ -z "$(ls "$WT/.swarm/tasks/processing")" ] || red "processing/ should be empty"
capture="$(sed -n 's/^capture=//p' "$WT/.swarm/sidelined")"
grep -q "worker scrollback line" "$capture" || red "scrollback not saved at '$capture'"
grep -q "kill-window -t llm-proj:iss-5" "$TEST_DIR/tmux.log" || red "window not killed: $(cat "$TEST_DIR/tmux.log")"
grep -q "stop -t 10 swarm-llm-proj-iss-5" "$TEST_DIR/docker.log" || red "container not stopped: $(cat "$TEST_DIR/docker.log")"
grep -q "worker.sideline .*issue=5 reason=stalled briefs=1" "$EVENTS" || red "worker.sideline not logged: $(cat "$EVENTS")"
[ -d "$WT/.git" ] || [ -f "$WT/.git" ] || red "worktree must be kept"
green "sidelined: scrollback saved, brief moved aside, marker written, window + container stopped, worktree kept"

# ============================================================================
heading "Part 2: provision-worker.sh --wake"
# ============================================================================
printf 'coordinator\nutil\n' > "$TEST_DIR/windows.txt"   # window is gone now
off=(HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0 PROVISION_SPAWN_CHECK_SECS=0)
run_wake() {  # env assignments...; prints rc
    set +e
    ( cd "$PROJECT_DIR" && env "${off[@]}" "$@" bash "$PROVISION" --wake 5 > "$TEST_DIR/wake.log" 2>&1 )
    local rc=$?
    set -e
    echo "$rc"
}

rc=$(run_wake)
[ "$rc" -eq 2 ] || red "--wake with an empty inbox should exit 2, got $rc: $(cat "$TEST_DIR/wake.log")"
green "--wake with nothing queued exits 2"

echo "answer: go ahead" > "$WT/.swarm/tasks/inbox/20261012-120000-5.md"
: > "$TEST_DIR/gh.log"; : > "$TEST_DIR/tmux.log"
rc=$(run_wake MAX_WORKERS=0)
[ "$rc" -eq 3 ] || red "MAX_WORKERS=0 should refuse with exit 3, got $rc: $(cat "$TEST_DIR/wake.log")"
[ -f "$WT/.swarm/tasks/inbox/20261012-120000-5.md" ] || red "cap refusal must keep the queued brief"
[ -f "$WT/.swarm/sidelined" ] || red "cap refusal must keep the marker"
green "a cap refusal keeps the brief and the marker (retried next tick)"

: > "$TEST_DIR/gh.log"; : > "$TEST_DIR/tmux.log"
rc=$(run_wake)
[ "$rc" -eq 0 ] || red "--wake should succeed, got $rc: $(cat "$TEST_DIR/wake.log")"
grep -q "issue view" "$TEST_DIR/gh.log" && red "--wake must not fetch the issue"
[ "$(find "$WT/.swarm/tasks/inbox" -name '*.md' | wc -l)" -eq 1 ] || red "--wake must not write a second brief: $(ls "$WT/.swarm/tasks/inbox")"
grep -q "new-window -d -t llm-proj -n iss-5" "$TEST_DIR/tmux.log" || red "window not spawned: $(cat "$TEST_DIR/tmux.log")"
[ ! -e "$WT/.swarm/sidelined" ] || red "marker should be cleared once the worker is up"
grep -q "worker.start .*issue=5 task_id=20261012-120000-5 .* wake=1" "$EVENTS" || red "worker.start wake=1 missing: $(tail -3 "$EVENTS")"
grep -q "worker.wake .*issue=5 task_id=20261012-120000-5" "$EVENTS" || red "worker.wake missing"
green "--wake spawns for the queued brief, no issue fetch, no new brief, marker cleared, events logged"

# ============================================================================
heading "Part 2b: provision-worker.sh plain (non-wake) re-provision of a sidelined issue (issue #578 self-review finding)"
# ============================================================================
# A plain re-provision of a sidelined issue is its own supported path (see
# provision-worker.sh's "A live worker is not sidelined, however it got
# here" comment), separate from --wake. Issue #578's no_window salvage
# branch could not tell this apart from a window removed outright, and
# would have swept away a requeue.sh answer sitting in inbox/ — exactly
# the queued, not-yet-claimed brief this whole feature exists to protect.
rm -f "$WT/.swarm/tasks/inbox"/*.md
printf 'reason=manual\n' > "$WT/.swarm/sidelined"
echo "answer: proceed" > "$WT/.swarm/tasks/inbox/20200101-000000-5.md"
: > "$TEST_DIR/gh.log"; : > "$TEST_DIR/tmux.log"
( cd "$PROJECT_DIR" && env "${off[@]}" bash "$PROVISION" 5 > "$TEST_DIR/plain-reprovision.log" 2>&1 ) \
    || red "plain re-provision of a sidelined issue should succeed: $(cat "$TEST_DIR/plain-reprovision.log")"
[ -f "$WT/.swarm/tasks/inbox/20200101-000000-5.md" ] || red "sidelined answer brief must not be salvaged away"
grep -q 'answer: proceed' "$WT/.swarm/tasks/inbox/20200101-000000-5.md" || red "answer brief content changed"
[ ! -d "$PROJECT_DIR/.swarm/salvaged/iss-5" ] || red "nothing should have been salvaged: $(find "$PROJECT_DIR/.swarm/salvaged" -type f)"
[ "$(find "$WT/.swarm/tasks/inbox" -name '*.md' | wc -l)" -eq 2 ] || red "expected the answer brief plus a freshly-fetched issue brief, got: $(ls "$WT/.swarm/tasks/inbox")"
grep -q "issue view" "$TEST_DIR/gh.log" || red "a plain re-provision still fetches the issue (unlike --wake)"
grep -q "new-window -d -t llm-proj -n iss-5" "$TEST_DIR/tmux.log" || red "window not spawned: $(cat "$TEST_DIR/tmux.log")"
[ ! -e "$WT/.swarm/sidelined" ] || red "marker should be cleared once the worker is up"
green "sidelined answer brief survives a plain re-provision untouched; a fresh issue brief queues alongside it, not instead of it"

# ============================================================================
heading "Part 3: watcher passes (sideline_idle_pass / sideline_wake_pass)"
# ============================================================================
rm -rf "$WT/.swarm/tasks/inbox"/* "$WT/.swarm/tasks/sidelined"
# shellcheck source=/dev/null
. "$REPO/scripts/_load-env.sh" "$PROJECT_DIR" >/dev/null 2>&1
WORKSPACE="$TEST_DIR"
EVENTS_LOG="$TEST_DIR/watch-events.log"; : > "$EVENTS_LOG"
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$COORD_INBOX_DIR/.self"
DRY_RUN=0
SESSION_NAME=llm-proj
log_event() { local c="$1"; shift; printf '%s  %-15s %s\n' "$(date -u +%FT%TZ)" "$c" "$*" >> "$EVENTS_LOG"; }
extract_fn() { sed -n "/^${1}() {/,/^}/p" "$WATCH"; }
for fn in coord_inbox_write mtime_epoch is_own_worktree_dir own_worktree_dirs_for_scan \
          has_live_window_draining_brief worker_inbox_brief sideline_reason sidelined_worker_body \
          sideline_idle_pass sideline_wake_pass stranded_brief_queue_lines stranded_brief_body \
          stranded_brief_sweep_pass; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract '$fn' from $WATCH — renamed?"
    eval "$body"
done
declare -A SIDELINE_WAKE_FAIL_LOGGED=() STRANDED_BRIEF_LOGGED=()

# tmux as a function: one live iss-5 window with a settable activity time.
LIVE=1; ACTIVITY=0
tmux() {
    case "$1" in
        list-windows) [ "$LIVE" = 1 ] && echo "iss-5"; echo coordinator ;;
        list-panes)   echo 0 ;;
        display-message) echo "$ACTIVITY" ;;
    esac
}
BUSY=0
worker_pane_busy() { [ "$BUSY" = 1 ]; }

cat > "$TEST_DIR/sideline-stub" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TEST_DIR/sideline-stub.log"
touch "$WT/.swarm/sidelined"
STUB
cat > "$TEST_DIR/provision-stub" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$TEST_DIR/provision-stub.log"
exit "\$(cat "$TEST_DIR/provision-rc")"
STUB
chmod +x "$TEST_DIR/sideline-stub" "$TEST_DIR/provision-stub"
SIDELINE_WORKER="$TEST_DIR/sideline-stub"
PROVISION_WORKER="$TEST_DIR/provision-stub"
WATCH_SIDELINE_SWEEP_SECS=60
inbox_notes() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

WATCH_SIDELINE_SECS=0; ACTIVITY=1
sideline_idle_pass
[ ! -e "$TEST_DIR/sideline-stub.log" ] || red "WATCH_SIDELINE_SECS=0 must never sideline"
green "off by default (WATCH_SIDELINE_SECS=0)"

WATCH_SIDELINE_SECS=3600; ACTIVITY=$(( $(date +%s) - 600 ))
sideline_idle_pass
[ ! -e "$TEST_DIR/sideline-stub.log" ] || red "10 idle minutes is under the 60-minute threshold"
ACTIVITY=$(( $(date +%s) - 4000 )); BUSY=1
sideline_idle_pass
[ ! -e "$TEST_DIR/sideline-stub.log" ] || red "a mid-turn pane must not be sidelined"
BUSY=0; echo q > "$WT/.swarm/tasks/inbox/q.md"
sideline_idle_pass
[ ! -e "$TEST_DIR/sideline-stub.log" ] || red "a queued brief must block sidelining"
rm "$WT/.swarm/tasks/inbox/q.md"
green "not sidelined: under threshold, mid-turn, or brief queued"

sideline_idle_pass
grep -q "^5 $PROJECT_DIR --reason finished$" "$TEST_DIR/sideline-stub.log" || red "expected finished sideline: $(cat "$TEST_DIR/sideline-stub.log" 2>/dev/null)"
grep -q "watch.sideline .*issue=5 reason=finished" "$EVENTS_LOG" || red "watch.sideline not logged"
[ "$(inbox_notes)" -eq 0 ] || red "a finished worker needs no coordinator note"
green "idle 60+ min, nothing claimed -> sidelined as finished, no coordinator note"

rm -f "$WT/.swarm/sidelined" "$TEST_DIR/sideline-stub.log"
echo t > "$WT/.swarm/tasks/processing/t2.md"
printf -- '---\nkind: decision-needed\n---\nwhich way?\n' > "$WT/.swarm/tasks/outbox/m.md"
sideline_idle_pass
grep -q -- "--reason waiting$" "$TEST_DIR/sideline-stub.log" || red "expected waiting: $(cat "$TEST_DIR/sideline-stub.log")"
[ "$(inbox_notes)" -eq 1 ] || red "a mid-task sideline must write one coordinator note"
grep -q "requeue.sh 5" "$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' | head -1)" || red "note should say how to resume"
rm -f "$WT/.swarm/tasks/outbox/m.md" "$WT/.swarm/tasks/processing/t2.md" "$COORD_INBOX_DIR"/*.md
green "mid-task with a decision-needed message -> waiting, coordinator note says how to resume"

# Wake pass: marker present, window gone.
LIVE=0; : > "$EVENTS_LOG"
echo 0 > "$TEST_DIR/provision-rc"
sideline_wake_pass
[ ! -e "$TEST_DIR/provision-stub.log" ] || red "no queued brief -> no wake"
echo "fix the review nit" > "$WT/.swarm/tasks/inbox/20261012-130000-5.md"
backdate() { touch -d "@$(( $(date +%s) - 200 ))" "$1"; }
backdate "$WT/.swarm/tasks/inbox/20261012-130000-5.md"
stranded_brief_sweep_pass
[ "$(inbox_notes)" -eq 0 ] || red "stranded sweep must leave a sidelined worktree to the wake pass"
green "sidelined + queued brief is not reported as stranded"

echo 3 > "$TEST_DIR/provision-rc"
sideline_wake_pass; sideline_wake_pass
[ "$(grep -c -- "--wake 5 $PROJECT_DIR" "$TEST_DIR/provision-stub.log")" -eq 2 ] || red "cap refusal should retry each tick"
[ "$(inbox_notes)" -eq 0 ] || red "cap refusal is not worth a coordinator note"
green "cap refusal (exit 3) retries quietly every tick"

echo 4 > "$TEST_DIR/provision-rc"
sideline_wake_pass; sideline_wake_pass
[ "$(inbox_notes)" -eq 1 ] || red "a real wake failure writes exactly one note, got $(inbox_notes)"
grep -q "watch.wake.error .*issue=5 rc=4" "$EVENTS_LOG" || red "watch.wake.error not logged"
rm -f "$COORD_INBOX_DIR"/*.md
green "other wake failures: one coordinator note per issue, deduped"

echo 0 > "$TEST_DIR/provision-rc"
sideline_wake_pass
grep -q "watch.wake .*issue=5 result=ok" "$EVENTS_LOG" || red "successful wake not logged"
[ -z "${SIDELINE_WAKE_FAIL_LOGGED[5]:-}" ] || red "success should clear the failure dedup"
green "successful wake logged, failure dedup cleared"
