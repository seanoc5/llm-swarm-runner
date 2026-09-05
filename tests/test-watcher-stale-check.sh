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
EVENTS_LOG2="$TEST_DIR/events2.log"
KILL_LOG2="$TEST_DIR/kill2.log"
FAKE_SCRIPT2="$TEST_DIR/fake-watcher2.sh"
echo '#!/usr/bin/env bash' > "$FAKE_SCRIPT2"
sleep 1
touch "$FAKE_SCRIPT2"   # bump mtime so it's stale relative to a launch mtime captured just before this

STALE_FNS="$(extract_fn mtime_epoch; extract_fn watcher_is_stale; extract_fn watcher_check_staleness; extract_fn log_event)"

cat > "$TEST_DIR/run-check.sh" <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail
EVENTS_LOG="$EVENTS_LOG2"
WATCHER_STALE_CHECK=1
WATCHER_SELF_PATH="$FAKE_SCRIPT2"
WATCHER_LAUNCH_MTIME=0
WATCHER_STARTED_AT="2026-08-08T10:00:00Z"
CLEANUP_CALLED=0
cleanup_on_exit() { CLEANUP_CALLED=1; }
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
PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR/.swarm"
CHECK_SCRIPT="$TEST_DIR/checked-script.sh"
echo '#!/usr/bin/env bash' > "$CHECK_SCRIPT"
LAUNCH_MTIME="$(stat -c %Y "$CHECK_SCRIPT" 2>/dev/null || stat -f %m "$CHECK_SCRIPT" 2>/dev/null)"
cat > "$PROJECT_DIR/.swarm/coordinator-watch.state" <<EOF
pid=999999
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

heading "Test 6: --check-stale CLI — missing state file (no watcher has run here)"
NO_WATCHER_DIR="$TEST_DIR/no-watcher-project"
mkdir -p "$NO_WATCHER_DIR"
set +e
OUT="$("$WATCH" --check-stale "$NO_WATCHER_DIR" 2>&1)"; RC=$?
set -e
check "no state file -> exit 2" "2" "$RC"
if echo "$OUT" | grep -qi 'No watcher state file'; then got=present; else got=missing; fi
check "no state file -> explanatory message printed" "present" "$got"

heading "Test 7: a live watcher startup writes a state file that --check-stale reads as FRESH"
# End-to-end sanity check that the real startup code path (not a hand-
# written fixture) produces a state file --check-stale can read. ONCE=1 +
# DRY_RUN=1 + no worker worktrees means the watcher does exactly one no-op
# pass and exits on its own — no tmux/inotify required for this.
LIVE_PROJECT="$TEST_DIR/live-project"
mkdir -p "$LIVE_PROJECT/.swarm"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_LLM_START"

ONCE=1 DRY_RUN=1 WATCHER_QUIET=1 LLM_START="$FAKE_LLM_START" WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 AUTO_COMPACT=0 WORKER_AUTO_COMPACT=0 \
    WORKER_AUTO_DELIVER=0 WATCHER_STALE_CHECK=0 timeout 5 "$WATCH" "$LIVE_PROJECT" >/dev/null 2>&1 || true

STATE_FILE="$LIVE_PROJECT/.swarm/coordinator-watch.state"
if [ -r "$STATE_FILE" ]; then got=written; else got=missing; fi
check "a real watcher startup writes .swarm/coordinator-watch.state" "written" "$got"

set +e
OUT="$("$WATCH" --check-stale "$LIVE_PROJECT" 2>&1)"; RC=$?
set -e
check "immediately after its own startup, the watcher's own script reads as FRESH" "0" "$RC"

echo ""
green "All watcher-stale-check tests passed ($PASS checks)"
