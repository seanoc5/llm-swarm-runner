#!/usr/bin/env bash
#
# test-coordinator-auto-compact.sh — Tests for coordinator-watch.sh's
# AUTO_COMPACT feature (auto-compact a long-lived coordinator before
# waking it, see that file's header comment).
#
# Unlike test-watcher-autoclose.sh (which runs the real coordinator-watch.sh
# as a subprocess with kill-finished-workers.sh/llm-start.sh stubbed on
# PATH), this feature's units — coordinator_pane_state, coordinator_pane_busy,
# probe_ctx_used, maybe_auto_compact — have no equivalent PATH-stubbable
# seam: they call tmux directly and read a probe file. So instead this test
# extracts those function bodies verbatim from the real script (sed, not a
# hand-retyped copy — see extract_fn below) and exercises them against a
# real (throwaway) tmux session, which is the cheapest way to get genuine
# pane_current_command / capture-pane behavior without mocking tmux itself.
#
# Requires: tmux, jq (both already required by the feature itself).
#
# The tmux() shadow function near Test 6 is defined mid-file on purpose:
# calls above it hit the real tmux binary, calls below it (until unset -f)
# hit the stub. shellcheck's SC2218 flags every call above the definition
# as if it were a forward-reference bug, so it's disabled file-wide here.
# shellcheck disable=SC2218
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"
command -v jq   >/dev/null 2>&1 || red "jq not found — required by this feature and this test"

TEST_DIR=$(mktemp -d -t coord-auto-compact-XXXXXX)
SESSION_NAME="test-auto-compact-$$"
cleanup() {
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    local fn="$1"
    sed -n "/^${fn}() {/,/^}/p" "$WATCH"
}
for fn in mtime_epoch coordinator_pane_state coordinator_pane_busy probe_ctx_used maybe_auto_compact \
          auto_compact_poll_pass log_event; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $WATCH — has it been renamed?"
    eval "$body"
done

# ─────────────────────────── fixed env the functions expect ────────────────
EVENTS_LOG="$TEST_DIR/events.log"; : > "$EVENTS_LOG"
AUTO_COMPACT_LOCK="$TEST_DIR/coord-compact.lock"
HAVE_JQ=1
DRY_RUN=1
AUTO_COMPACT=1
AUTO_COMPACT_THRESHOLD_TOKENS=150000
AUTO_COMPACT_PROBE_MAX_AGE_SECS=120
AUTO_COMPACT_BUSY_PATTERN='Considering…|Sautéed for|Cooked for|Baked for|Simmered for|✻|✶|Press Ctrl-C again to .xit'
AUTO_COMPACT_START_TIMEOUT_SECS=15
AUTO_COMPACT_FINISH_TIMEOUT_SECS=300
AUTO_COMPACT_VERIFY_TIMEOUT_SECS=30
AUTO_COMPACT_POLL_SECS=2
AUTO_COMPACT_PROBE="$TEST_DIR/probe.json"
AUTO_COMPACT_COOLDOWN_SECS=900
LAST_AUTO_COMPACT_POLL_TRIGGER=0

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

# check_eventually — like check(), but for assertions that read tmux pane
# state right after a send-keys: the shell needs a moment to parse the
# injected keystrokes and exec the new foreground process, and tmux needs a
# moment after that to notice the pty's foreground pgrp changed. A single
# fixed sleep before sampling is a race — generous enough on an idle box,
# too short under load (e.g. this host running several other things at
# once), which is exactly the "expected [cli] got [shell]" flake this
# fixture used to produce. Polling up to `max` times keeps a correct-and-fast
# run just as fast (it returns the instant the condition holds) while giving
# a loaded run real headroom -- a genuine classification bug still fails,
# just after the full poll window instead of after one guess.
check_eventually() {
    local desc="$1" expect="$2" cmd="$3" max="${4:-30}"
    local got=""
    for ((i = 0; i < max; i++)); do
        got="$(eval "$cmd")"
        if [ "$expect" = "$got" ]; then
            green "$desc"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep 0.1
    done
    red "$desc (expected [$expect] got [$got] after $((max))x0.1s polling)"
}

heading "Test 1: coordinator_pane_state"
state="$(coordinator_pane_state)"
check "no session -> absent" "absent" "$state"

tmux new-session -d -s "$SESSION_NAME" -n coordinator 2>/dev/null
check_eventually "fresh session, bash foreground -> shell" "shell" 'coordinator_pane_state'

