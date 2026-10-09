#!/usr/bin/env bash
#
# test-shape-window-flags.sh — shape tests for issue #594's per-window tmux
# status flags (📬/🟡/✋ on worker windows, 🔔 on the coordinator window).
#
# Covers:
#   - scripts/_window-flags.sh's own rank/ownership contract (set never
#     downgrades, clear only acts when it currently owns the slot), and the
#     WATCH_WINDOW_FLAGS=0 kill switch, sourced and called directly.
#   - on_outcome's 📬 set/clear from an outcome JSON's task_state (through
#     the real coordinator-watch.sh, background, same convention as
#     test-watcher-autoclose.sh).
#   - pr_poll_pass's 🟡 set/clear from gh pr list's state/isDraft.
#   - window_flags_sweep_pass's ✋ set/clear from an outbox decision-needed
#     message appearing/disappearing.
#   - coord_approval_flag_pass's 🔔 set/clear from the coordinator's own
#     transcript.
#
# Strategy: a stub tmux that is a REAL per-window @swarm_flag store (a
# directory of one file per "session:window" key, value = file contents) so
# set/show/unset round-trip exactly like real tmux user options would —
# unlike test-watcher-autoclose.sh's argv-logging stubs, the priority/rank
# tests here need genuine current-value readback.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
WINDOW_FLAGS_LIB="$SCRIPT_DIR/../scripts/_window-flags.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"
[ -f "$WINDOW_FLAGS_LIB" ] || red "_window-flags.sh not found: $WINDOW_FLAGS_LIB"

TEST_DIR=$(mktemp -d -t shape-window-flags-XXXXXX)
export HOST_STATE_DIR="$TEST_DIR/host-state" HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0
cleanup() {
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/bin"

# ───────────────────── Stub tmux: a real @swarm_flag store ─────────────────
#
# FLAG_DIR holds one file per "session:window" key (':' sanitized to '_' so
# it's a safe filename); file content is the flag glyph, file ABSENT means
# unset — matches real tmux's "no such user option" exactly as far as
# _window_flag_current's `2>/dev/null` capture cares (stdout empty either
# way). list-windows/has-session back the few other tmux calls
# coordinator-watch.sh's non-flag code paths (has_live_window,
# coord_human_present-adjacent checks) make along the way.
FLAG_DIR="$TEST_DIR/flag-store"
export FLAG_DIR
mkdir -p "$FLAG_DIR"
TMUX_WINDOWS_FILE="$TEST_DIR/tmux-windows.txt"
: > "$TMUX_WINDOWS_FILE"
FAKE_TMUX="$TEST_DIR/bin/tmux"
cat > "$FAKE_TMUX" <<'STUB'
#!/usr/bin/env bash
key_file() { printf '%s/%s\n' "$FLAG_DIR" "$(printf '%s' "$1" | tr ':/' '__')"; }
case "${1:-}" in
    show-window-options)
        shift
        target=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -t) target="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        kf="$(key_file "$target")"
        [ -f "$kf" ] && cat "$kf"
        exit 0
        ;;
    set-window-option)
        shift
        target="" do_unset=0
        rest=()
        while [ $# -gt 0 ]; do
            case "$1" in
                -t) target="$2"; shift 2 ;;
                -u) do_unset=1; shift ;;
                *) rest+=("$1"); shift ;;
            esac
        done
        kf="$(key_file "$target")"
        if [ "$do_unset" = "1" ]; then
            rm -f "$kf"
        else
            # rest is ("@swarm_flag" "VALUE") — harvest VALUE as the last one.
            val=""
            for a in "${rest[@]}"; do val="$a"; done
            printf '%s' "$val" > "$kf"
        fi
        exit 0
        ;;
    list-windows) cat "$TMUX_WINDOWS_FILE" ;;
    has-session)  exit 1 ;;
    *)            exit 0 ;;
esac
STUB
chmod +x "$FAKE_TMUX"
export PATH="$TEST_DIR/bin:$PATH"

flag_of() {  # flag_of <session:window>
    local kf="$FLAG_DIR/$(printf '%s' "$1" | tr ':/' '__')"
    [ -f "$kf" ] && cat "$kf" || true
}

# ============================================================================
heading "Part A: _window-flags.sh sourced directly — rank/ownership contract"
# ============================================================================
SESSION_NAME="llm-testproj"
EVENTS_SEEN="$TEST_DIR/events-seen.log"
log_event() { printf '%s %s\n' "$1" "$2" >> "$EVENTS_SEEN"; }
# shellcheck source=../scripts/_window-flags.sh
. "$WINDOW_FLAGS_LIB"

