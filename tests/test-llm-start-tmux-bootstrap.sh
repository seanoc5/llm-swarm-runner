#!/usr/bin/env bash
#
# test-llm-start-tmux-bootstrap.sh — issue #555 self-review round 6: a
# brand-new swarm socket is bootstrapped with `-f /dev/null` (issue #550,
# to guarantee pane-base-index 0 for the watcher's `.0` pane targeting
# regardless of the operator's own ~/.tmux.conf) — but that also means the
# operator's own customizations, including the project's Ctrl-Z
# install-tmux-binding.sh binding, never load on that socket at all.
# llm-start.sh's fix: an explicit `tmux source-file "$TMUX_CONF"` right
# after the bootstrap new-session call recovers the operator's conf one
# time, with the pre-existing unconditional `pane-base-index 0` (which
# runs later, every invocation) still re-asserting the issue #550
# guarantee afterwards.
#
# This test extracts the three real commands by exact text (sed, not a
# hand-retyped copy — same technique test-llm-start-reprompt.sh's
# extract_fn uses for functions) so it stays coupled to the shipped code,
# and replays them verbatim, in order, against a real throwaway tmux
# socket with a fake TMUX_CONF standing in for ~/.tmux.conf. The shipped
# lines never pass -L themselves (the real swarm socket is selected via
# $TMUX_HOST/ambient state, not a flag on these specific calls), so a
# `tmux` shell function redirects their bare `tmux` calls onto the
# throwaway socket without editing the extracted text itself; every OTHER
# tmux call this test makes on its own behalf goes through `command tmux`
# explicitly instead, so the two never fight over -L.
#
# Tests 4-5 (self-review round 8) cover the follow-on bug the round-6 fix
# itself opened up: something else re-sourcing the operator's conf on an
# ALREADY-LIVE swarm socket (install-tmux-binding.sh does exactly this,
# intentionally, on every running swarm-* socket) can flip the global
# pane-base-index back to whatever that conf says, for any window created
# after that point — until llm-start.sh next happens to run and
# re-assert it. llm-start.sh's coordinator window and provision-worker.sh's
# iss-N windows now both set a WINDOW-level override at creation time
# instead, which takes precedence over the global value for that window's
# whole lifetime and so can't drift later no matter what re-sources the
# conf next.
#
# Requires: tmux.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_START="$SCRIPT_DIR/../llm-start.sh"
[ -x "$LLM_START" ] || red "llm-start.sh not executable: $LLM_START"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"

