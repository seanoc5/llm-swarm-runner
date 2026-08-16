#!/usr/bin/env bash
#
# test-llm-start-reprompt.sh — Tests for llm-start.sh's live-REPL reprompt
# path (issue #295: extend #291's settle+verify+retry to the wake path).
#
# Same technique as test-coordinator-auto-compact.sh: llm-start.sh's
# reprompt_inject/reprompt_confirm_submitted/reprompt_last_pane_line/
# log_event functions have no PATH-stubbable seam (they call tmux
# directly), so this extracts their bodies verbatim (sed, not a
# hand-retyped copy — see extract_fn below) and exercises them against a
# real (throwaway) tmux session and fake-REPL fixtures — including the
# eaten-first-Enter shape transferred from
# test-coordinator-auto-compact.sh's Test 15 / fake-repl-eatfirst.sh.
#
# Requires: tmux.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_START="$SCRIPT_DIR/../llm-start.sh"
[ -x "$LLM_START" ] || red "llm-start.sh not executable: $LLM_START"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"

TEST_DIR=$(mktemp -d -t llm-start-reprompt-XXXXXX)
SESSION_NAME="test-reprompt-$$"
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
    sed -n "/^${fn}() {/,/^}/p" "$LLM_START"
}
for fn in log_event reprompt_last_pane_line reprompt_confirm_submitted reprompt_inject; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract function '$fn' from $LLM_START — has it been renamed?"
    eval "$body"
done

# ─────────────────────────── fixed env the functions expect ────────────────
EVENTS_LOG="$TEST_DIR/events.log"; : > "$EVENTS_LOG"
# issue #290/#295 — must match the shipped busy-indicator default (anchored
# on the "(esc to interrupt)" hint plus a spinner token counter and the
# queued-input marker; see coordinator-watch.sh's AUTO_COMPACT_BUSY_PATTERN
# header comment for the forensics behind each token — this file's
# COORD_BUSY_PATTERN must stay in sync with it).
COORD_BUSY_PATTERN='\(esc to interrupt\)|Press Ctrl-C again to .xit|· ↓ [0-9.,]+k? tokens|Press up to edit queued messages|Compacting conversation'
# A small positive default (unlike test-coordinator-auto-compact.sh's 0):
# every test here asserts on reprompt_confirm_submitted's single-shot
# capture (no internal poll loop), so genuine pty scheduling latency after
# send-keys needs real settle time to avoid flaking, not just correctness
# under the eaten-Enter races themselves.
COMPACT_SUBMIT_SETTLE_SECS=0.3

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

# check_eventually — see test-coordinator-auto-compact.sh's identical
# helper for the race this guards (tmux needs a moment after send-keys to
# notice the pty's foreground process changed).
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

# pane_contains <target> <needle> — yes/no.
#
# Deliberately captures into a variable FIRST, then greps that variable —
# the same shape reprompt_last_pane_line/reprompt_confirm_submitted use
# internally — rather than piping `tmux capture-pane` directly into
# tail/grep. Empirically, a direct `tmux capture-pane ... | tail -1` (no
# intermediate variable) unreliably returns empty in this sandbox even
# once the pane genuinely holds the expected text — a two-process-pipe
# race specific to this environment, not a real tmux behavior; capture-
# into-a-variable-then-pipe sidesteps it entirely.
pane_contains() {
    local target="$1" needle="$2" content
    content="$(tmux capture-pane -t "$target" -p 2>/dev/null)" || { echo no; return; }
    if printf '%s\n' "$content" | grep -qF "$needle"; then
        echo yes
    else
        echo no
    fi
}

heading "Test 1: reprompt_inject — normal case, Enter submits on the first try"
# Stand-in for a live Claude Code REPL: prints an idle prompt, reads one
# line at a time, and on any non-empty line simulates a brief turn (busy
# indicator, then redraws back to idle).
FAKE_REPL="$TEST_DIR/fake-claude-repl.sh"
cat > "$FAKE_REPL" <<'REPL'
#!/usr/bin/env bash
echo "idle-prompt >"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "✻ Considering… (esc to interrupt)"
    sleep 2
    clear
    echo "idle-prompt >"
done
REPL
chmod +x "$FAKE_REPL"

tmux new-session -d -s "$SESSION_NAME" -n coordinator 2>/dev/null
# A freshly created pane's shell needs a moment before it reliably accepts
# input — send-keys on the very next line can otherwise land before the
# shell has attached, silently dropping the keystrokes rather than merely
# delaying them (verified empirically against this sandbox's tmux).
sleep 0.3
# exec -a claude sets argv[0] so this fixture reads as the real CLI process
# name, matching llm-start.sh's own coordinator-pane detection convention.
tmux send-keys -t "$SESSION_NAME:coordinator" "exec -a claude bash $FAKE_REPL" Enter
check_eventually "fake REPL foreground" "yes" \
    "pane_contains '$SESSION_NAME:coordinator' 'idle-prompt >'"

PROMPT_FILE="$TEST_DIR/prompt1.txt"
printf 'Worker(s) just finished. Triage their outcomes.\n' > "$PROMPT_FILE"
: > "$EVENTS_LOG"
rc=0
reprompt_inject "$SESSION_NAME:coordinator" "$PROMPT_FILE" || rc=$?
check "reprompt_inject returns success on a clean first-try submit" "0" "$rc"

if grep -q 'coord.wake.resubmit' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no spurious resubmit logged on a clean submit" "absent" "$got"
if grep -q 'coord.wake.submit_failed' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no spurious submit_failed logged on a clean submit" "absent" "$got"