: > "$EVENTS_SEEN"
set_window_flag "iss-1" "📬" "test_a1"
[ "$(flag_of "$SESSION_NAME:iss-1")" = "📬" ] || red "expected 📬 set on iss-1"
green "set_window_flag sets an empty slot"
grep -q 'watch.flag window=iss-1 flag=📬' "$EVENTS_SEEN" || red "expected a watch.flag log_event call"
green "set_window_flag calls the caller's log_event when present"

# 🟡 (rank 2) must overwrite 📬 (rank 1) — higher priority wins.
set_window_flag "iss-1" "🟡" "test_a2"
[ "$(flag_of "$SESSION_NAME:iss-1")" = "🟡" ] || red "expected 🟡 to overwrite 📬 (higher rank)"
green "set_window_flag lets a higher-rank flag overwrite a lower one"

# 📬 (rank 1) must NOT overwrite 🟡 (rank 2) — lower priority loses.
set_window_flag "iss-1" "📬" "test_a3"
[ "$(flag_of "$SESSION_NAME:iss-1")" = "🟡" ] || red "lower-rank 📬 incorrectly overwrote 🟡"
green "set_window_flag refuses to let a lower-rank flag overwrite a higher one"

# clear_window_flag for a flag that is NOT the current owner is a no-op.
clear_window_flag "iss-1" "📬" "test_a4"
[ "$(flag_of "$SESSION_NAME:iss-1")" = "🟡" ] || red "clear_window_flag cleared a flag it didn't own"
green "clear_window_flag is a no-op when it doesn't currently own the slot"

# clear_window_flag for the actual current flag clears it.
clear_window_flag "iss-1" "🟡" "test_a5"
[ -z "$(flag_of "$SESSION_NAME:iss-1")" ] || red "clear_window_flag did not clear the flag it owns"
green "clear_window_flag clears the flag it currently owns"

# ✋ (rank 3, highest) set, then a 🟡 set attempt must not downgrade it.
set_window_flag "iss-2" "✋" "test_a6"
set_window_flag "iss-2" "🟡" "test_a7"
[ "$(flag_of "$SESSION_NAME:iss-2")" = "✋" ] || red "🟡 incorrectly downgraded ✋ (highest rank)"
green "✋ (highest rank) survives a later lower-rank set attempt"

# Re-setting the SAME flag that's already current is a cheap no-op (no
# redundant tmux call / log_event) — verify via the events log line count.
: > "$EVENTS_SEEN"
set_window_flag "iss-2" "✋" "test_a8_noop"
[ ! -s "$EVENTS_SEEN" ] || red "re-setting an already-current flag should not log an event; got: $(cat "$EVENTS_SEEN")"
green "set_window_flag is a true no-op when the flag is already current"

# Kill switch: WATCH_WINDOW_FLAGS=0 turns every set/clear into a no-op.
set_window_flag "iss-3" "✋" "test_a9"
[ "$(flag_of "$SESSION_NAME:iss-3")" = "✋" ] || red "setup failed: iss-3 should have ✋ before testing the kill switch"
WATCH_WINDOW_FLAGS=0 set_window_flag "iss-3" "📬" "test_a10"
[ "$(flag_of "$SESSION_NAME:iss-3")" = "✋" ] || red "WATCH_WINDOW_FLAGS=0 should have no-op'd the set"
WATCH_WINDOW_FLAGS=0 clear_window_flag "iss-3" "✋" "test_a11"
[ "$(flag_of "$SESSION_NAME:iss-3")" = "✋" ] || red "WATCH_WINDOW_FLAGS=0 should have no-op'd the clear"
green "WATCH_WINDOW_FLAGS=0 kill switch disables both set and clear"