tmux send-keys -t "$SESSION_NAME:coordinator" "sleep 300" Enter
check_eventually "non-shell foreground -> cli" "cli" 'coordinator_pane_state'
tmux send-keys -t "$SESSION_NAME:coordinator" C-c
sleep 0.2

heading "Test 2: coordinator_pane_busy"
busy_or_idle() { if coordinator_pane_busy; then echo busy; else echo idle; fi; }

tmux send-keys -t "$SESSION_NAME:coordinator" "clear; echo 'some idle prompt >'" Enter
check_eventually "idle-looking text -> not busy" "idle" 'busy_or_idle'

tmux send-keys -t "$SESSION_NAME:coordinator" "clear; echo '✻ Considering… (esc to interrupt)'" Enter
check_eventually "spinner text -> busy" "busy" 'busy_or_idle'

tmux send-keys -t "$SESSION_NAME:coordinator" "clear; echo 'Press Ctrl-C again to exit'" Enter
check_eventually "exit-confirm text -> busy (guarded against a stray Enter)" "busy" 'busy_or_idle'

heading "Test 3: probe_ctx_used"
rm -f "$AUTO_COMPACT_PROBE"
rc=0; out="$(probe_ctx_used)" || rc=$?
check "missing probe -> rc1" "1" "$rc"

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
rc=0; out="$(probe_ctx_used)" || rc=$?
check "fresh valid probe -> rc0" "0" "$rc"
check "fresh valid probe -> used=160000" "160000" "$out"

touch -d '@0' "$AUTO_COMPACT_PROBE" 2>/dev/null || touch -t 197001010000 "$AUTO_COMPACT_PROBE"
rc=0; out="$(probe_ctx_used)" || rc=$?
check "stale probe -> rc1" "1" "$rc"

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":"garbage"}}' > "$AUTO_COMPACT_PROBE"
rc=0; out="$(probe_ctx_used)" || rc=$?
check "non-numeric used -> rc1" "1" "$rc"

heading "Test 4: maybe_auto_compact threshold + pane-state gating (DRY_RUN)"
printf '{"context_window":{"context_window_size":200000,"total_input_tokens":50000}}' > "$AUTO_COMPACT_PROBE"
# `cat` (no args) keeps a non-shell process in the foreground (state=cli)
# while leaving the just-echoed line as the visible screen content, so both
# the pane-state and busy checks see what we intend simultaneously.
tmux send-keys -t "$SESSION_NAME:coordinator" "clear; echo 'idle >'; cat" Enter
check_eventually "cat foreground -> cli (sanity check before the threshold test)" "cli" 'coordinator_pane_state'

before="$(wc -l < "$EVENTS_LOG")"
maybe_auto_compact
after="$(wc -l < "$EVENTS_LOG")"
check "under threshold -> no compact event logged" "$before" "$after"

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
maybe_auto_compact
if grep -q 'coord.compact ' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "over threshold, idle cli pane -> coord.compact logged (DRY_RUN, no real injection)" "logged" "$got"

heading "Test 5: real (non-DRY_RUN) injection against a fake REPL"
# Stand-in for a live Claude Code REPL: prints an idle prompt, reads one
# line at a time, and on "/compact" simulates a multi-second compaction
# (busy indicator, then redraws back to idle) -- enough to validate the
# real load-buffer+paste-buffer+send-keys-Enter injection + capture-pane
# polling loop without needing the actual CLI.
FAKE_REPL="$TEST_DIR/fake-claude-repl.sh"
cat > "$FAKE_REPL" <<'REPL'
#!/usr/bin/env bash
echo "idle-prompt >"
while IFS= read -r line; do
    # A real Claude Code TUI enables bracketed-paste mode, so tmux wraps the
    # pasted "/compact\n" content in escape sequences the app reads as
    # "insert a literal newline into the input buffer", not "submit" -- only
    # the standalone send-keys Enter afterwards actually submits. A plain
    # `read` loop like this one has no bracketed-paste awareness, so it sees
    # the embedded newline as its own line terminator and picks up a
    # second, empty line from the trailing Enter. Skipping blanks here is a
    # test-fixture accommodation for that gap, not a real REPL quirk.
    [ -z "$line" ] && continue
    if [ "$line" = "/compact" ]; then
        echo "✻ Considering… (esc to interrupt)"
        sleep 4
        # A real TUI redraws its status region in place rather than
        # appending new lines, so the busy indicator is genuinely gone from
        # the visible screen once idle -- `clear` approximates that (plain
        # echo would otherwise leave it sitting in scrollback forever,
        # which a real redrawing TUI wouldn't do).
        clear
        echo "idle-prompt >"
    else
        echo "unrecognized: $line"
        echo "idle-prompt >"
    fi
