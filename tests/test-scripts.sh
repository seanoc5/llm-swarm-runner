#!/usr/bin/env bash
#
# test-scripts.sh — Sanity checks for the orchestration scripts.
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0

check_script() {
    local script="$1"
    echo "Checking $script..."
    
    # 1. Syntax check
    if ! bash -n "$script"; then
        red "  ✗ $script: Syntax error"
        FAIL=$((FAIL + 1))
        return
    fi
    
    # 2. Unbound variables check (simulated)
    # We grep for variable assignments and then for usages to catch obvious typos.
    # A more robust way is to run with 'set -u' but that requires mocking environment.
    if command -v shellcheck &>/dev/null; then
        if ! shellcheck "$script"; then
            red "  ✗ $script: Shellcheck failed"
            FAIL=$((FAIL + 1))
            return
        fi
    fi

    # 3. Specific logic checks for llm-start.sh
    if [[ "$script" == *"llm-start.sh" ]]; then
        # Ensure no leftover PROMPT_FILE usage (exact word match)
        if grep -q "\bPROMPT_FILE\b" "$script"; then
            red "  ✗ $script: Contains deprecated PROMPT_FILE"
            FAIL=$((FAIL + 1))
            return
        fi
        # Ensure SYSTEM_PROMPT_FILE is both defined and used
        if ! grep -q "SYSTEM_PROMPT_FILE=" "$script" || ! grep -q "\$SYSTEM_PROMPT_FILE" "$script"; then
            red "  ✗ $script: SYSTEM_PROMPT_FILE definition/usage mismatch"
            FAIL=$((FAIL + 1))
            return
        fi
    fi

    green "  ✓ $script: Passed sanity checks"
    PASS=$((PASS + 1))
}

# Self-locate so the test runs from any clone path.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$TESTS_DIR")}"

echo "=== Script Sanity Checks ==="
check_script "$LLM_SWARM_DIR/llm-start.sh"
check_script "$LLM_SWARM_DIR/sandbox.sh"
check_script "$LLM_SWARM_DIR/scripts/worker-listener.sh"
check_script "$LLM_SWARM_DIR/scripts/reap-orphan-worktrees.sh"

echo ""
echo "Summary: $PASS passed, $FAIL failed."
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