TEST_DIR=$(mktemp -d -t llm-start-tmux-bootstrap-XXXXXX)
SOCK="test-bootstrap-$$"
cleanup() { command tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT

extract_line() {
    local pattern="$1"
    grep -F "$pattern" "$LLM_START" || red "could not find expected line in llm-start.sh (has it been rewritten?): $pattern"
}

NEW_SESSION_LINE="$(extract_line 'tmux -f /dev/null new-session')"
SOURCE_FILE_LINE="$(extract_line 'tmux source-file "$TMUX_CONF"')"
PANE_BASE_LINE="$(extract_line 'tmux set-option -g pane-base-index 0')"
COORD_WINDOW_OVERRIDE_LINE="$(extract_line 'tmux set-window-option -t "$SESSION_NAME:coordinator" pane-base-index 0')"

PROVISION_WORKER="$SCRIPT_DIR/../scripts/provision-worker.sh"
[ -x "$PROVISION_WORKER" ] || red "provision-worker.sh not executable: $PROVISION_WORKER"
ISS_WINDOW_OVERRIDE_LINE="$(grep -F 'tmux set-window-option -t "$SESSION_NAME:iss-$ISSUE" pane-base-index 0' "$PROVISION_WORKER" \
    || red "could not find expected line in provision-worker.sh (has it been rewritten?): the iss-\$ISSUE pane-base-index override")"

PASS=0
check() {
    local desc="$1" expect="$2" got="$3"
    if [ "$expect" = "$got" ]; then
        green "$desc"; PASS=$((PASS + 1))
    else
        red "$desc (expected [$expect] got [$got])"
    fi
}

# ─────────────────────────── ordering in the source file ───────────────────
heading "Test 1: source-file call sits between the bootstrap new-session and the pane-base-index re-assertion"
NEW_SESSION_LN=$(grep -nF 'tmux -f /dev/null new-session' "$LLM_START" | head -1 | cut -d: -f1)
SOURCE_FILE_LN=$(grep -nF 'tmux source-file "$TMUX_CONF"' "$LLM_START" | head -1 | cut -d: -f1)
PANE_BASE_LN=$(grep -nF 'tmux set-option -g pane-base-index 0' "$LLM_START" | head -1 | cut -d: -f1)
if [ "$NEW_SESSION_LN" -lt "$SOURCE_FILE_LN" ] && [ "$SOURCE_FILE_LN" -lt "$PANE_BASE_LN" ]; then
    got=ordered
else
    got=unordered
fi
check "new-session -> source-file -> pane-base-index 0, in that order" "ordered" "$got"

# ─────────────────────────── behavioral replay on real tmux ────────────────
heading "Test 2: operator's ~/.tmux.conf customizations apply, but pane-base-index 0 still wins"

# Fake operator conf: sets pane-base-index to 1 (the exact footgun #550
# fixed) and a custom global option standing in for "any customization" a
# real ~/.tmux.conf (including install-tmux-binding.sh's Ctrl-Z block)
# would set.
TMUX_CONF="$TEST_DIR/fake.tmux.conf"
cat > "$TMUX_CONF" <<'CONF'
set -g pane-base-index 1
set -g @operator-customization "loaded"
CONF

# Redirect the extracted lines' own bare `tmux` calls onto the throwaway
# socket, unmodified otherwise. SESSION_NAME/TMUX_ENV_OPTS match the
# variable names the real lines reference.
tmux() { command tmux -L "$SOCK" "$@"; }
SESSION_NAME="probe"
TMUX_ENV_OPTS=()

eval "$NEW_SESSION_LINE"
eval "$SOURCE_FILE_LINE"
eval "$PANE_BASE_LINE"

got="$(command tmux -L "$SOCK" show-options -g pane-base-index 2>/dev/null | awk '{print $2}')"
check "pane-base-index still forced to 0 despite operator conf setting 1" "0" "${got:-missing}"

got="$(command tmux -L "$SOCK" show-options -g @operator-customization 2>/dev/null | awk '{print $2}')"
check "operator's other conf customizations DO apply (source-file ran)" 'loaded' "${got:-missing}"

# ─────────────────────────── missing conf doesn't error ────────────────────
heading "Test 3: a missing ~/.tmux.conf is a no-op, not an error"
command tmux -L "$SOCK" kill-server 2>/dev/null || true
TMUX_CONF="$TEST_DIR/does-not-exist.conf"

eval "$NEW_SESSION_LINE"
set +e
eval "$SOURCE_FILE_LINE"
rc=$?
set -e
check "source-file guard exits 0 even when TMUX_CONF doesn't exist" "0" "$rc"

got="$(command tmux -L "$SOCK" show-options -g pane-base-index 2>/dev/null | awk '{print $2}')"
# Before the belt-and-suspenders line runs, this is just tmux's own
# compiled-in default (0) — nothing was sourced to set it either way.
check "no stray pane-base-index leaks in from a nonexistent conf" "0" "${got:-0}"

# ──────────────────── window-level override survives later drift ──────────
heading "Test 4: the coordinator window's pane-base-index override survives a LATER global drift (self-review round 8 finding)"

command tmux -L "$SOCK" kill-server 2>/dev/null || true
TMUX_CONF="$TEST_DIR/does-not-exist.conf"
eval "$NEW_SESSION_LINE"
eval "$COORD_WINDOW_OVERRIDE_LINE"

got="$(command tmux -L "$SOCK" list-panes -t "probe:coordinator" -F '#{pane_index}' 2>/dev/null)"
check "coordinator pane starts at index 0" "0" "${got:-missing}"

# Simulate something else (install-tmux-binding.sh) re-sourcing an
# operator conf that sets pane-base-index 1 on this ALREADY-LIVE socket —
# the exact round-8 scenario, with no llm-start.sh re-run in between.
command tmux -L "$SOCK" set-option -g pane-base-index 1
got="$(command tmux -L "$SOCK" list-panes -t "probe:coordinator" -F '#{pane_index}' 2>/dev/null)"
check "coordinator's own window-level override is unaffected by the later global drift" "0" "${got:-missing}"

heading "Test 5: provision-worker.sh's iss-N window gets the same per-window override"

command tmux -L "$SOCK" new-window -d -t probe -n "iss-908" 'sleep 300'
SESSION_NAME=probe ISSUE=908
eval "$ISS_WINDOW_OVERRIDE_LINE"

got="$(command tmux -L "$SOCK" list-panes -t "probe:iss-908" -F '#{pane_index}' 2>/dev/null)"
check "iss-908 pane starts at index 0 despite the global drift set in Test 4" "0" "${got:-missing}"

command tmux -L "$SOCK" set-option -g pane-base-index 1
got="$(command tmux -L "$SOCK" list-panes -t "probe:iss-908" -F '#{pane_index}' 2>/dev/null)"
check "iss-908's own window-level override is also unaffected by a later global drift" "0" "${got:-missing}"

echo ""
green "All llm-start.sh tmux-bootstrap tests passed ($PASS checks)"