unset SESSION_NAME
rm -rf "$FLAG_DIR"/*

# ============================================================================
heading "Part B: integration — real coordinator-watch.sh drives all four flags"
# ============================================================================
PROJECT_DIR="$TEST_DIR/myproject"
mkdir -p "$PROJECT_DIR/.swarm"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"

# Stubs the watcher's non-flag code paths need so a background run doesn't
# error out or hang — same roster as test-watcher-autoclose.sh.
KILL_LOG="$TEST_DIR/kill.log"
FAKE_KILL="$TEST_DIR/fake-kill-finished-workers.sh"
cat > "$FAKE_KILL" <<EOF
#!/usr/bin/env bash
printf '%s  KILL: %s\n' "\$(date +%s%N)" "\$*" >> "$KILL_LOG"
echo "Done. Closed 0 window(s)."
exit 0
EOF
chmod +x "$FAKE_KILL"

REAP_ORPHAN_LOG="$TEST_DIR/reap-orphan.log"
FAKE_REAP_ORPHAN="$TEST_DIR/fake-reap-orphan-worktrees.sh"
cat > "$FAKE_REAP_ORPHAN" <<EOF
#!/usr/bin/env bash
printf '%s  REAP: %s\n' "\$(date +%s%N)" "\$*" >> "$REAP_ORPHAN_LOG"
echo "Done. Reaped 0 worktree(s) (skipped 0 of 0 scanned)."
exit 0
EOF
chmod +x "$FAKE_REAP_ORPHAN"

WAKE_LOG="$TEST_DIR/wake.log"
FAKE_LLM_START="$TEST_DIR/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<EOF
#!/usr/bin/env bash
printf '%s  WAKE: %s\n' "\$(date +%s%N)" "\$*" >> "$WAKE_LOG"
exit 0
EOF
chmod +x "$FAKE_LLM_START"

# gh stub: pr list reads a 5-column TSV fixture (branch/state/number/
# createdAt/isDraft, matching pr_poll_pass's --jq projection exactly).
GH_PR_LIST_FILE="$TEST_DIR/gh-pr-list.tsv"
: > "$GH_PR_LIST_FILE"
FAKE_GH="$TEST_DIR/bin/gh"
cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
    cat "$GH_PR_LIST_FILE"
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_GH"

start_watcher() {
    local autoclose="$1" logfile="$2"
    WATCHER_AUTOCLOSE="$autoclose" \
        KILL_FINISHED="$FAKE_KILL" \
        REAP_ORPHAN="${REAP_ORPHAN:-$FAKE_REAP_ORPHAN}" \
        LLM_START="$FAKE_LLM_START" \
        WORKSPACE="$TEST_DIR" \
        WATCH_PR_POLL_SECS="${WATCH_PR_POLL_SECS:-0}" \
        WATCH_ORPHAN_SWEEP_SECS=0 \
        WATCH_CHECK_ON_DONE=0 \
        WATCH_WINDOW_FLAGS="${WATCH_WINDOW_FLAGS:-1}" \
        WATCH_WINDOW_FLAGS_SWEEP_SECS="${WATCH_WINDOW_FLAGS_SWEEP_SECS:-0}" \
        HOME="${FAKE_HOME:-$TEST_DIR/home}" \
        DRY_RUN=0 ONCE="${ONCE:-1}" POLL_SECS=1 DEBOUNCE_SECS=0 \
        "$WATCH" "$PROJECT_DIR" > "$logfile" 2>&1 &
    WATCH_PID=$!
    sleep 1.5
}
stop_watcher() {
    [ -n "${WATCH_PID:-}" ] || return 0
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    unset WATCH_PID
}
wait_for_watcher_exit() {
    local i
    for ((i=0; i<20; i++)); do
        if ! kill -0 "$WATCH_PID" 2>/dev/null; then break; fi
        sleep 0.5
    done
    wait "$WATCH_PID" 2>/dev/null || true
    unset WATCH_PID
}

# ---------------------------------------------------------------------------
heading "Test B1: on_outcome sets 📬 for task_state=done-no-pr"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-42/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"

start_watcher 0 "$TEST_DIR/watch-b1.log"
echo '{"task_id":"t42","outcome":"ok","task_state":"done-no-pr"}' \
    > "$TEST_DIR/wt-issue-42/.swarm/tasks/done/t42.ok.json"
wait_for_watcher_exit

[ "$(flag_of "$SESSION_NAME:iss-42")" = "📬" ] \
    || red "expected 📬 on iss-42 after a done-no-pr outcome. Watch log:
$(cat "$TEST_DIR/watch-b1.log")"
green "on_outcome set 📬 for task_state=done-no-pr"

grep -qE 'watch\.flag[[:space:]]+window=iss-42 flag=📬' "$PROJECT_DIR/.swarm/events.log" \
    || red "expected a watch.flag event in events.log"
green "events.log recorded the watch.flag transition"

# ---------------------------------------------------------------------------
heading "Test B2: on_outcome does NOT set 📬 for task_state=ready-for-review"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-43/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"

start_watcher 0 "$TEST_DIR/watch-b2.log"
echo '{"task_id":"t43","outcome":"ok","task_state":"ready-for-review"}' \
    > "$TEST_DIR/wt-issue-43/.swarm/tasks/done/t43.ok.json"
wait_for_watcher_exit

[ -z "$(flag_of "$SESSION_NAME:iss-43")" ] \
    || red "expected NO flag on iss-43 for a ready-for-review outcome; got: $(flag_of "$SESSION_NAME:iss-43")"
green "on_outcome leaves ready-for-review alone (no 📬)"

# ---------------------------------------------------------------------------
heading "Test B3: on_outcome's 📬 is cleared by a LATER correction to a different state"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-44/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"

start_watcher 0 "$TEST_DIR/watch-b3a.log"
echo '{"task_id":"t44","outcome":"ok","task_state":"done-no-pr"}' \
    > "$TEST_DIR/wt-issue-44/.swarm/tasks/done/t44.ok.json"
wait_for_watcher_exit
[ "$(flag_of "$SESSION_NAME:iss-44")" = "📬" ] || red "setup: expected 📬 before the correction"

start_watcher 0 "$TEST_DIR/watch-b3b.log"
echo '{"task_id":"t44b","outcome":"ok","task_state":"ready-for-review"}' \
    > "$TEST_DIR/wt-issue-44/.swarm/tasks/done/t44b.ok.json"
wait_for_watcher_exit

[ -z "$(flag_of "$SESSION_NAME:iss-44")" ] \
    || red "a later outcome with a different task_state should clear the stale 📬; got: $(flag_of "$SESSION_NAME:iss-44")"
green "a later outcome correction clears a stale 📬"

# ---------------------------------------------------------------------------
heading "Test B4: pr_poll_pass sets 🟡 for an OPEN, non-draft PR"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-50/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"
printf 'fix/issue-50\tOPEN\t101\t2026-01-01T00:00:00Z\tfalse\n' > "$GH_PR_LIST_FILE"

ONCE=0 WATCH_PR_POLL_SECS=2 start_watcher 0 "$TEST_DIR/watch-b4.log"
sleep 4
stop_watcher

[ "$(flag_of "$SESSION_NAME:iss-50")" = "🟡" ] \
    || red "expected 🟡 on iss-50 for an OPEN non-draft PR. Watch log:
$(cat "$TEST_DIR/watch-b4.log")"
green "pr_poll_pass set 🟡 for an OPEN, non-draft PR"

# ---------------------------------------------------------------------------
heading "Test B5: pr_poll_pass withholds 🟡 for a draft PR, and clears one already set"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-51/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"
# Pre-seed 🟡 directly, as if a prior ready PR had set it.
mkdir -p "$FLAG_DIR"
printf '🟡' > "$FLAG_DIR/${SESSION_NAME}_iss-51"
printf 'fix/issue-51\tOPEN\t102\t2026-01-01T00:00:00Z\ttrue\n' > "$GH_PR_LIST_FILE"

ONCE=0 WATCH_PR_POLL_SECS=2 start_watcher 0 "$TEST_DIR/watch-b5.log"
sleep 4
stop_watcher

[ -z "$(flag_of "$SESSION_NAME:iss-51")" ] \
    || red "expected 🟡 to be cleared once the PR went back to draft; got: $(flag_of "$SESSION_NAME:iss-51"). Watch log:
$(cat "$TEST_DIR/watch-b5.log")"
green "pr_poll_pass clears 🟡 when the PR is a draft"

# ---------------------------------------------------------------------------
heading "Test B6: pr_poll_pass clears 🟡 on MERGED/CLOSED"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-52/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$FLAG_DIR"
printf '🟡' > "$FLAG_DIR/${SESSION_NAME}_iss-52"
printf 'fix/issue-52\tMERGED\t103\t2026-01-01T00:00:00Z\tfalse\n' > "$GH_PR_LIST_FILE"

ONCE=0 WATCH_PR_POLL_SECS=2 start_watcher 0 "$TEST_DIR/watch-b6.log"
sleep 4
stop_watcher

[ -z "$(flag_of "$SESSION_NAME:iss-52")" ] \
    || red "expected 🟡 to be cleared on MERGED; got: $(flag_of "$SESSION_NAME:iss-52")"
green "pr_poll_pass clears 🟡 on MERGED"

# ---------------------------------------------------------------------------
heading "Test B7: pr_poll_pass's 🟡 never clobbers a higher-rank ✋"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-53/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"
mkdir -p "$FLAG_DIR"
printf '✋' > "$FLAG_DIR/${SESSION_NAME}_iss-53"
printf 'fix/issue-53\tOPEN\t104\t2026-01-01T00:00:00Z\tfalse\n' > "$GH_PR_LIST_FILE"

ONCE=0 WATCH_PR_POLL_SECS=2 start_watcher 0 "$TEST_DIR/watch-b7.log"
sleep 4
stop_watcher

[ "$(flag_of "$SESSION_NAME:iss-53")" = "✋" ] \
    || red "a ready PR's 🟡 incorrectly clobbered the higher-rank ✋; got: $(flag_of "$SESSION_NAME:iss-53")"
green "🟡 never overwrites a higher-rank ✋ already on the window"

# ---------------------------------------------------------------------------
heading "Test B8: window_flags_sweep_pass sets ✋ for an unprocessed decision-needed message"
# ---------------------------------------------------------------------------
WT60="$TEST_DIR/wt-issue-60"
mkdir -p "$WT60/.swarm/tasks/outbox" "$WT60/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"
: > "$GH_PR_LIST_FILE"
cat > "$WT60/.swarm/tasks/outbox/20260101T000000Z-need-call.md" <<'EOF'
---
kind: decision-needed
task_id: t60
ts: 2026-01-01T00:00:00Z
---
Which way should we go?
EOF

ONCE=0 WATCH_WINDOW_FLAGS_SWEEP_SECS=2 start_watcher 0 "$TEST_DIR/watch-b8.log"
sleep 4
stop_watcher

[ "$(flag_of "$SESSION_NAME:iss-60")" = "✋" ] \
    || red "expected ✋ on iss-60 for an unprocessed decision-needed outbox message. Watch log:
$(cat "$TEST_DIR/watch-b8.log")"
green "window_flags_sweep_pass set ✋ for a live decision-needed message"

# ---------------------------------------------------------------------------
heading "Test B9: window_flags_sweep_pass clears ✋ once the message is archived"
# ---------------------------------------------------------------------------
mkdir -p "$WT60/.swarm/tasks/outbox/processed"
mv "$WT60/.swarm/tasks/outbox/20260101T000000Z-need-call.md" "$WT60/.swarm/tasks/outbox/processed/"

ONCE=0 WATCH_WINDOW_FLAGS_SWEEP_SECS=2 start_watcher 0 "$TEST_DIR/watch-b9.log"
sleep 4
stop_watcher

[ -z "$(flag_of "$SESSION_NAME:iss-60")" ] \
    || red "expected ✋ to clear once the message moved to outbox/processed/; got: $(flag_of "$SESSION_NAME:iss-60")"
green "window_flags_sweep_pass clears ✋ once the message is archived (self-healing)"

# ---------------------------------------------------------------------------
heading "Test B10: window_flags_sweep_pass ignores a non-decision (fyi) outbox message"
# ---------------------------------------------------------------------------
WT61="$TEST_DIR/wt-issue-61"
mkdir -p "$WT61/.swarm/tasks/outbox" "$WT61/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
cat > "$WT61/.swarm/tasks/outbox/20260101T000000Z-fyi.md" <<'EOF'
---
kind: fyi
task_id: t61
ts: 2026-01-01T00:00:00Z
---
Just a heads up.
EOF

ONCE=0 WATCH_WINDOW_FLAGS_SWEEP_SECS=2 start_watcher 0 "$TEST_DIR/watch-b10.log"
sleep 4
stop_watcher

[ -z "$(flag_of "$SESSION_NAME:iss-61")" ] \
    || red "an fyi-only outbox message should never raise ✋; got: $(flag_of "$SESSION_NAME:iss-61")"
green "window_flags_sweep_pass ignores non-decision-needed outbox messages"

# ---------------------------------------------------------------------------
heading "Test B11: coord_approval_flag_pass sets 🔔 when the coordinator's last turn is pending approval"
# ---------------------------------------------------------------------------
# transcript_dir_for() maps $PROJECT_DIR to ~/.claude/projects/<slug> under
# the HOME this watcher run sees — point HOME at a throwaway fixture so we
# control exactly what transcript it finds.
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"
FAKE_HOME="$TEST_DIR/home-b11"
SLUG="$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
TRANSCRIPT_DIR="$FAKE_HOME/.claude/projects/$SLUG"
mkdir -p "$TRANSCRIPT_DIR"
cat > "$TRANSCRIPT_DIR/session.jsonl" <<'EOF'
{"timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"kick off the work"},"promptSource":"typed"}
{"timestamp":"2026-01-01T00:05:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Pending your approval: merge PR #99 (yes/no)"}]}}
EOF

ONCE=0 WATCH_WINDOW_FLAGS_SWEEP_SECS=2 FAKE_HOME="$FAKE_HOME" start_watcher 0 "$TEST_DIR/watch-b11.log"
sleep 4
stop_watcher

[ "$(flag_of "$SESSION_NAME:coordinator")" = "🔔" ] \
    || red "expected 🔔 on the coordinator window when its last turn is pending approval and no human has replied. Watch log:
$(cat "$TEST_DIR/watch-b11.log")"
green "coord_approval_flag_pass set 🔔 for a pending-approval last turn"

# ---------------------------------------------------------------------------
heading "Test B12: coord_approval_flag_pass clears 🔔 once the operator replies"
# ---------------------------------------------------------------------------
cat >> "$TRANSCRIPT_DIR/session.jsonl" <<'EOF'
{"timestamp":"2026-01-01T00:06:00Z","message":{"role":"user","content":"yes, go ahead"},"promptSource":"typed"}
EOF

ONCE=0 WATCH_WINDOW_FLAGS_SWEEP_SECS=2 FAKE_HOME="$FAKE_HOME" start_watcher 0 "$TEST_DIR/watch-b12.log"
sleep 4
stop_watcher

[ -z "$(flag_of "$SESSION_NAME:coordinator")" ] \
    || red "expected 🔔 to clear once a human-typed reply landed; got: $(flag_of "$SESSION_NAME:coordinator")"
green "coord_approval_flag_pass clears 🔔 once the operator replies"

# ---------------------------------------------------------------------------
heading "Test B13: coord_approval_flag_pass stays clear when the last turn isn't an approval ask"
# ---------------------------------------------------------------------------
rm -rf "$FLAG_DIR"/*
FAKE_HOME_B13="$TEST_DIR/home-b13"
SLUG_B13="$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
TRANSCRIPT_DIR_B13="$FAKE_HOME_B13/.claude/projects/$SLUG_B13"
mkdir -p "$TRANSCRIPT_DIR_B13"
cat > "$TRANSCRIPT_DIR_B13/session.jsonl" <<'EOF'
{"timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"status?"},"promptSource":"typed"}
{"timestamp":"2026-01-01T00:05:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Nothing needed from you right now."}]}}
EOF

ONCE=0 WATCH_WINDOW_FLAGS_SWEEP_SECS=2 FAKE_HOME="$FAKE_HOME_B13" start_watcher 0 "$TEST_DIR/watch-b13.log"
sleep 4
stop_watcher

[ -z "$(flag_of "$SESSION_NAME:coordinator")" ] \
    || red "expected no 🔔 when the last turn isn't an approval ask; got: $(flag_of "$SESSION_NAME:coordinator")"
green "coord_approval_flag_pass raises no 🔔 for a non-approval last turn"

# ---------------------------------------------------------------------------
heading "Test B14: WATCH_WINDOW_FLAGS=0 suppresses every flag, end to end"
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/wt-issue-70/.swarm/tasks/done"
rm -rf "$FLAG_DIR"/*
rm -f "$PROJECT_DIR/.swarm/events.log"

WATCH_WINDOW_FLAGS=0 start_watcher 0 "$TEST_DIR/watch-b14.log"
echo '{"task_id":"t70","outcome":"ok","task_state":"done-no-pr"}' \
    > "$TEST_DIR/wt-issue-70/.swarm/tasks/done/t70.ok.json"
wait_for_watcher_exit

[ -z "$(flag_of "$SESSION_NAME:iss-70")" ] \
    || red "WATCH_WINDOW_FLAGS=0 should have suppressed 📬; got: $(flag_of "$SESSION_NAME:iss-70")"
if [ -f "$PROJECT_DIR/.swarm/events.log" ] && grep -q 'watch\.flag ' "$PROJECT_DIR/.swarm/events.log"; then
    red "WATCH_WINDOW_FLAGS=0 should produce zero watch.flag events; got:
$(cat "$PROJECT_DIR/.swarm/events.log")"
fi
green "WATCH_WINDOW_FLAGS=0 suppresses flags end to end (on_outcome path)"

heading "All window-flags shape tests passed"