tmux send-keys -t "$SESSION_NAME:coordinator" C-c 2>/dev/null || true
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

heading "Test 2: reprompt_inject — first Enter eaten, retried once (issue #290/#295)"
# Fixture transferred from test-coordinator-auto-compact.sh's Test 15
# (fake-repl-eatfirst.sh): models the ROOT CAUSE bug this issue fixes by
# tracking composer state byte-by-byte, so the FIRST Enter after a paste
# can be "eaten" (composer left non-empty, no submit) and only a SECOND
# bare Enter against that still-present text genuinely submits it. Here
# the paste is an arbitrary (non-slash) prompt rather than "/compact",
# since #295 is the generic reprompt path, not specifically slash-command
# autocomplete.
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
            if [ -n "$composer" ] && [ "$enters" -eq 1 ]; then
                # First Enter is eaten: nothing submits, composer unchanged.
                render_idle
                continue
            fi
            if [ -n "$composer" ]; then
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

EATFIRST_SESSION="${SESSION_NAME}-eatfirst"
tmux new-session -d -s "$EATFIRST_SESSION" -n coordinator 2>/dev/null
sleep 0.3   # see Test 1's identical comment on this settle delay
tmux send-keys -t "$EATFIRST_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_EATFIRST" Enter
check_eventually "eat-first session: fake REPL foreground" "yes" \
    "pane_contains '$EATFIRST_SESSION:coordinator' 'idle-prompt >'"

PROMPT_FILE2="$TEST_DIR/prompt2.txt"
# No trailing newline: unlike Test 1's line-buffered fixture, this one reads
# byte-by-byte with no bracketed-paste awareness (same limitation the
# original fake-repl-eatfirst.sh documents — a real terminal wraps the
# pasted content in bracketed-paste escapes so an embedded newline reads as
# "insert a literal newline", not "submit"; this raw fixture can't tell the
# difference). A trailing newline in the pasted file would read as the
# fixture's own first "Enter", short-circuiting the very race under test.
printf 'Top up workers per the Initial Startup Checklist.' > "$PROMPT_FILE2"
: > "$EVENTS_LOG"
rc=0
reprompt_inject "$EATFIRST_SESSION:coordinator" "$PROMPT_FILE2" || rc=$?

check "reprompt_inject still returns success once the retry lands" "0" "$rc"

if grep -q 'coord.wake.resubmit' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "first Enter eaten -> coord.wake.resubmit logged" "logged" "$got"

if grep -q 'coord.wake.submit_failed' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "retried Enter reaches the CLI -> no false submit_failed" "absent" "$got"

tmux kill-session -t "$EATFIRST_SESSION" 2>/dev/null || true

heading "Test 3: reprompt_inject — stuck composer never clears -> coord.wake.submit_failed, not silent (issue #295 acceptance)"
# This fixture never submits at all (every Enter is a no-op against the
# rendered text), modeling a race that neither settle nor a single retry
# can recover from. Must be LOGGED, not dropped silently.
FAKE_REPL_STUCK="$TEST_DIR/fake-repl-stuck.sh"
cat > "$FAKE_REPL_STUCK" <<'REPL'
#!/usr/bin/env bash
render() {
    printf '\033[2J\033[H'
    echo "idle-prompt >"
    echo "❯ some prompt text stuck here"
}
render
while IFS= read -r line; do
    render
done
REPL
chmod +x "$FAKE_REPL_STUCK"

STUCK_SESSION="${SESSION_NAME}-stuck"
tmux new-session -d -s "$STUCK_SESSION" -n coordinator 2>/dev/null
sleep 0.3   # see Test 1's identical comment on this settle delay
tmux send-keys -t "$STUCK_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_STUCK" Enter
check_eventually "stuck session: fake REPL foreground" "yes" \
    "pane_contains '$STUCK_SESSION:coordinator' 'idle-prompt >'"

PROMPT_FILE3="$TEST_DIR/prompt3.txt"
printf 'This will never submit.\n' > "$PROMPT_FILE3"
: > "$EVENTS_LOG"
rc=0
reprompt_inject "$STUCK_SESSION:coordinator" "$PROMPT_FILE3" || rc=$?

check "reprompt_inject returns non-zero when the retry also fails to confirm" "1" "$rc"

if grep -q 'coord.wake.resubmit' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "unconfirmed first Enter -> coord.wake.resubmit logged" "logged" "$got"

if grep -q 'coord.wake.submit_failed' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "still unconfirmed after retry -> coord.wake.submit_failed logged (not silent)" "logged" "$got"

tmux kill-session -t "$STUCK_SESSION" 2>/dev/null || true

heading "Test 4: shipped COMPACT_SUBMIT_SETTLE_SECS/COORD_BUSY_PATTERN defaults are wired up in llm-start.sh"
grep -q '^COMPACT_SUBMIT_SETTLE_SECS="\${COMPACT_SUBMIT_SETTLE_SECS:-1}"' "$LLM_START" \
    && got=present || got=missing
check "llm-start.sh defaults COMPACT_SUBMIT_SETTLE_SECS to a positive delay (issue #290 reuse)" "present" "$got"

grep -q '^COORD_BUSY_PATTERN=' "$LLM_START" && got=present || got=missing
check "llm-start.sh defines its own COORD_BUSY_PATTERN" "present" "$got"

echo ""
green "All llm-start.sh reprompt tests passed ($PASS checks)"
