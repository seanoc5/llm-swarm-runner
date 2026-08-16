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
    tmux kill-session -t "${SESSION_NAME}-retract" 2>/dev/null || true
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
          auto_compact_poll_pass compact_retract_queued compact_last_pane_line compact_composer_clear \
          compact_confirm_submitted compact_replay_detected log_event; do
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
# issue #252/#274: must match coordinator-watch.sh's own default — anchored
# on the "(esc to interrupt)" hint instead of a spinner-verb list, plus the
# "Compacting conversation" in-flight-compaction anchor (see that file's
# AUTO_COMPACT_BUSY_PATTERN header comment for why).
AUTO_COMPACT_BUSY_PATTERN='\(esc to interrupt\)|Press Ctrl-C again to .xit|Compacting conversation'
AUTO_COMPACT_START_TIMEOUT_SECS=15
AUTO_COMPACT_FINISH_TIMEOUT_SECS=300
AUTO_COMPACT_VERIFY_TIMEOUT_SECS=30
AUTO_COMPACT_POLL_SECS=2
AUTO_COMPACT_PROBE="$TEST_DIR/probe.json"
AUTO_COMPACT_COOLDOWN_SECS=900
LAST_AUTO_COMPACT_POLL_TRIGGER=0
# issue #265 — must match coordinator-watch.sh's own default marker text.
COMPACT_QUEUED_MARKER_PATTERN='Press up to edit queued messages'
COMPACT_RETRACT_BACKSPACES=3
# issue #290 — 0 by default so most tests aren't slowed by the settle
# delay; individual tests below override it where the delay itself is
# what's under test.
COMPACT_SUBMIT_SETTLE_SECS=0
# issue #292 — must match coordinator-watch.sh's own default.
COMPACT_REPLAY_PATTERN='Not enough messages to compact\.'

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

heading "Test 11: shipped AUTO_COMPACT_BUSY_PATTERN default matches 2.1.x busy chrome (issue #266)"
# Every test above pins its own AUTO_COMPACT_BUSY_PATTERN override (set at
# the top of this file), so none of them would have caught issue #266: the
# 2.1.x CLI dropped the "(esc to interrupt)" hint the OLD default was solely
# anchored on, and the default silently stopped matching anything. This test
# extracts the actual shipped default straight out of coordinator-watch.sh
# (not a hand-copied guess) so it fails if the default ever regresses again.
default_pattern="$(
    unset AUTO_COMPACT_BUSY_PATTERN
    eval "$(grep -m1 '^AUTO_COMPACT_BUSY_PATTERN=' "$WATCH")"
    printf '%s' "$AUTO_COMPACT_BUSY_PATTERN"
)"
[ -n "$default_pattern" ] || red "could not extract AUTO_COMPACT_BUSY_PATTERN default from $WATCH"

match_default() {
    printf '%s' "$1" | LC_ALL=C grep -qE "$default_pattern" && echo match || echo nomatch
}

check "default matches 2.1.x spinner token counter" "match" \
    "$(match_default '✽ Churning… (1s · ↓ 63 tokens)')"
check "default matches queued-input marker" "match" \
    "$(match_default '❯ Press up to edit queued messages')"
check "default still matches legacy esc-to-interrupt hint (<=2.0.x)" "match" \
    "$(match_default '✻ Considering… (esc to interrupt)')"
check "default still matches Ctrl-C exit-confirm prompt" "match" \
    "$(match_default 'Press Ctrl-C again to exit')"
check "default does NOT match finished-turn summary (no token counter)" "nomatch" \
    "$(match_default '✻ Churned for 13s')"
check "default does NOT match idle statusline /clear hint" "nomatch" \
    "$(match_default 'sonnet · wt-issue-42 · ctx: 900k/1M (90%) · new task? /clear to save 109.7k tokens')"
check "default matches an in-flight compaction (issue #274)" "match" \
    "$(match_default 'Compacting conversation… (1m 49s)')"

