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
for fn in log_event reprompt_last_pane_line reprompt_confirm_submitted reprompt_composer_dirty reprompt_retry_safe reprompt_inject; do
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
# issue #422 — must match the shipped default (chrome catalog: "※ recap:"
# lines and the session-resume picker; see llm-start.sh's
# reprompt_composer_dirty header comment).
REPROMPT_CHROME_PATTERN='^※ recap:|Resume this session with|^[0-9]+\.[[:space:]]*Resume from'

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
# Stand-in for a live Claude Code REPL: prints an idle prompt plus a
# genuinely-empty composer line, reads one line at a time, and on any
# non-empty line simulates a brief turn (busy indicator, then redraws back
# to idle). The composer line is rendered as "❯ " (leading marker + a
# single trailing space, nothing else) — issue #422's pre-paste dirty
# check trims that to empty via reprompt_last_pane_line's existing
# leading-chrome strip, exactly like a real empty Claude Code composer;
# see reprompt_composer_dirty's header comment.
FAKE_REPL="$TEST_DIR/fake-claude-repl.sh"
cat > "$FAKE_REPL" <<'REPL'
#!/usr/bin/env bash
render_idle() {
    echo "idle-prompt >"
    printf '\xe2\x9d\xaf \n'
}
render_idle
while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "✻ Considering… (esc to interrupt)"
    sleep 2
    clear
    render_idle
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

heading "Test 1b: reprompt_composer_dirty — pre-existing draft, wake deferred and never pasted (issue #422)"
# Static fixture: renders a composer that already holds unsubmitted text
# from the very start (the corpusminder-spring incident's shape — a human
# was mid-draft before any wake ever fired) and never changes it
# regardless of what arrives on stdin. reprompt_inject must detect this
# BEFORE touching tmux at all — no load-buffer, no paste-buffer, no Enter
# — so this fixture never needs to distinguish "our paste" from anything
# else; it just has to prove nothing changed.
FAKE_REPL_DIRTY="$TEST_DIR/fake-repl-dirty.sh"
cat > "$FAKE_REPL_DIRTY" <<'REPL'
#!/usr/bin/env bash
render() {
    printf '\033[2J\033[H'
    echo "idle-prompt >"
    echo "❯ pre-existing unsent human draft"
}
render
while IFS= read -r line; do
    render
done
REPL
chmod +x "$FAKE_REPL_DIRTY"

DIRTY_SESSION="${SESSION_NAME}-dirty"
tmux new-session -d -s "$DIRTY_SESSION" -n coordinator 2>/dev/null
sleep 0.3   # see Test 1's identical comment on this settle delay
tmux send-keys -t "$DIRTY_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_DIRTY" Enter
check_eventually "dirty session: fake REPL foreground" "yes" \
    "pane_contains '$DIRTY_SESSION:coordinator' 'idle-prompt >'"

PROMPT_FILE1B="$TEST_DIR/prompt1b.txt"
printf 'This must never be pasted over a real draft.\n' > "$PROMPT_FILE1B"
: > "$EVENTS_LOG"
rc=0
reprompt_inject "$DIRTY_SESSION:coordinator" "$PROMPT_FILE1B" || rc=$?

check "reprompt_inject returns 2 (deferred) on a pre-existing dirty composer" "2" "$rc"

if grep -q 'coord.wake.skip' "$EVENTS_LOG" && grep -q 'reason=composer_dirty' "$EVENTS_LOG"; then
    got=logged
else
    got=missing
fi
check "dirty composer -> coord.wake.skip reason=composer_dirty logged" "logged" "$got"

if grep -qE 'coord\.wake\.(resubmit|submit_failed)' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "no paste attempted at all -> no resubmit/submit_failed logged" "absent" "$got"

check "the operator's draft is still there, untouched" "yes" \
    "$(pane_contains "$DIRTY_SESSION:coordinator" 'pre-existing unsent human draft')"
check "our prompt text never landed in the pane" "no" \
    "$(pane_contains "$DIRTY_SESSION:coordinator" 'never be pasted over')"

tmux kill-session -t "$DIRTY_SESSION" 2>/dev/null || true

