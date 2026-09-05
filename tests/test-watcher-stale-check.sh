#!/usr/bin/env bash
#
# test-watcher-stale-check.sh — Tests for coordinator-watch.sh's stale-daemon
# self-check (issue #296).
#
# Background: a watcher pane is a long-lived bash process. Bash parses every
# function body into memory once, at startup — a watcher launched days ago
# keeps running whatever code existed at that moment forever, even after a
# fix lands on disk and is pulled into the checkout. This is exactly how
# issues #265 and #274 both got silently un-fixed in production: a watcher
# launched 2026-08-08 misfired a spurious /compact at 16% context into a
# live worker pane on 2026-08-16, despite both issues having been closed
# days earlier. This issue adds two things:
#   1. watcher_is_stale/watcher_check_staleness/run_stale_check_loop — a
#      periodic self-check that compares this script's own on-disk mtime
#      against what it was at launch, and shuts the whole daemon down on a
#      mismatch (there's no way to make an already-running process start
#      executing a function body it already parsed differently).
#   2. `coordinator-watch.sh --check-stale [project-dir]` — a cheap, one-shot
#      way to answer "is my watcher stale?" from a second terminal, reading
#      the state file a live watcher writes at startup.
#
# Strategy: (1) is tested by extracting the real function bodies (sed, not a
# hand-retyped copy) and exercising the pure watcher_is_stale predicate
# in-process, plus watcher_check_staleness's logging/exit behavior in a
# genuinely separate `bash -c` subprocess (so its shutdown signals can't
# reach — and kill — this test script itself: bash's $$ does not change
# across `&`/subshell forks, only a real new process gets its own). (2) is
# tested by invoking the real coordinator-watch.sh binary directly against a
# hand-written state file — no live daemon, tmux, or inotify needed.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"