heading "Test 11b: shipped COMPACT_RETRACT_BACKSPACES/COMPACT_SUBMIT_SETTLE_SECS defaults (issue #290)"
# The runtime-log incident this fixes: COMPACT_RETRACT_BACKSPACES=3 against a
# 9-char "/compact " ghost left "/compa" sitting in the composer. Guard the
# shipped default directly so a future edit can't silently regress it back
# below the composer's full length.
default_backspaces="$(
    unset COMPACT_RETRACT_BACKSPACES
    eval "$(grep -m1 '^COMPACT_RETRACT_BACKSPACES=' "$WATCH")"
    printf '%s' "$COMPACT_RETRACT_BACKSPACES"
)"
check "shipped COMPACT_RETRACT_BACKSPACES default covers the full 9-char \"/compact \" ghost" "1" \
    "$([ "${default_backspaces:-0}" -ge 9 ] && echo 1 || echo 0)"
default_settle="$(
    unset COMPACT_SUBMIT_SETTLE_SECS
    eval "$(grep -m1 '^COMPACT_SUBMIT_SETTLE_SECS=' "$WATCH")"
    printf '%s' "$COMPACT_SUBMIT_SETTLE_SECS"
)"
check "shipped COMPACT_SUBMIT_SETTLE_SECS default is a positive delay" "1" \
    "$([ "${default_settle:-0}" -gt 0 ] && echo 1 || echo 0)"

# fake-composer-repl.sh (issue #290)
#
# A bare `cat` (Test 12's old fixture) scrolls forever -- once it echoes
# "/compact", that text sits in scrollback as regular output FOREVER,
# unaffected by later Backspace bytes (those only edit the currently
# uncommitted input line, which is empty by then). That made it impossible
# to test compact_composer_clear's "is the composer ACTUALLY empty" check
# meaningfully. This fixture instead tracks composer state itself and
# redraws it in place after every keystroke -- the way a real Claude Code
# TUI redraws its input box -- so Backspace bytes genuinely shrink what's
# rendered. Escape is a no-op on the composer text (the same BELIEF
# compact_retract_queued's header comment documents), and Enter appends a
# single trailing space the first time (modeling the autocomplete menu
# accepting the completion instead of submitting -- the exact "/compact "
# ghost issue #290 reports) and is a no-op after that. Never renders
# anything busy-pattern-shaped, so a caller driving this through
# maybe_auto_compact deterministically hits a phase=start timeout.
FAKE_COMPOSER="$TEST_DIR/fake-composer-repl.sh"
cat > "$FAKE_COMPOSER" <<'REPL'
#!/usr/bin/env bash
composer=""
stty raw -echo 2>/dev/null || true
render() {
    printf '\033[2J\033[H'
    echo "idle >"
    printf '\xe2\x9d\xaf %s\n' "$composer"
}
render
while IFS= read -rn1 -d '' ch; do
    case "$ch" in
        $'\x7f'|$'\x08') composer="${composer%?}" ;;
        $'\x1b') : ;;
        $'\r'|$'\n')
            case "$composer" in
                *" ") : ;;
                *) composer="$composer " ;;
            esac
            ;;
        *) composer="$composer$ch" ;;
    esac
    render
done
REPL
chmod +x "$FAKE_COMPOSER"

heading "Test 12a: compact_retract_queued — COMPACT_RETRACT_BACKSPACES=3 (old default) leaves a ghost (issue #290)"
# Reproduces the reported incident directly: the composer ends up holding
# "/compact " (9 chars, incl. the autocomplete menu's trailing space) when
# the phase=start timeout fires, and the OLD default of 3 backspaces
# reliably left "/compa" behind -- a partial clear that #265/#272's
# marker-only success check couldn't detect, so it got logged as a
# false-positive "retracted". This must now correctly log retract_failed.
RETRACT_SESSION="${SESSION_NAME}-retract"
tmux new-session -d -s "$RETRACT_SESSION" -n coordinator 2>/dev/null
tmux send-keys -t "$RETRACT_SESSION:coordinator" "exec -a claude bash $FAKE_COMPOSER" Enter

ORIG_SESSION_NAME="$SESSION_NAME"
SESSION_NAME="$RETRACT_SESSION"
check_eventually "retraction session: fake composer foreground -> cli" "cli" 'coordinator_pane_state'

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":200000}}' > "$AUTO_COMPACT_PROBE"