done
REPL
chmod +x "$FAKE_REPL"

DRY_RUN=0
AUTO_COMPACT_START_TIMEOUT_SECS=10
AUTO_COMPACT_FINISH_TIMEOUT_SECS=15
AUTO_COMPACT_VERIFY_TIMEOUT_SECS=10
AUTO_COMPACT_POLL_SECS=1
: > "$EVENTS_LOG"

# Test 4 left `cat` blocked in the foreground reading stdin -- interrupt it
# first, or the exec command below would be fed to cat as input rather than
# interpreted by the shell.
tmux send-keys -t "$SESSION_NAME:coordinator" C-c
sleep 0.3
# exec -a claude sets argv[0] so pane_current_command reports "claude" (the
# real CLI's process name) rather than "bash" -- otherwise this fixture,
# itself a bash script, would be indistinguishable from an idle interactive
# shell under coordinator_pane_state's process-name check.
tmux send-keys -t "$SESSION_NAME:coordinator" "exec -a claude bash $FAKE_REPL" Enter
check_eventually "fake REPL foreground (argv[0]=claude) -> cli" "cli" 'coordinator_pane_state'

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
# Simulate a real installed statusline re-rendering with post-compaction
# usage: the fixture's fake compaction takes 4s, so land the lower value
# in the probe file around then -- close to when the busy indicator clears
# and maybe_auto_compact starts polling the probe's mtime for a refresh.
# This exercises the ineffective-compaction check's HAPPY path (usage
# really did drop -> no warning).
( sleep 4; printf '{"context_window":{"context_window_size":200000,"total_input_tokens":40000}}' > "$AUTO_COMPACT_PROBE" ) &
BGPID=$!
start_ts=$(date +%s)
maybe_auto_compact
end_ts=$(date +%s)
wait "$BGPID" 2>/dev/null || true
elapsed=$((end_ts - start_ts))

# start-wait (~0-1s) + fixture compaction (4s) + finish-wait (~0-1s) +
# verify-poll until the probe's mtime advances (~0-1s, since the
# background job lands the fresh probe right around when busy clears)
# puts this around 5-7s; bound generously either side.
if grep -q 'coord.compact.done' "$EVENTS_LOG" && [ "$elapsed" -ge 4 ] && [ "$elapsed" -lt 20 ]; then
    green "real /compact injection observed start->finish transition (~${elapsed}s; fixture sleeps 4s)"
    PASS=$((PASS + 1))
else
    red "did not observe expected coord.compact.done within the expected window (elapsed=${elapsed}s); events.log: $(cat "$EVENTS_LOG")"
fi
if grep -q 'coord.compact.ineffective' "$EVENTS_LOG"; then
    red "usage genuinely dropped (160000 -> 40000) but coord.compact.ineffective still fired; events.log: $(cat "$EVENTS_LOG")"
else
    green "usage genuinely dropped -> no false-positive coord.compact.ineffective"
    PASS=$((PASS + 1))
fi

heading "Test 6: set -e safety — a forced tmux failure must not abort the process"
# This file (coordinator-watch.sh) runs under set -euo pipefail. Force
# `tmux list-panes` to fail mid-call (simulating the TOCTOU window
# coordinator_pane_state's own has-session/list-windows precondition
# checks can't fully close) and confirm the function degrades to a safe
# fallback instead of taking the whole daemon down.
tmux() {
    if [ "$1" = "list-panes" ]; then
        return 7
    fi
    command tmux "$@"
}
state="$(coordinator_pane_state)" || state="CRASHED"
unset -f tmux
if [ "$state" = "shell" ]; then
    green "forced tmux list-panes failure resolved to a safe fallback (state=shell), process still alive"
    PASS=$((PASS + 1))
else
    red "expected state=shell on tmux failure, got [$state]"
fi

