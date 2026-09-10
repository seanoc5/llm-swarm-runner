#!/usr/bin/env bash
#
# test-shape-pr-next-steps.sh — the actionable half of the swarm's PR
# warning comments (issue #397).
#
# Background: requeue.sh posts a `SWARM_PENDING_BRIEF: queued` comment so a
# human merging from GitHub does not merge past an in-flight fix (#375).
# The comment stated the problem but not the move, and its most valuable
# fact — whether ANYTHING is polling the brief — was computed and then
# printed only to a terminal nobody reads. When no listener exists,
# "wait for the cleared comment" is advice that never resolves.
#
# What is asserted here is the decision content, not the plumbing (the
# end-to-end posting path is tests/test-pr-brief-marker.sh):
#
#   listener_state    → the four delivery states, tmux stubbed on PATH
#   delivery_outlook  → each state yields a distinct, verdict-bearing line
#   brief_excerpt     → truncation, fence defanging, opt-out, missing file
#   salvaged_excerpt  → inbox preferred over processing (the bigger loss)
#
# Functions are extracted with sed rather than hand-copied, so a rename or
# a contract change fails here instead of drifting. No tmux server, no
# network, no gh.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUEUE="$SCRIPT_DIR/../scripts/requeue.sh"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
[ -r "$REQUEUE" ] || red "requeue.sh not readable: $REQUEUE"
[ -r "$KILL_WT" ] || red "kill-worktree.sh not readable: $KILL_WT"

TEST_DIR=$(mktemp -d -t shape-next-steps-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract() {
    local fn="$1" file="$2" body
    body="$(sed -n "/^$fn() {/,/^}/p" "$file")"
    [ -n "$body" ] || red "could not extract '$fn' from $file — renamed?"
    eval "$body"
}
extract listener_state    "$REQUEUE"
extract delivery_outlook  "$REQUEUE"
extract brief_excerpt     "$REQUEUE"
extract salvaged_excerpt  "$KILL_WT"

# ───────────────────────────── tmux stub on PATH ────────────────────────────
# Driven by TMUX_HAS_SESSION / TMUX_WINDOWS / TMUX_PANE_CMD so each state is
# reachable without a live server.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    has-session)  [ "${TMUX_HAS_SESSION:-0}" = "1" ] && exit 0 || exit 1 ;;
    list-windows) printf '%s\n' ${TMUX_WINDOWS:-} ;;
    list-panes)   [ -n "${TMUX_PANE_CMD:-}" ] && echo "$TMUX_PANE_CMD" ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

# ══════════════════════════════ listener_state ══════════════════════════════

heading "Test 1: no session / no listener window → nothing is polling"
export TMUX_HAS_SESSION=0 TMUX_WINDOWS="" TMUX_PANE_CMD=""
[ "$(listener_state "" iss-90)" = "no-session" ] \
    || red "empty session name must be no-session, got: $(listener_state "" iss-90)"
[ "$(listener_state llm-proj iss-90)" = "no-session" ] \
    || red "dead session must be no-session, got: $(listener_state llm-proj iss-90)"
export TMUX_HAS_SESSION=1 TMUX_WINDOWS="coordinator util"
[ "$(listener_state llm-proj iss-90)" = "no-listener" ] \
    || red "session with zero iss-* windows must be no-listener, got: $(listener_state llm-proj iss-90)"
green "no-session and no-listener detected — the two states where waiting never resolves"

heading "Test 2: live listener at a shell → live-idle; inside an agent → live-busy"
export TMUX_HAS_SESSION=1 TMUX_WINDOWS="coordinator iss-90" TMUX_PANE_CMD="bash"
[ "$(listener_state llm-proj iss-90)" = "live-idle" ] \
    || red "shell pane must be live-idle, got: $(listener_state llm-proj iss-90)"
export TMUX_PANE_CMD="claude"
[ "$(listener_state llm-proj iss-90)" = "live-busy:claude" ] \
    || red "agent pane must be live-busy:<cmd>, got: $(listener_state llm-proj iss-90)"
# An unresolvable window name (worktree not named wt-issue-N) keeps the
# long-standing fast-path assumption rather than inventing a fifth state.
export TMUX_PANE_CMD=""
[ "$(listener_state llm-proj "")" = "live-idle" ] \
    || red "unresolvable window name must fall back to live-idle, got: $(listener_state llm-proj "")"
green "live-idle / live-busy:<cmd> distinguished; unknown window falls back to the fast path"

# ═════════════════════════════ delivery_outlook ═════════════════════════════

heading "Test 3: every state produces a distinct, verdict-bearing sentence"
declare -A seen=()
for st in live-idle live-busy:claude no-listener no-session; do
    out="$(delivery_outlook "$st" llm-proj iss-90)"
    [ -n "$out" ] || red "delivery_outlook produced nothing for state '$st'"
    [ -z "${seen[$out]:-}" ] || red "state '$st' renders identically to another state"
    seen["$out"]=1