# Shadow tmux to record every invocation (delegating to the real binary
# throughout) so the assertions below can confirm the actual Escape/
# Backspace keystrokes were sent, not just that SOME retraction ran.
TMUX_CALL_LOG="$TEST_DIR/tmux-calls.log"
: > "$TMUX_CALL_LOG"
tmux() {
    printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
    command tmux "$@"
}

DRY_RUN=0
AUTO_COMPACT_START_TIMEOUT_SECS=2
AUTO_COMPACT_POLL_SECS=1
COMPACT_RETRACT_BACKSPACES=3
: > "$EVENTS_LOG"
maybe_auto_compact wake
pane_after_3="$(tmux capture-pane -t "$RETRACT_SESSION:coordinator" -p 2>/dev/null)"
unset -f tmux
SESSION_NAME="$ORIG_SESSION_NAME"
tmux kill-session -t "$RETRACT_SESSION" 2>/dev/null || true

if grep -q 'coord.compact.timeout.*phase=start' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "phase=start timeout logged for the never-busy coordinator pane" "logged" "$got"

if grep -q 'coord.compact.retract_failed' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "3 backspaces against a 9-char ghost -> coord.compact.retract_failed (issue #290)" "logged" "$got"

if grep -q 'coord.compact.retracted' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no false-positive retracted verdict" "absent" "$got"

if printf '%s' "$pane_after_3" | grep -q '/compa'; then got=present; else got=missing; fi
check "composer still shows the exact reported \"/compa\" ghost" "present" "$got"

if grep -q "send-keys -t $RETRACT_SESSION:coordinator Escape" "$TMUX_CALL_LOG"; then got=sent; else got=missing; fi
check "retraction sent an Escape keystroke to the coordinator pane" "sent" "$got"

bspace_count="$(grep -c "send-keys -t $RETRACT_SESSION:coordinator BSpace" "$TMUX_CALL_LOG" || true)"
check "retraction sent 3 Backspace keystrokes" "3" "$bspace_count"

heading "Test 12b: compact_retract_queued — COMPACT_RETRACT_BACKSPACES=12 (shipped default) fully clears the composer (issue #290)"
RETRACT_SESSION_B="${SESSION_NAME}-retractb"
tmux new-session -d -s "$RETRACT_SESSION_B" -n coordinator 2>/dev/null
tmux send-keys -t "$RETRACT_SESSION_B:coordinator" "exec -a claude bash $FAKE_COMPOSER" Enter

SESSION_NAME="$RETRACT_SESSION_B"
check_eventually "retraction session b: fake composer foreground -> cli" "cli" 'coordinator_pane_state'

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":200000}}' > "$AUTO_COMPACT_PROBE"

: > "$TMUX_CALL_LOG"
tmux() {
    printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
    command tmux "$@"
}

COMPACT_RETRACT_BACKSPACES=12
: > "$EVENTS_LOG"
maybe_auto_compact wake
pane_after_12="$(tmux capture-pane -t "$RETRACT_SESSION_B:coordinator" -p 2>/dev/null)"
unset -f tmux
SESSION_NAME="$ORIG_SESSION_NAME"
tmux kill-session -t "$RETRACT_SESSION_B" 2>/dev/null || true
COMPACT_RETRACT_BACKSPACES=3

if grep -q 'coord.compact.retracted' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "12 backspaces against a 9-char ghost -> coord.compact.retracted" "logged" "$got"

if grep -q 'coord.compact.retract_failed' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no false-negative retract_failed" "absent" "$got"

if printf '%s' "$pane_after_12" | grep -qE '/compa|/compact'; then got=present; else got=missing; fi
check "composer fully cleared -- no \"/compact\" fragment left" "missing" "$got"

heading "Test 13: compact_retract_queued — queued marker still visible -> coord.compact.retract_failed (issue #265)"
# Same separate-session technique as Test 12, but this fixture keeps
# re-rendering the queued-input marker on every read cycle regardless of
# what's sent — Escape/Backspace (no trailing Enter) never complete a line,
# so this `read` loop never even wakes up for them; the screen just stays
# exactly as first rendered. That models a retraction attempt that
# genuinely did not clear the queue, so the outcome must be logged as
# retract_failed, never a false-positive retracted.
RETRACT_SESSION2="${SESSION_NAME}-retract2"
tmux new-session -d -s "$RETRACT_SESSION2" -n coordinator 2>/dev/null
FAKE_STUCK="$TEST_DIR/fake-stuck-repl.sh"
cat > "$FAKE_STUCK" <<'REPL'
#!/usr/bin/env bash
render() {
    clear
    echo "idle >"
    echo "❯ Press up to edit queued messages"
}
render
while IFS= read -r line; do
    render
