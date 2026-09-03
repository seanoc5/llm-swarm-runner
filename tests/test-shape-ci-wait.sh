#!/usr/bin/env bash
#
# test-shape-ci-wait.sh — Non-LLM shape tests for scripts/ci-wait.sh (#297):
# the CONFLICTING/DIRTY mergeability short-circuit, plus the green/red/
# timeout exit codes from the bounded `gh pr checks` poll. `gh` is stubbed
# via a PATH override so no network/GitHub access is needed.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_WAIT="$SCRIPT_DIR/../scripts/ci-wait.sh"
[ -x "$CI_WAIT" ] || red "not executable: $CI_WAIT"

TEST_DIR=$(mktemp -d -t shape-ci-wait-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

PASS=0
check() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        green "$desc"
        PASS=$((PASS + 1))
    else
        red "$desc"
    fi
}

# ─────────────────────────── gh stub ────────────────────────────────────────

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "pr view")
        n=0
        if [ -f "${GH_CALL_COUNT_FILE:-/dev/null}" ]; then n="$(cat "$GH_CALL_COUNT_FILE")"; fi
        n=$((n + 1))
        [ -n "${GH_CALL_COUNT_FILE:-}" ] && echo "$n" > "$GH_CALL_COUNT_FILE"
        if [ "$n" = "1" ] && [ "${GH_VIEW_UNKNOWN_FIRST:-0}" = "1" ]; then
            echo '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefOid":"deadbeef"}'
        else
            echo "{\"mergeable\":\"${GH_VIEW_MERGEABLE:-MERGEABLE}\",\"mergeStateStatus\":\"${GH_VIEW_STATE:-CLEAN}\",\"headRefOid\":\"deadbeef\"}"
        fi
        exit 0 ;;
    "pr checks")
        exit "${GH_CHECKS_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"

# ─────────────────────────── Test 1: CONFLICTING ⇒ exit 3, no checks polled ─

heading "Test 1: CONFLICTING/DIRTY PR short-circuits before any checks poll"
rc=0
out="$(GH_VIEW_MERGEABLE=CONFLICTING GH_VIEW_STATE=DIRTY GH_CHECKS_RC=0 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 3 on CONFLICTING/DIRTY" '[ "$rc" -eq 3 ]'
check "message names the rebase-first remedy" 'grep -qi "rebase" <<<"$out"'

# ─────────────────────────── Test 2: mergeable + checks green ⇒ exit 0 ──────

heading "Test 2: mergeable PR, checks green → exit 0"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 0 on green checks" '[ "$rc" -eq 0 ]'

# ─────────────────────────── Test 3: mergeable + checks failing ⇒ exit 1 ────

heading "Test 3: mergeable PR, checks failing → exit 1"
rc=0
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=1 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "exits 1 on failing checks" '[ "$rc" -eq 1 ]'

# ─────────────────────────── Test 4: mergeable + checks pending ⇒ timeout ───

heading "Test 4: mergeable PR, checks pending past deadline → exit 2 (timeout)"
rc=0
start="$(date -u +%s)"
out="$(GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=8 \
    CI_WAIT_POLL_SECONDS=1 "$CI_WAIT" 42 2 2>&1)" || rc=$?
elapsed=$(( $(date -u +%s) - start ))
check "exits 2 on timeout" '[ "$rc" -eq 2 ]'
check "message says timed out" 'grep -qi "timed out" <<<"$out"'
check "actually waited close to the deadline (not an instant false-positive)" '[ "$elapsed" -ge 2 ]'

# ─────────────────────────── Test 5: UNKNOWN mergeability retried once ──────

heading "Test 5: UNKNOWN mergeable on first read is retried, not treated as conflicting"
rc=0
COUNT_FILE="$TEST_DIR/gh-call-count"
rm -f "$COUNT_FILE"
out="$(GH_CALL_COUNT_FILE="$COUNT_FILE" GH_VIEW_UNKNOWN_FIRST=1 \
    GH_VIEW_MERGEABLE=MERGEABLE GH_VIEW_STATE=CLEAN GH_CHECKS_RC=0 \
    "$CI_WAIT" 42 5 2>&1)" || rc=$?
check "resolves to success once mergeability settles" '[ "$rc" -eq 0 ]'
check "pr view was called at least twice (initial + retry)" '[ "$(cat "$COUNT_FILE")" -ge 2 ]'

# ─────────────────────────── Test 6: usage error ─────────────────────────────

heading "Test 6: no PR# argument → usage error"
rc=0
"$CI_WAIT" >/dev/null 2>&1 || rc=$?
check "exits 4 with no arguments" '[ "$rc" -eq 4 ]'

heading "Results: $PASS checks passed"
green "All checks passed."