heading "Test 1c: reprompt_composer_dirty — a coordinator mid-turn is not a draft, wake still lands (issue #422 self-review finding)"
# Fixture that renders ONLY busy/spinner chrome and ignores all input —
# models a wake landing while the coordinator is mid-turn (the pre-#422
# behavior this PR must NOT regress): Claude Code queues a pasted
# follow-up during a busy turn ("Press up to edit queued messages"), and
# reprompt_confirm_submitted already treats a busy match as confirmed-
# submitted for exactly that reason. Without checking COORD_BUSY_PATTERN
# FIRST, reprompt_composer_dirty would misread the spinner/status line
# itself as "a draft" and defer a wake that used to land fine.
FAKE_REPL_BUSY="$TEST_DIR/fake-repl-busy.sh"
cat > "$FAKE_REPL_BUSY" <<'REPL'
#!/usr/bin/env bash
render() {
    printf '\033[2J\033[H'
    echo "✻ Considering… (esc to interrupt)"
}
render
while IFS= read -r line; do
    render
done
REPL
chmod +x "$FAKE_REPL_BUSY"

BUSY_SESSION="${SESSION_NAME}-busy"
tmux new-session -d -s "$BUSY_SESSION" -n coordinator 2>/dev/null
sleep 0.3   # see Test 1's identical comment on this settle delay
tmux send-keys -t "$BUSY_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_BUSY" Enter
check_eventually "busy session: fake REPL foreground" "yes" \
    "pane_contains '$BUSY_SESSION:coordinator' 'esc to interrupt'"

PROMPT_FILE1C="$TEST_DIR/prompt1c.txt"
printf 'Worker(s) just finished. Triage their outcomes.\n' > "$PROMPT_FILE1C"
: > "$EVENTS_LOG"
rc=0
reprompt_inject "$BUSY_SESSION:coordinator" "$PROMPT_FILE1C" || rc=$?

check "reprompt_inject queues into a busy (mid-turn) coordinator instead of deferring" "0" "$rc"

if grep -qE 'coord\.wake\.skip.*reason=composer_dirty' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "a busy turn must NOT be misread as a dirty composer" "absent" "$got"

tmux kill-session -t "$BUSY_SESSION" 2>/dev/null || true

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

heading "Test 2b: reprompt_inject — eaten-first-Enter retry survives a WRAPPED long prompt (issue #422 self-review finding)"
# Same fake-repl-eatfirst.sh fixture as Test 2, but with a long single-line
# prompt (no embedded newline) in a pane fixed to a narrow 80-column width
# — the exact shape of the real default WAKE_PROMPT (~300 chars, one
# logical line). Without capture-pane -J in reprompt_last_pane_line, and
# without comparing against the prompt's LAST line in reprompt_retry_safe,
# this composer's rendered content soft-wraps across several pane rows and
# `tail -1` only ever sees the final wrapped fragment — which never starts
# with (or, pre-fix, matches) the full pasted text, so the eaten-first-
# Enter retry gets wrongly treated as "foreign content" and reprompt_inject
# returns 2 instead of 0. Reuses $FAKE_REPL_EATFIRST (already written to
# $TEST_DIR by Test 2, unchanged) in a fresh, fixed-width session.
EATFIRST_WRAP_SESSION="${SESSION_NAME}-eatfirst-wrap"
tmux new-session -d -s "$EATFIRST_WRAP_SESSION" -n coordinator -x 80 -y 24 2>/dev/null
sleep 0.3   # see Test 1's identical comment on this settle delay
tmux send-keys -t "$EATFIRST_WRAP_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_EATFIRST" Enter
check_eventually "eat-first-wrap session: fake REPL foreground" "yes" \
    "pane_contains '$EATFIRST_WRAP_SESSION:coordinator' 'idle-prompt >'"

PROMPT_FILE2B="$TEST_DIR/prompt2b.txt"
# ~290 chars, no trailing newline (see Test 2's identical comment on why)
# — comfortably wraps across multiple rows at 80 columns once rendered
# behind the "❯ " composer marker.
printf 'Worker(s) just finished. Triage their outcome JSONs in worktrees/.swarm/tasks/done/, then top up workers per the Initial Startup Checklist (compute AVAILABLE, count alive workers, fill open slots up to MAX_WORKERS subject to MAX_TMUX_WINDOWS).' > "$PROMPT_FILE2B"
: > "$EVENTS_LOG"
rc=0
reprompt_inject "$EATFIRST_WRAP_SESSION:coordinator" "$PROMPT_FILE2B" || rc=$?