done
REPL
chmod +x "$FAKE_STUCK"
tmux send-keys -t "$RETRACT_SESSION2:coordinator" "exec -a claude bash $FAKE_STUCK" Enter

SESSION_NAME="$RETRACT_SESSION2"
check_eventually "stuck-queue session: fake REPL foreground -> cli" "cli" 'coordinator_pane_state'

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":200000}}' > "$AUTO_COMPACT_PROBE"

: > "$TMUX_CALL_LOG"
tmux() {
    printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
    command tmux "$@"
}

: > "$EVENTS_LOG"
maybe_auto_compact wake
unset -f tmux
SESSION_NAME="$ORIG_SESSION_NAME"
tmux kill-session -t "$RETRACT_SESSION2" 2>/dev/null || true

if grep -q 'coord.compact.timeout.*phase=start' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "phase=start timeout logged for the stuck-queue coordinator pane" "logged" "$got"

if grep -q 'coord.compact.retract_failed' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "queued marker still visible after Escape/Backspace -> coord.compact.retract_failed" "logged" "$got"

if grep -q 'coord.compact.retracted' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no false-positive retracted verdict" "absent" "$got"

if grep -q "send-keys -t $RETRACT_SESSION2:coordinator Escape" "$TMUX_CALL_LOG"; then got=sent; else got=missing; fi
check "retraction still sent an Escape keystroke even though it didn't clear the queue" "sent" "$got"

heading "Test 14: compact_retract_queued — never sends Escape into a pane that's genuinely busy (issue #290 reconciliation with #274)"
# A phase=start timeout can be a FALSE positive: the compaction may
# actually be running, just missed by a busy-pattern regression (the exact
# shape of #274's incident). compact_retract_queued must refuse to send
# ANY keystroke in that case -- called here directly (not through
# maybe_auto_compact, which wouldn't even reach the timeout/retraction
# branch if the pane is genuinely busy) so the guard itself is exercised
# in isolation.
RETRACT_SESSION3="${SESSION_NAME}-retract3"
tmux new-session -d -s "$RETRACT_SESSION3" -n coordinator 2>/dev/null
tmux send-keys -t "$RETRACT_SESSION3:coordinator" "clear; echo 'idle >'; echo 'Compacting conversation… (12s)'; cat" Enter
check_eventually "busy-guard session: compaction text visible" "busy" \
    "tmux capture-pane -t '$RETRACT_SESSION3:coordinator' -p 2>/dev/null | grep -q 'Compacting conversation' && echo busy || echo idle"

: > "$TMUX_CALL_LOG"
tmux() {
    printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
    command tmux "$@"
}

: > "$EVENTS_LOG"
if compact_retract_queued "$RETRACT_SESSION3:coordinator" coord.compact "trigger=wake" "$AUTO_COMPACT_BUSY_PATTERN"; then
    rc=0
else
    rc=$?
fi
unset -f tmux
tmux kill-session -t "$RETRACT_SESSION3" 2>/dev/null || true

check "retraction guard returns success (no-op is not a failure)" "0" "$rc"
if grep -q 'coord.compact.retract_skip.*reason=busy' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "coord.compact.retract_skip reason=busy logged" "logged" "$got"
if grep -q "send-keys -t $RETRACT_SESSION3:coordinator Escape" "$TMUX_CALL_LOG"; then got=present; else got=absent; fi
check "NO Escape sent into the genuinely-busy pane" "absent" "$got"
if grep -q "send-keys -t $RETRACT_SESSION3:coordinator BSpace" "$TMUX_CALL_LOG"; then got=present; else got=absent; fi
check "NO Backspace sent into the genuinely-busy pane" "absent" "$got"