TEST_DIR=$(mktemp -d -t watcher-stale-check-XXXXXX)
cleanup() {
    # Test 7 backgrounds a real coordinator-watch.sh; if an earlier check
    # in this file fails and exits before that test's own kill runs, this
    # is the backstop that keeps it from leaking past the test run.
    [ -n "${LIVE_WATCH_PID:-}" ] && kill "$LIVE_WATCH_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        printf '\033[33mKEEP=1: leaving %s for inspection\033[0m\n' "$TEST_DIR"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

PASS=0
check() {
    local desc="$1" expect="$2" got="$3"
    if [ "$expect" = "$got" ]; then
        green "$desc"
        PASS=$((PASS + 1))
    else
        red "$desc (expected [$expect] got [$got])"
    fi
}

extract_fn() {
    local fn="$1"
    sed -n "/^${fn}() {/,/^}/p" "$WATCH"
}

heading "Test 1: watcher_is_stale — pure predicate (in-process)"
for fn in mtime_epoch watcher_is_stale log_event; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done

FAKE_SCRIPT="$TEST_DIR/fake-watcher.sh"
echo '#!/usr/bin/env bash' > "$FAKE_SCRIPT"
WATCHER_SELF_PATH="$FAKE_SCRIPT"
WATCHER_LAUNCH_MTIME="$(mtime_epoch "$FAKE_SCRIPT")"

rc=0; watcher_is_stale || rc=$?
check "unchanged mtime -> watcher_is_stale returns 1 (fresh)" "1" "$rc"

sleep 1
touch "$FAKE_SCRIPT"
rc=0; watcher_is_stale || rc=$?
check "bumped mtime -> watcher_is_stale returns 0 (stale)" "0" "$rc"

# Restore, then confirm the predicate goes back to fresh (not latched).
touch -r "$FAKE_SCRIPT" "$FAKE_SCRIPT" 2>/dev/null || true
WATCHER_LAUNCH_MTIME="$(mtime_epoch "$FAKE_SCRIPT")"
rc=0; watcher_is_stale || rc=$?
check "launch mtime re-captured to match current -> fresh again" "1" "$rc"

heading "Test 2: watcher_check_staleness — logs, attempts shutdown, exits cleanly (separate subprocess)"
# Run in a genuinely separate \`bash\` process (not eval'd in-process here)
# so a bug that let a real, unstubbed \`kill\` reach this test's own PID
# can't take the test harness down with it. The real implementation's
# self-directed \`kill -TERM "\$\$"\` is exactly right in production —
# watcher_check_staleness runs inside run_stale_check_loop's own
# backgrounded process, and bash's \$\$ does NOT change across a \`&\` fork
# (only \$BASHPID does), so \$\$ there still names the TOP-LEVEL watcher
# process, not the background loop itself. Reproducing that fork
# relationship faithfully in a standalone test is unnecessary risk for
# little signal, so \`kill\` is stubbed here to record its argv instead of
# actually signaling anything — this test verifies the DETECTION, LOGGING,
# and SHUTDOWN-ATTEMPT logic, which is where the actual risk of a bug
# lives; the signal-delivery mechanics are three ordinary \`kill\` calls
# with no logic of their own to get wrong.
#
# Uses the REAL cleanup_on_exit (extracted, not stubbed) under the SAME
# `set -euo pipefail` the real script runs under — self-review caught that
# an earlier version of this test stubbed cleanup_on_exit to a no-op and
# ran without `-e`, which hid a real bug: cleanup_on_exit's last line
# (`[ -n "${seen_file:-}" ] && rm -f -- "$seen_file"`, no trailing `|| true`
# unlike every other line in that function) fails its `set -e` check
# whenever seen_file is empty — true for run_stale_check_loop's process,
# which never sets it — silently aborting THIS caller before either
# `kill -TERM` line ever ran, and before this function's own `exit 0`.
# That would have shipped the self-check as a no-op: it logs
# watch.stale_daemon and prints the shutdown banner, then the daemon just
# keeps running the stale code forever. Fixed at the source (that line now
# has `|| true` like its siblings); this test's realistic harness is what
# catches a regression if it comes back.
EVENTS_LOG2="$TEST_DIR/events2.log"
KILL_LOG2="$TEST_DIR/kill2.log"
FAKE_SCRIPT2="$TEST_DIR/fake-watcher2.sh"
echo '#!/usr/bin/env bash' > "$FAKE_SCRIPT2"
sleep 1
touch "$FAKE_SCRIPT2"   # bump mtime so it's stale relative to a launch mtime captured just before this

STALE_FNS="$(extract_fn mtime_epoch; extract_fn watcher_is_stale; extract_fn watcher_check_staleness; extract_fn cleanup_on_exit; extract_fn log_event)"

cat > "$TEST_DIR/run-check.sh" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
EVENTS_LOG="$EVENTS_LOG2"
WATCHER_STALE_CHECK=1
WATCHER_SELF_PATH="$FAKE_SCRIPT2"
WATCHER_LAUNCH_MTIME=0
WATCHER_STARTED_AT="2026-08-08T10:00:00Z"
# Realistic empty state, same as run_stale_check_loop's own process would
# see: no other timer loops/pane-echo/seen_file in this minimal harness.
WATCH_TIMER_PID=""
WORKER_COMPACT_TIMER_PID=""
AUTO_COMPACT_POLL_TIMER_PID=""
STALE_CHECK_PID=""
WATCHER_ECHO_PID=""
seen_file=""
kill() { printf 'kill %s\n' "\$*" >> "$KILL_LOG2"; return 0; }
$STALE_FNS
watcher_check_staleness
echo "UNREACHABLE — watcher_check_staleness should have exited first"
exit 99
SCRIPT
chmod +x "$TEST_DIR/run-check.sh"

set +e
bash "$TEST_DIR/run-check.sh" >"$TEST_DIR/run-check.out" 2>&1
RUN_RC=$?
set -e

check "watcher_check_staleness exits 0 (clean shutdown, not a crash)" "0" "$RUN_RC"
if grep -q 'UNREACHABLE' "$TEST_DIR/run-check.out"; then got=reached; else got=not_reached; fi
check "exits before falling through to the caller's next line" "not_reached" "$got"
if grep -q 'watch.stale_daemon' "$EVENTS_LOG2"; then got=logged; else got=missing; fi
check "watch.stale_daemon logged to EVENTS_LOG" "logged" "$got"
if grep -qF "script=$FAKE_SCRIPT2" "$EVENTS_LOG2" && grep -q 'launch_mtime=0' "$EVENTS_LOG2"; then got=present; else got=missing; fi
check "watch.stale_daemon records script path + launch_mtime" "present" "$got"
if grep -qi 'STALE DAEMON' "$TEST_DIR/run-check.out"; then got=present; else got=missing; fi
check "human-readable STALE DAEMON banner printed to stdout (visible in the pane)" "present" "$got"
if grep -qE '^kill -TERM -[0-9]+' "$KILL_LOG2" 2>/dev/null; then got=attempted; else got=missing; fi
check "attempts a process-group TERM (reaches a blocked run_inotify/run_poll too)" "attempted" "$got"
if [ "$(grep -c '^kill -TERM' "$KILL_LOG2" 2>/dev/null || echo 0)" -ge 2 ]; then got=both; else got=missing; fi
check "attempts both the process-group signal and the direct-PID backstop" "both" "$got"

heading "Test 3: watcher_check_staleness — no-op on a fresh script"
: > "$EVENTS_LOG2"
FAKE_SCRIPT3="$TEST_DIR/fake-watcher3.sh"
echo '#!/usr/bin/env bash' > "$FAKE_SCRIPT3"
FRESH_MTIME="$(stat -c %Y "$FAKE_SCRIPT3" 2>/dev/null || stat -f %m "$FAKE_SCRIPT3" 2>/dev/null)"
cat > "$TEST_DIR/run-check-fresh.sh" <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail
EVENTS_LOG="$EVENTS_LOG2"
WATCHER_STALE_CHECK=1
WATCHER_SELF_PATH="$FAKE_SCRIPT3"
WATCHER_LAUNCH_MTIME=$FRESH_MTIME
WATCHER_STARTED_AT="2026-08-08T10:00:00Z"
cleanup_on_exit() { :; }
$STALE_FNS
watcher_check_staleness
echo "REACHED — fresh script, no shutdown expected"
exit 0
SCRIPT
chmod +x "$TEST_DIR/run-check-fresh.sh"
OUT3="$(bash "$TEST_DIR/run-check-fresh.sh")"
check "fresh script -> watcher_check_staleness returns without shutting down" "REACHED — fresh script, no shutdown expected" "$OUT3"
if grep -q 'watch.stale_daemon' "$EVENTS_LOG2"; then got=logged; else got=missing; fi
check "fresh script -> nothing logged" "missing" "$got"

heading "Test 4: watcher_check_staleness — no-op when WATCHER_STALE_CHECK=0"
: > "$EVENTS_LOG2"
cat > "$TEST_DIR/run-check-disabled.sh" <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail
EVENTS_LOG="$EVENTS_LOG2"
WATCHER_STALE_CHECK=0
WATCHER_SELF_PATH="$FAKE_SCRIPT2"
WATCHER_LAUNCH_MTIME=0
WATCHER_STARTED_AT="2026-08-08T10:00:00Z"
cleanup_on_exit() { :; }
$STALE_FNS
watcher_check_staleness
echo "REACHED — disabled, no shutdown expected"
exit 0
SCRIPT
chmod +x "$TEST_DIR/run-check-disabled.sh"
OUT4="$(bash "$TEST_DIR/run-check-disabled.sh")"
check "WATCHER_STALE_CHECK=0 -> disabled even though the script IS stale" "REACHED — disabled, no shutdown expected" "$OUT4"

heading "Test 5: --check-stale CLI — FRESH/STALE against a hand-written state file (issue #296)"
# pid=$$ — THIS test script's own pid — so it's guaranteed alive for the
# whole FRESH/STALE comparison below without needing a real watcher
# process; the liveness check itself gets its own dedicated Test 5b.
PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR/.swarm"
CHECK_SCRIPT="$TEST_DIR/checked-script.sh"
echo '#!/usr/bin/env bash' > "$CHECK_SCRIPT"
LAUNCH_MTIME="$(stat -c %Y "$CHECK_SCRIPT" 2>/dev/null || stat -f %m "$CHECK_SCRIPT" 2>/dev/null)"
cat > "$PROJECT_DIR/.swarm/coordinator-watch.state" <<EOF
pid=$$
started_at=2026-08-08T10:00:00Z
script_path=$CHECK_SCRIPT
script_mtime_at_launch=$LAUNCH_MTIME
EOF

set +e
OUT="$("$WATCH" --check-stale "$PROJECT_DIR" 2>&1)"; RC=$?
set -e
check "FRESH state -> exit 0" "0" "$RC"
if echo "$OUT" | grep -q 'status: *FRESH'; then got=fresh; else got=notfresh; fi
check "FRESH state -> reports FRESH" "fresh" "$got"

sleep 1
touch "$CHECK_SCRIPT"
set +e
OUT="$("$WATCH" --check-stale "$PROJECT_DIR" 2>&1)"; RC=$?
set -e
check "on-disk script changed -> exit 1" "1" "$RC"
if echo "$OUT" | grep -q 'status: *STALE'; then got=stale; else got=notstale; fi
check "changed script -> reports STALE" "stale" "$got"

heading "Test 5b: --check-stale CLI — a dead recorded pid reports NOT RUNNING, never FRESH (issue #296 self-review finding)"
# Self-review finding: the state file is written once at startup and never
# removed, so it outlives the watcher itself (clean ONCE=1 exit, a crash, or
# WATCHER_STALE_CHECK's own shutdown all leave it behind unchanged) — without
# a liveness check, a dead watcher whose script hasn't since changed would
# report FRESH/exit 0, telling the operator "nothing to do" when there is no
# watcher running at all. `sleep 0.2 &` then `wait` for it guarantees a pid
# that WAS valid but is now genuinely dead, not just an arbitrary guess.
sleep 0.2 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
cat > "$PROJECT_DIR/.swarm/coordinator-watch.state" <<EOF
pid=$DEAD_PID
started_at=2026-08-08T10:00:00Z
script_path=$CHECK_SCRIPT
script_mtime_at_launch=$LAUNCH_MTIME
EOF
set +e
OUT="$("$WATCH" --check-stale "$PROJECT_DIR" 2>&1)"; RC=$?
set -e
check "dead recorded pid, unchanged script -> exit 3, NOT the FRESH exit 0 this would have wrongly reported before" "3" "$RC"
if echo "$OUT" | grep -q 'status: *NOT RUNNING'; then got=present; else got=missing; fi
check "dead recorded pid -> reports NOT RUNNING" "present" "$got"

heading "Test 6: --check-stale CLI — missing state file (no watcher has run here)"
NO_WATCHER_DIR="$TEST_DIR/no-watcher-project"
mkdir -p "$NO_WATCHER_DIR"
set +e
OUT="$("$WATCH" --check-stale "$NO_WATCHER_DIR" 2>&1)"; RC=$?
set -e
check "no state file -> exit 2" "2" "$RC"
if echo "$OUT" | grep -qi 'No watcher state file'; then got=present; else got=missing; fi
check "no state file -> explanatory message printed" "present" "$got"

heading "Test 6b: --check-stale CLI — a partial/corrupted state file still produces a coherent verdict (issue #296 self-review finding)"
# Self-review finding: the state-file WRITE already tolerates a partial
# write (\`... || true\` at the write site) — a process killed mid-write, or
# a full disk, can leave a truncated file missing a key. state_get's
# grep|cut pipeline returning non-zero for a missing key, under this
# script's set -euo pipefail, silently aborted the WHOLE --check-stale
# invocation before printing anything — exit 1 with zero output, which
# reads as STALE with no explanation. This file is missing script_path and
# script_mtime_at_launch entirely (simulating a write truncated after the
# first two lines); the fix must still run to completion and report SOME
# coherent status rather than dying silently mid-read.
PARTIAL_DIR="$TEST_DIR/partial-state-project"
mkdir -p "$PARTIAL_DIR/.swarm"
cat > "$PARTIAL_DIR/.swarm/coordinator-watch.state" <<EOF
pid=$$
started_at=2026-08-08T10:00:00Z
EOF
set +e
OUT="$("$WATCH" --check-stale "$PARTIAL_DIR" 2>&1)"; RC=$?
set -e
if [ -n "$OUT" ]; then got=produced; else got=empty; fi
check "partial state file -> --check-stale still produces output (does not die silently)" "produced" "$got"
check "partial state file -> a live pid but no confirmable script -> exit 1 (STALE: can't confirm freshness)" "1" "$RC"
if echo "$OUT" | grep -q 'status: *STALE'; then got=stale; else got=notstale; fi
check "partial state file -> reports STALE, not a bare unexplained failure" "stale" "$got"

heading "Test 7: a live watcher startup writes a state file that --check-stale reads as FRESH while it's running, then NOT RUNNING once it exits"
# End-to-end sanity check that the real startup code path (not a hand-
# written fixture) produces a state file --check-stale can read correctly
# both while the watcher is genuinely alive (kept running via ONCE=0 rather
# than letting it exit immediately — see Test 5b above for why the
# liveness check makes this distinction matter) and after it's gone.
LIVE_PROJECT="$TEST_DIR/live-project"
mkdir -p "$LIVE_PROJECT/.swarm"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_LLM_START"

DRY_RUN=1 WATCHER_QUIET=1 LLM_START="$FAKE_LLM_START" WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 AUTO_COMPACT=0 WORKER_AUTO_COMPACT=0 \
    WORKER_AUTO_DELIVER=0 WATCHER_STALE_CHECK=0 ONCE=0 "$WATCH" "$LIVE_PROJECT" >/dev/null 2>&1 &
LIVE_WATCH_PID=$!

STATE_FILE="$LIVE_PROJECT/.swarm/coordinator-watch.state"
for _i in $(seq 1 50); do
    [ -r "$STATE_FILE" ] && break
    sleep 0.1
done
if [ -r "$STATE_FILE" ]; then got=written; else got=missing; fi
check "a real watcher startup writes .swarm/coordinator-watch.state" "written" "$got"

set +e
OUT="$("$WATCH" --check-stale "$LIVE_PROJECT" 2>&1)"; RC=$?
set -e
check "while the real watcher process is still alive, its own script reads as FRESH" "0" "$RC"

kill "$LIVE_WATCH_PID" 2>/dev/null || true
# Wait for it to actually exit rather than trusting a fixed sleep — racing
# the check against a kill still in flight would flakily report FRESH.
for _i in $(seq 1 50); do
    kill -0 "$LIVE_WATCH_PID" 2>/dev/null || break
    sleep 0.1
done

set +e
OUT="$("$WATCH" --check-stale "$LIVE_PROJECT" 2>&1)"; RC=$?
set -e
check "once that real watcher process has exited -> exit 3, not a stale FRESH from its leftover state file" "3" "$RC"
if echo "$OUT" | grep -q 'status: *NOT RUNNING'; then got=present; else got=missing; fi
check "exited watcher -> reports NOT RUNNING" "present" "$got"

echo ""
green "All watcher-stale-check tests passed ($PASS checks)"