done
green "four states, four distinct sentences"

heading "Test 4: the two 'nothing is polling' states say so, and say do not wait"
for st in no-listener no-session; do
    out="$(delivery_outlook "$st" llm-proj iss-90)"
    printf '%s' "$out" | grep -q 'nothing is polling this brief' \
        || red "state '$st' must say nothing is polling: $out"
    printf '%s' "$out" | grep -q 'Do not just wait' \
        || red "state '$st' must carry an explicit do-not-wait verdict: $out"
done
# The mirror image: when a listener really is idle, waiting IS correct and
# the comment must not send the reader chasing a non-problem.
out="$(delivery_outlook live-idle llm-proj iss-90)"
printf '%s' "$out" | grep -q 'Waiting is the right move' \
    || red "live-idle must bless waiting: $out"
printf '%s' "$out" | grep -q 'iss-90' || red "live-idle should name the window: $out"
# live-busy is the ambiguous one (issue #313 parking) — it must hedge
# toward checking rather than either extreme.
out="$(delivery_outlook live-busy:claude llm-proj iss-90)"
printf '%s' "$out" | grep -q 'confirm a new commit before merging' \
    || red "live-busy must ask for commit confirmation: $out"
printf '%s' "$out" | grep -q 'claude' || red "live-busy should name the blocking process: $out"
green "verdicts match the state: wait / check / do-not-wait"

# ══════════════════════════════ brief_excerpt ═══════════════════════════════

heading "Test 5: excerpt truncates and reports how much it dropped"
seq 1 50 | sed 's/^/line /' > "$TEST_DIR/long-brief.md"
out="$(SWARM_PR_BRIEF_LINES=5 brief_excerpt "$TEST_DIR/long-brief.md")"
printf '%s' "$out" | grep -q '^line 5$'  || red "expected the 5th line to survive: $out"
printf '%s' "$out" | grep -q 'line 6'    && red "expected line 6 to be cut at max_lines=5"
printf '%s' "$out" | grep -q 'truncated (45 more lines)' \
    || red "expected an explicit truncation count: $out"
green "head-of-brief with an honest truncation count"

heading "Test 6: a brief carrying its own six-backtick fence cannot break out"
{ printf '%s\n' '``````' 'pretend this closes the block' '``````'; } > "$TEST_DIR/fence-brief.md"
out="$(brief_excerpt "$TEST_DIR/fence-brief.md")"
printf '%s' "$out" | grep -q '^``````$' \
    && red "a bare six-backtick line survived — it would close the comment's own fence: $out"
printf '%s' "$out" | grep -q '\[fence\]' || red "expected the fence run to be defanged: $out"
green "six-or-more backtick runs defanged before they reach the comment"

heading "Test 7: excerpt is opt-out and silent on an unreadable brief"
echo "visible" > "$TEST_DIR/ok-brief.md"
[ -n "$(brief_excerpt "$TEST_DIR/ok-brief.md")" ] || red "default must emit the excerpt"
[ -z "$(SWARM_PR_BRIEF_EXCERPT=0 brief_excerpt "$TEST_DIR/ok-brief.md")" ] \
    || red "SWARM_PR_BRIEF_EXCERPT=0 must suppress it entirely"
[ -z "$(brief_excerpt "$TEST_DIR/nope.md")" ] || red "missing file must yield nothing, not an error"
green "SWARM_PR_BRIEF_EXCERPT=0 suppresses; a missing brief degrades to silence"

# ═════════════════════════════ salvaged_excerpt ═════════════════════════════

heading "Test 8: salvage excerpt prefers inbox/ (never delivered) over processing/"
SALV="$TEST_DIR/salvaged/iss-90"
mkdir -p "$SALV/inbox" "$SALV/processing" "$SALV/outbox"
echo "the undelivered inbox brief" > "$SALV/inbox/a.md"
echo "the half-done processing brief" > "$SALV/processing/b.md"
out="$(salvaged_excerpt "$SALV")"
printf '%s' "$out" | grep -q 'undelivered inbox brief' \
    || red "expected inbox/ to win: $out"
printf '%s' "$out" | grep -q 'processing brief' && red "processing/ should not appear while inbox/ has a brief"
# With inbox empty it must fall through rather than going silent — an
# orphaned processing/ brief is still work that never landed.
rm "$SALV/inbox/a.md"
printf '%s' "$(salvaged_excerpt "$SALV")" | grep -q 'processing brief' \
    || red "expected fallback to processing/ once inbox/ is empty"
rm "$SALV/processing/b.md"
[ -z "$(salvaged_excerpt "$SALV")" ] || red "an empty salvage dir must yield nothing"
green "inbox → processing → outbox precedence; empty salvage degrades to silence"

printf '\n\033[1;32mAll checks passed.\033[0m\n'