heading "Test 15: maybe_auto_compact — Enter eaten by the autocomplete menu is retried once (issue #290)"
# Models the ROOT CAUSE bug this issue fixes: the first Enter after pasting
# "/compact" is consumed by the CLI's slash-command autocomplete menu --
# accepting the completion (composer becomes "/compact ", NOT submitted)
# instead of starting a turn. A line-buffered `read` loop can't model this
# (the kernel already delivers the full "/compact" line to read() the
# instant Enter arrives, so there's no way for the text to still be
# "sitting in the composer" for a later bare Enter to submit) -- this
# fixture tracks composer state itself, raw byte by raw byte, like
# fake-composer-repl.sh above, so a SECOND bare Enter against the
# still-present "/compact "/"/compact" text can genuinely submit it.
# maybe_auto_compact only reaches coord.compact.done here if its
# resubmit-once logic actually fires that second Enter.
FAKE_REPL_EATFIRST="$TEST_DIR/fake-repl-eatfirst.sh"
cat > "$FAKE_REPL_EATFIRST" <<'REPL'
#!/usr/bin/env bash
composer=""
enters=0
stty raw -echo 2>/dev/null || true
render_idle() {
    printf '\033[2J\033[H'
    echo "idle-prompt >"
    printf '\xe2\x9d\xaf %s\n' "$composer"
}
render_idle
while IFS= read -rn1 -d '' ch; do
    case "$ch" in
        $'\r'|$'\n')
            enters=$((enters + 1))
            if [ "$composer" = "/compact" ] && [ "$enters" -eq 1 ]; then
                composer="$composer "   # menu eats it: appends a space, no submit
                render_idle
                continue
            fi
            if [ "$composer" = "/compact" ] || [ "$composer" = "/compact " ]; then
                composer=""
                printf '\033[2J\033[H'
                echo "✻ Considering… (esc to interrupt)"
                sleep 2
                printf '\033[2J\033[H'
                echo "idle-prompt >"
                printf '\xe2\x9d\xaf \n'
            else
                render_idle
            fi
            ;;
        $'\x7f'|$'\x08') composer="${composer%?}"; render_idle ;;
        $'\x1b') render_idle ;;
        *) composer="$composer$ch"; render_idle ;;
    esac
done
REPL
chmod +x "$FAKE_REPL_EATFIRST"

EATFIRST_SESSION="${ORIG_SESSION_NAME}-eatfirst"
tmux new-session -d -s "$EATFIRST_SESSION" -n coordinator 2>/dev/null
tmux send-keys -t "$EATFIRST_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_EATFIRST" Enter

SESSION_NAME="$EATFIRST_SESSION"
check_eventually "eat-first session: fake REPL foreground -> cli" "cli" 'coordinator_pane_state'

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":160000}}' > "$AUTO_COMPACT_PROBE"

DRY_RUN=0
AUTO_COMPACT_START_TIMEOUT_SECS=10
AUTO_COMPACT_FINISH_TIMEOUT_SECS=15
AUTO_COMPACT_VERIFY_TIMEOUT_SECS=5
AUTO_COMPACT_POLL_SECS=1
COMPACT_SUBMIT_SETTLE_SECS=0.2
: > "$EVENTS_LOG"
maybe_auto_compact wake
SESSION_NAME="$ORIG_SESSION_NAME"
tmux kill-session -t "$EATFIRST_SESSION" 2>/dev/null || true
COMPACT_SUBMIT_SETTLE_SECS=0

if grep -q 'coord.compact.resubmit' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "first Enter eaten -> coord.compact.resubmit logged" "logged" "$got"

if grep -q 'coord.compact.done' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "retried Enter reaches the CLI -> coord.compact.done (not a false phase=start timeout)" "logged" "$got"

if grep -q 'coord.compact.timeout.*phase=start' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no phase=start timeout once the retry lands" "absent" "$got"