heading "Test 7: ineffective-compaction detection — usage that DOESN'T drop must warn"
# Reuses the SAME fake REPL instance still running from Test 5 (it's a
# `while read` loop, so it's just sitting idle waiting for the next line --
# no need to restart it, and no C-c here: that process was launched via
# `exec`, so interrupting it would kill the pane's only process and take
# the whole session down with it). This time the background job re-writes
# the probe with the SAME value (fresh mtime, unchanged usage) -- simulating
# a statusline that genuinely re-rendered post-compaction but showed no
# drop, which is the exact silent-failure mode self-review flagged: a
# pasted "/compact" that somehow got submitted as a plain chat message
# instead of the slash command would still show the busy indicator
# appearing and clearing (claude processed *a* turn), but context would not
# actually drop. (A probe that's never rewritten AT ALL is a different,
# inconclusive case -- covered by Test 8 below.)
: > "$EVENTS_LOG"
printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
( sleep 4; printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE" ) &
BGPID7=$!
maybe_auto_compact
wait "$BGPID7" 2>/dev/null || true
if grep -q 'coord.compact.ineffective' "$EVENTS_LOG"; then
    green "usage did not drop (fresh probe, same value) -> coord.compact.ineffective correctly fired"
    PASS=$((PASS + 1))
else
    red "usage stayed at 160000 across the 'compaction' but no coord.compact.ineffective fired; events.log: $(cat "$EVENTS_LOG")"
fi

heading "Test 8: verify-skip — a probe that never refreshes must NOT be flagged as ineffective"
# Same setup as Test 7, but the probe is left completely untouched this
# time (no background rewrite at all) -- simulating a statusline that
# simply hasn't re-rendered yet (slow refresh cadence, pane not focused,
# etc). This must be inconclusive (coord.compact.verify_skip), not a false
# "ineffective" warning on a compaction that may have worked fine.
: > "$EVENTS_LOG"
printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
AUTO_COMPACT_VERIFY_TIMEOUT_SECS=3 maybe_auto_compact
if grep -q 'coord.compact.verify_skip' "$EVENTS_LOG" && ! grep -q 'coord.compact.ineffective' "$EVENTS_LOG"; then
    green "probe never refreshed -> coord.compact.verify_skip (no false-positive ineffective)"
    PASS=$((PASS + 1))
else
    red "expected verify_skip with no ineffective warning; events.log: $(cat "$EVENTS_LOG")"
fi

heading "Test 9: auto_compact_poll_pass — issue #210 poll-tick trigger"
# Reuses the same fake REPL still running from Tests 5/7/8 (idle at its
# prompt, cli foreground via exec -a claude) -- see Test 7's comment on why
# it's never interrupted once launched via exec.

# --- 9a: over threshold, idle pane -> fires with trigger=poll, cooldown starts ---
: > "$EVENTS_LOG"
printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
LAST_AUTO_COMPACT_POLL_TRIGGER=0
( sleep 4; printf '{"context_window":{"context_window_size":200000,"total_input_tokens":40000}}' > "$AUTO_COMPACT_PROBE" ) &
BGPID9=$!
auto_compact_poll_pass
wait "$BGPID9" 2>/dev/null || true

if grep -Eq '^[^ ]+  coord\.compact {2}.*trigger=poll' "$EVENTS_LOG"; then
    green "poll-tick trigger fires and tags the coord.compact event trigger=poll"
    PASS=$((PASS + 1))
else
    red "expected a coord.compact line tagged trigger=poll; events.log: $(cat "$EVENTS_LOG")"
fi
if grep -q 'coord.compact.done.*trigger=poll' "$EVENTS_LOG"; then
    green "coord.compact.done also tagged trigger=poll"
    PASS=$((PASS + 1))
else
    red "expected coord.compact.done tagged trigger=poll; events.log: $(cat "$EVENTS_LOG")"
fi
check "cooldown timestamp recorded after an attempted compact" "1" "$([ "$LAST_AUTO_COMPACT_POLL_TRIGGER" -gt 0 ] && echo 1 || echo 0)"

# --- 9b: still over threshold, but within cooldown -> must NOT re-fire ---
before="$(wc -l < "$EVENTS_LOG")"
auto_compact_poll_pass
after="$(wc -l < "$EVENTS_LOG")"
check "cooldown suppresses immediate re-trigger -> no new lines logged beyond the skip" \
    "1" "$(tail -n $((after - before)) "$EVENTS_LOG" | grep -c 'coord.compact.skip.*reason=cooldown trigger=poll' || true)"
if tail -n $((after - before)) "$EVENTS_LOG" | grep -q '^[^ ]\+  coord\.compact  '; then
    red "cooldown should have suppressed a second injection; events.log tail: $(tail -n $((after - before)) "$EVENTS_LOG")"
else
    green "no second coord.compact injection while cooldown is active"
    PASS=$((PASS + 1))
fi

# --- 9c: cooldown expires -> poll-tick fires again ---
AUTO_COMPACT_COOLDOWN_SECS=1
sleep 2
printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
before="$(wc -l < "$EVENTS_LOG")"
( sleep 4; printf '{"context_window":{"context_window_size":200000,"total_input_tokens":40000}}' > "$AUTO_COMPACT_PROBE" ) &
BGPID9c=$!
auto_compact_poll_pass
wait "$BGPID9c" 2>/dev/null || true
after="$(wc -l < "$EVENTS_LOG")"
if tail -n $((after - before)) "$EVENTS_LOG" | grep -Eq '^[^ ]+  coord\.compact {2}.*trigger=poll'; then
    green "poll-tick re-fires once the cooldown window has elapsed"
    PASS=$((PASS + 1))
else
    red "expected a fresh coord.compact after cooldown expiry; events.log tail: $(tail -n $((after - before)) "$EVENTS_LOG")"
fi
AUTO_COMPACT_COOLDOWN_SECS=900

# --- 9d: busy pane -> poll-tick skips silently, tagged trigger=poll, no
# cooldown consumed (so it can retry on the very next tick rather than wait
# out a cooldown meant for actual compact attempts) ---
orig_coordinator_pane_busy="$(extract_fn coordinator_pane_busy)"
coordinator_pane_busy() { return 0; }
: > "$EVENTS_LOG"
LAST_AUTO_COMPACT_POLL_TRIGGER=0
auto_compact_poll_pass
eval "$orig_coordinator_pane_busy"
if grep -q 'coord.compact.skip.*reason=pane_busy trigger=poll' "$EVENTS_LOG"; then
    green "busy pane -> coord.compact.skip reason=pane_busy trigger=poll (existing skip event, now tagged)"
    PASS=$((PASS + 1))
else
    red "expected coord.compact.skip reason=pane_busy trigger=poll; events.log: $(cat "$EVENTS_LOG")"
fi
check "pane-busy skip does not start a cooldown" "0" "$LAST_AUTO_COMPACT_POLL_TRIGGER"

heading "Test 10: maybe_auto_compact serializes concurrent wake + poll callers (issue #210 review finding)"
# Reuses the same fake REPL still running from Tests 5/7/8/9 (idle at its
# prompt). Before the flock added in review, a wake-path call and a
# poll-tick call landing within milliseconds of each other could both pass
# the coordinator_pane_busy check while the pane was still idle, then both
# race on the SAME tmux buffer (llm-coord-autocompact) -- this fires them
# genuinely concurrently (each in its own subshell, backgrounded together)
# and asserts only ONE of them actually injects, the other backs off with
# reason=locked rather than racing the tmux calls.
: > "$EVENTS_LOG"
printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"
( sleep 4; printf '{"context_window":{"context_window_size":200000,"total_input_tokens":40000}}' > "$AUTO_COMPACT_PROBE" ) &
BGPID10=$!
( maybe_auto_compact wake ) &
WAKE_PID=$!
( maybe_auto_compact poll ) &
POLL_PID=$!
wait "$WAKE_PID" 2>/dev/null || true
wait "$POLL_PID" 2>/dev/null || true
wait "$BGPID10" 2>/dev/null || true

attempts="$(grep -Ec '^[^ ]+  coord\.compact {2,}' "$EVENTS_LOG" || true)"
locked_skips="$(grep -c 'coord.compact.skip.*reason=locked' "$EVENTS_LOG" || true)"
check "exactly one caller actually attempted a compact (no double injection)" "1" "$attempts"
check "exactly one caller backed off on the lock" "1" "$locked_skips"
if grep -q 'coord.compact.done' "$EVENTS_LOG"; then
    green "the winning caller completed its compaction cleanly"
    PASS=$((PASS + 1))
else
    red "expected the lock winner to reach coord.compact.done; events.log: $(cat "$EVENTS_LOG")"
fi

echo ""
green "All coordinator-auto-compact tests passed ($PASS checks)"