check "reprompt_inject succeeds through the retry even when the composer wraps across rows" "0" "$rc"

if grep -q 'coord.wake.resubmit' "$EVENTS_LOG"; then got=logged; else got=missing; fi
check "wrapped composer: first Enter eaten -> coord.wake.resubmit logged" "logged" "$got"

if grep -qE 'coord\.wake\.skip.*reason=composer_dirty_after_paste' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "wrapped composer must NOT be misread as foreign content" "absent" "$got"

tmux kill-session -t "$EATFIRST_WRAP_SESSION" 2>/dev/null || true

heading "Test 3: reprompt_inject — composer clear pre-paste, then stuck post-paste -> coord.wake.submit_failed, not silent (issue #295 acceptance)"
# Starts with a genuinely EMPTY composer (so issue #422's pre-paste
# reprompt_composer_dirty check passes and the paste actually happens —
# this fixture is specifically testing the DIFFERENT, older bug: what
# happens once our own paste is in but never clears), then accumulates
# whatever it's fed and never submits it — every Enter is a no-op against
# the rendered text, modeling a race that neither settle nor a single
# retry can recover from. Must be LOGGED, not dropped silently.
FAKE_REPL_STUCK="$TEST_DIR/fake-repl-stuck.sh"
cat > "$FAKE_REPL_STUCK" <<'REPL'
#!/usr/bin/env bash
composer=""
render() {
    printf '\033[2J\033[H'
    echo "idle-prompt >"
    printf '\xe2\x9d\xaf %s\n' "$composer"
}
render
while IFS= read -r line; do
    [ -n "$line" ] && composer="$composer$line"
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

heading "Test 3b: reprompt_retry_safe — unrelated content after paste suppresses the blind retry-Enter (issue #422)"
# Starts with a genuinely EMPTY composer (paste proceeds), but as soon as
# ANY input lands, jams in unrelated text instead of what was actually
# pasted — modeling an operator's own draft appearing in the settle window
# right after our paste, or any other TUI re-render our paste didn't
# cause. reprompt_inject must NOT blindly re-press Enter against that: the
# constraint is "only re-press Enter when the composer holds the pasted
# wake text and nothing else."
FAKE_REPL_FOREIGN="$TEST_DIR/fake-repl-foreign.sh"
cat > "$FAKE_REPL_FOREIGN" <<'REPL'
#!/usr/bin/env bash
composer=""
render() {
    printf '\033[2J\033[H'
    echo "idle-prompt >"
    printf '\xe2\x9d\xaf %s\n' "$composer"
}
render
while IFS= read -r line; do
    [ -n "$line" ] && composer="unrelated human text nothing to do with the wake"
    render
done
REPL
chmod +x "$FAKE_REPL_FOREIGN"

FOREIGN_SESSION="${SESSION_NAME}-foreign"
tmux new-session -d -s "$FOREIGN_SESSION" -n coordinator 2>/dev/null
sleep 0.3   # see Test 1's identical comment on this settle delay
tmux send-keys -t "$FOREIGN_SESSION:coordinator" "exec -a claude bash $FAKE_REPL_FOREIGN" Enter
check_eventually "foreign-content session: fake REPL foreground" "yes" \
    "pane_contains '$FOREIGN_SESSION:coordinator' 'idle-prompt >'"

PROMPT_FILE3B="$TEST_DIR/prompt3b.txt"
printf 'Top up workers per the Initial Startup Checklist.' > "$PROMPT_FILE3B"
: > "$EVENTS_LOG"
rc=0
reprompt_inject "$FOREIGN_SESSION:coordinator" "$PROMPT_FILE3B" || rc=$?

check "reprompt_inject returns 2 (deferred) rather than force-submitting foreign content" "2" "$rc"

if grep -q 'coord.wake.skip' "$EVENTS_LOG" && grep -q 'reason=composer_dirty_after_paste' "$EVENTS_LOG"; then
    got=logged
else
    got=missing
fi
check "foreign content after paste -> coord.wake.skip reason=composer_dirty_after_paste logged" "logged" "$got"