heading "Test 16: compact_last_pane_line — a captured pane that's ENTIRELY ctx-statusline lines doesn't abort under set -e/pipefail (issue #290 self-review finding)"
# A self-review flagged that compact_last_pane_line's internal pipeline
# (capture -> exclude the ctx: statusline -> trim -> tail) sits under this
# file's `set -o pipefail`: if EVERY captured line matches the ctx:
# exclusion (grep -v then emits zero lines and exits 1), the whole pipeline
# reports non-zero even though nothing actually went wrong -- and since
# compact_confirm_submitted assigns the result via a bare (non-`local`)
# `last="$(compact_last_pane_line ...)"`, that non-zero would trip `set -e`
# and abort the entire watcher process. No live tmux session needed here --
# this stubs the `tmux` builtin directly so capture-pane returns a single
# line that's ENTIRELY the ctx: pattern, deterministically forcing the
# exact grep -v edge case (real captures always have blank padding lines
# that survive the filter, so this can't be reproduced against a real pane
# -- see this function's header comment).
tmux() {
    if [ "$1" = "capture-pane" ]; then
        printf 'sonnet · wt-issue-99 · ctx: 900k/1M (90%%)\n'
        return 0
    fi
    command tmux "$@"
}
rc=0
out="$(compact_last_pane_line "fake:target")" || rc=$?
unset -f tmux
check "compact_last_pane_line returns 0 even when EVERY line matches the ctx exclusion" "0" "$rc"
check "compact_last_pane_line echoes empty (nothing survives the exclusion)" "" "$out"

heading "Test 17: maybe_auto_compact — composer already empty at a phase=start timeout -> coord.compact.delivered_as_text, not a misleading retraction (issue #292)"
# Models the DISTINCT #292 failure mode from Tests 12/13: the injected
# /compact reaches the model as a plain chat message rather than executing
# as a slash command. Unlike a genuine non-submit (Test 12: "/compa" ghost
# left behind) or a genuinely stuck queue (Test 13: queued marker still
# visible), here the composer is ALREADY clear by the time the phase=start
# timeout fires — nothing was ever left un-submitted — yet no busy indicator
# ever appeared either. This must be recognized as "delivered as text" (a
# distinct log event), never the misleading "retracted" verdict a composer
# that's ALREADY empty would otherwise produce for the wrong reason.
FAKE_DELIVERED_AS_TEXT="$TEST_DIR/fake-repl-delivered-as-text.sh"
cat > "$FAKE_DELIVERED_AS_TEXT" <<'REPL'
#!/usr/bin/env bash
composer=""
stty raw -echo 2>/dev/null || true
render() {
    printf '\033[2J\033[H'
    echo "idle >"
    printf '\xe2\x9d\xaf %s\n' "$composer"
}
render
while IFS= read -rn1 -d '' ch; do
    case "$ch" in
        # Models the literal "/compact" being delivered to the model as a
        # plain chat message: the composer clears immediately (accepted),
        # but nothing busy-shaped ever renders — the fixture never shows the
        # quick reply, just settles right back to an empty composer, the
        # same as a real short queued-turn response would once it's done.
        $'\r'|$'\n') composer=""; render ;;
        $'\x7f'|$'\x08') composer="${composer%?}"; render ;;
        $'\x1b') render ;;
        *) composer="$composer$ch"; render ;;
    esac
done
REPL
chmod +x "$FAKE_DELIVERED_AS_TEXT"

DAT_SESSION="${SESSION_NAME}-deliveredastext"
tmux new-session -d -s "$DAT_SESSION" -n coordinator 2>/dev/null
tmux send-keys -t "$DAT_SESSION:coordinator" "exec -a claude bash $FAKE_DELIVERED_AS_TEXT" Enter

ORIG_SESSION_NAME="$SESSION_NAME"
SESSION_NAME="$DAT_SESSION"
check_eventually "delivered-as-text session: fake composer foreground -> cli" "cli" 'coordinator_pane_state'

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":200000}}' > "$AUTO_COMPACT_PROBE"

TMUX_CALL_LOG="$TEST_DIR/tmux-calls-dat.log"
: > "$TMUX_CALL_LOG"
tmux() {
    printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
    command tmux "$@"
}

DRY_RUN=0
AUTO_COMPACT_START_TIMEOUT_SECS=2
AUTO_COMPACT_POLL_SECS=1
: > "$EVENTS_LOG"
maybe_auto_compact wake
unset -f tmux
SESSION_NAME="$ORIG_SESSION_NAME"
tmux kill-session -t "$DAT_SESSION" 2>/dev/null || true

