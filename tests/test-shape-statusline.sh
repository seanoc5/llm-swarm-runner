#!/usr/bin/env bash
#
# test-shape-statusline.sh — Non-LLM shape tests for
# statusline-with-context.sh (issue #194; hardened in PR #168's review
# cycle, see commit cca369b).
#
# Two real crashers were found and fixed there:
#   - context_window_size:0    → division by zero under set -u
#   - context_window_size:"1M" → non-numeric arithmetic under set -u
# Neither is pinned by an automated test — this file exists to pin them,
# plus the never-fail contract (jq missing, malformed JSON, empty stdin)
# and the per-user probe path (moved off the shared, world-readable
# /tmp/claude-statusline-last.json — see cca369b).
#
# No network, no tokens: this is a pure stdin-in/stdout-out shape test.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="$SCRIPT_DIR/../scripts/statusline-with-context.sh"
[ -x "$STATUSLINE" ] || red "not executable: $STATUSLINE"

TEST_DIR=$(mktemp -d -t shape-statusline-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Isolate probe writes to our TEST_DIR — never let this test touch a real
# per-user XDG_RUNTIME_DIR or shared /tmp.
export XDG_RUNTIME_DIR="$TEST_DIR/runtime"
mkdir -p "$XDG_RUNTIME_DIR"
UID_FOR_PROBE="${UID:-$(id -u)}"
EXPECTED_PROBE="$XDG_RUNTIME_DIR/claude-statusline-$UID_FOR_PROBE.json"

run_ok() {
    # run_ok <label> <payload>
    local label="$1" payload="$2"
    local out rc
    out=$(printf '%s' "$payload" | "$STATUSLINE" 2>"$TEST_DIR/stderr.log") && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || red "$label: expected exit 0, got $rc (stderr: $(cat "$TEST_DIR/stderr.log"))"
    [ -n "$out" ] || red "$label: expected non-empty output"
    green "$label: exit 0, non-empty output ($out)"
}

# ============================================================================
heading "Test 1: valid payload"
# ============================================================================
run_ok "valid payload" '{"model":{"display_name":"claude-sonnet-5"},"workspace":{"current_dir":"/opt/work/foo"},"context_window":{"context_window_size":1000000,"total_input_tokens":195000}}'

# ============================================================================
heading "Test 2: context_window_size:0 — the division-by-zero crasher"
# ============================================================================
run_ok "context_window_size:0" '{"model":"claude-opus-4-8","context_window":{"context_window_size":0,"total_input_tokens":500}}'

# ============================================================================
heading "Test 3: context_window_size:\"1M\" — the non-numeric crasher"
# ============================================================================
run_ok 'context_window_size:"1M"' '{"model":"claude-opus-4-8","context_window":{"context_window_size":"1M","total_input_tokens":500}}'

# ============================================================================
heading "Test 4: empty stdin"
# ============================================================================
run_ok "empty stdin" ''

# ============================================================================
heading "Test 5: malformed JSON"
# ============================================================================
run_ok "malformed JSON" '{not json at all'

# ============================================================================
heading "Test 6: jq missing from PATH"
# ============================================================================
NOJQ_BIN="$TEST_DIR/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in cat mktemp mv rm dirname; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || red "host is missing required tool: $tool"
    ln -sf "$tool_path" "$NOJQ_BIN/$tool"
done
if [ -x "$NOJQ_BIN/jq" ]; then
    red "sanity check failed: jq leaked into the stub PATH"
fi
# Resolve bash's absolute path first: `PATH=X bash ...` looks up "bash"
# itself in the *new* PATH X, so a bare `bash` here would 127 before ever
# reaching the script under test.
BASH_BIN="$(command -v bash)"
out=$(printf '%s' '{"model":"claude-sonnet-5"}' | PATH="$NOJQ_BIN" "$BASH_BIN" "$STATUSLINE" 2>"$TEST_DIR/stderr.log") && rc=0 || rc=$?
[ "$rc" -eq 0 ] || red "jq-missing: expected exit 0, got $rc (stderr: $(cat "$TEST_DIR/stderr.log"))"
[ -n "$out" ] || red "jq-missing: expected non-empty output (degraded fields ok)"
green "jq missing from PATH: exit 0, non-empty output ($out)"

# ============================================================================
heading "Test 7: probe file lands at the per-user path, never the shared default"
# ============================================================================
rm -f "$EXPECTED_PROBE"
printf '%s' '{"model":"claude-sonnet-5"}' | "$STATUSLINE" >/dev/null
[ -f "$EXPECTED_PROBE" ] || red "expected probe at $EXPECTED_PROBE, not found"
[ ! -e "/tmp/claude-statusline-last.json" ] || red "SECURITY REGRESSION: shared /tmp/claude-statusline-last.json was written"
green "probe written to per-user path $EXPECTED_PROBE; shared /tmp path untouched"

# ============================================================================
heading "All statusline shape tests passed"
# ============================================================================
green "never-fail contract (valid/zero/string-total/empty/malformed/no-jq) + per-user probe path"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