if grep -q 'coord.wake.resubmit' "$EVENTS_LOG"; then got=present; else got=absent; fi
check "retry-Enter never fires against content that isn't ours" "absent" "$got"

tmux kill-session -t "$FOREIGN_SESSION" 2>/dev/null || true

heading "Test 1d: reprompt_composer_dirty — Claude Code 2.1.x idle chrome is not a draft (issue #440)"
# Static fixtures shaped like a REAL Claude Code 2.1.x pane bottom, captured
# live 2026-09-19 (issue #440): a full-width ─ rule above and below the
# composer, a "ctx:" statusline, and the persistent mode footer UNDER the
# composer. Three composer states, all framework-generated except the last:
#   (a) empty composer with the dim placeholder  → must read clear
#   (b) dim suggested-next-prompt autofill        → must read clear
#   (c) text a human typed (no SGR at all)        → must read DIRTY
# Pre-#440, (a) and (b) read dirty — the footer was the last non-blank line
# on every idle pane — so ~99% of coordinator wakes deferred forever.
# The fixture renders real SGR (ESC[2m) so `capture-pane -e` sees exactly
# what the live TUI emits; tmux preserves the attribute across capture.
mk_cc_fixture() {   # <path> <composer-line-printf-fmt>
    cat > "$1" <<REPL
#!/usr/bin/env bash
render() {
    printf '\\033[2J\\033[H'
    echo "✻ Cogitated for 2m 45s · done 5:31 PM"
    echo "────────────────────────────────────────"
    printf '$2\\n'
    echo "────────────────────────────────────────"
    echo "  Fable 5 · corpusminder-spring · ctx: 197k/1M (20%)"
    echo "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
}
render
while IFS= read -r line; do render; done
REPL
    chmod +x "$1"
}
NBSP=$'\xc2\xa0'
mk_cc_fixture "$TEST_DIR/cc-empty.sh"  "❯${NBSP}\\033[2mTry \"edit <filepath> to...\"\\033[0m"
mk_cc_fixture "$TEST_DIR/cc-ghost.sh"  "❯${NBSP}\\033[2mmerge\\033[0m \\033[2mPR\\033[0m \\033[2m645"
mk_cc_fixture "$TEST_DIR/cc-typed.sh"  "❯${NBSP}nudge the coordinator to re-verify and un-draft it"

for case in empty:clear ghost:clear typed:dirty; do
    name="${case%%:*}"; want="${case##*:}"
    CC_SESSION="${SESSION_NAME}-cc-$name"
    tmux new-session -d -s "$CC_SESSION" -n coordinator -x 120 -y 20 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$CC_SESSION:coordinator" "exec -a claude bash $TEST_DIR/cc-$name.sh" Enter
    check_eventually "cc-$name: fixture foreground" "yes" \
        "pane_contains '$CC_SESSION:coordinator' 'shift+tab to cycle'"
    if reprompt_composer_dirty "$CC_SESSION:coordinator" "$COORD_BUSY_PATTERN"; then got=dirty; else got=clear; fi
    check "cc-$name composer reads $want (issue #440)" "$want" "$got"
    tmux kill-session -t "$CC_SESSION" 2>/dev/null || true
done

heading "Test 4: shipped COMPACT_SUBMIT_SETTLE_SECS/COORD_BUSY_PATTERN defaults are wired up in llm-start.sh"
grep -q '^COMPACT_SUBMIT_SETTLE_SECS="\${COMPACT_SUBMIT_SETTLE_SECS:-1}"' "$LLM_START" \
    && got=present || got=missing
check "llm-start.sh defaults COMPACT_SUBMIT_SETTLE_SECS to a positive delay (issue #290 reuse)" "present" "$got"

grep -q '^COORD_BUSY_PATTERN=' "$LLM_START" && got=present || got=missing
check "llm-start.sh defines its own COORD_BUSY_PATTERN" "present" "$got"

grep -q '^REPROMPT_CHROME_PATTERN=' "$LLM_START" && got=present || got=missing
check "llm-start.sh defines REPROMPT_CHROME_PATTERN for the pre-paste dirty check (issue #422)" "present" "$got"

echo ""
green "All llm-start.sh reprompt tests passed ($PASS checks)"