if grep -q 'coord.compact.timeout.*phase=start' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "phase=start timeout still logged (busy indicator never appeared)" "logged" "$got"

if grep -q 'coord.compact.delivered_as_text' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "composer already empty -> coord.compact.delivered_as_text (issue #292)" "logged" "$got"

if grep -q 'coord.compact.retracted' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no misleading coord.compact.retracted verdict" "absent" "$got"

if grep -q 'coord.compact.retract_failed' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no coord.compact.retract_failed either — retraction was never attempted" "absent" "$got"

if grep -q "send-keys -t $DAT_SESSION:coordinator Escape" "$TMUX_CALL_LOG"; then got=present; else got=absent; fi
check "NO Escape sent — nothing was left queued to retract" "absent" "$got"

if grep -q "send-keys -t $DAT_SESSION:coordinator BSpace" "$TMUX_CALL_LOG"; then got=present; else got=absent; fi
check "NO Backspace sent — nothing was left queued to retract" "absent" "$got"

heading "Test 18: maybe_auto_compact — a post-compact replayed /compact ('Not enough messages to compact.') is tolerated, not logged as ineffective (issue #292)"
# Transcript-verified real-world shape (corpusminder coordinator,
# 2026-08-16 02:50:04Z, see this file's COMPACT_REPLAY_PATTERN header
# comment): when the prompt that triggered a compaction was itself
# "/compact", the CLI's post-compact continuation replays it, producing an
# immediate second, harmless rejection — "Not enough messages to compact."
# — that lands within the watcher's own verify window. This fixture always
# prints that text right after a "compaction" finishes, standing in for
# that replay; the probe is deliberately left UNCHANGED post-compact (same
# shape as Test 7's ineffective-detection fixture) to prove the replay
# check takes precedence over the ineffective check, not just that it
# happens to agree with it.
FAKE_REPL_REPLAY="$TEST_DIR/fake-repl-replay.sh"
cat > "$FAKE_REPL_REPLAY" <<'REPL'
#!/usr/bin/env bash
echo "idle-prompt >"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$line" = "/compact" ]; then
        echo "✻ Considering… (esc to interrupt)"
        sleep 2
        clear
        echo "idle-prompt >"
        echo "Not enough messages to compact."
    else
        echo "unrecognized: $line"
        echo "idle-prompt >"
    fi
done
REPL
chmod +x "$FAKE_REPL_REPLAY"

REPLAY_SESSION="${SESSION_NAME}-replay"
tmux new-session -d -s "$REPLAY_SESSION" -n coordinator 2>/dev/null
tmux send-keys -t "$REPLAY_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_REPLAY" Enter

ORIG_SESSION_NAME="$SESSION_NAME"
SESSION_NAME="$REPLAY_SESSION"
check_eventually "replay session: fake REPL foreground -> cli" "cli" 'coordinator_pane_state'

printf '{"context_window":{"context_window_size":200000,"total_input_tokens":170000}}' > "$AUTO_COMPACT_PROBE"
( sleep 3; printf '{"context_window":{"context_window_size":200000,"total_input_tokens":170000}}' > "$AUTO_COMPACT_PROBE" ) &
BGPID18=$!

DRY_RUN=0
AUTO_COMPACT_START_TIMEOUT_SECS=10
AUTO_COMPACT_FINISH_TIMEOUT_SECS=15
AUTO_COMPACT_VERIFY_TIMEOUT_SECS=10
AUTO_COMPACT_POLL_SECS=1
: > "$EVENTS_LOG"
maybe_auto_compact wake
wait "$BGPID18" 2>/dev/null || true
SESSION_NAME="$ORIG_SESSION_NAME"
tmux kill-session -t "$REPLAY_SESSION" 2>/dev/null || true

if grep -q 'coord.compact.done' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "compaction still observed start->finish despite the trailing replay" "logged" "$got"

if grep -q 'coord.compact.replayed' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "post-compact replayed /compact text detected -> coord.compact.replayed (issue #292)" "logged" "$got"

if grep -q 'coord.compact.ineffective' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "replay tolerated -- no false-positive coord.compact.ineffective despite an unchanged probe value" "absent" "$got"

echo ""
green "All coordinator-auto-compact tests passed ($PASS checks)"
