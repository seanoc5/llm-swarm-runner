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
        # SC1091 is informational for dynamic source paths and should not
        # fail the suite. Keep warnings and errors as the quality gate.
        if ! shellcheck -S warning "$script"; then
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
check_script "$LLM_SWARM_DIR/scripts/coordinator-codex.sh"
check_script "$LLM_SWARM_DIR/scripts/worker-listener.sh"
check_script "$LLM_SWARM_DIR/scripts/reap-orphan-worktrees.sh"
check_script "$LLM_SWARM_DIR/scripts/kill-worktree.sh"
check_script "$LLM_SWARM_DIR/scripts/kill-finished-workers.sh"

# --- Functional: repurposed-worktree PR lookup (issue #97) ------------------
#
# reap-orphan-worktrees.sh used to key its PR-finalized check on
# fix/issue-N, derived from the wt-issue-N dirname. That breaks when a
# worktree is repurposed onto a different branch mid-life (checkout -B from
# a parked worker) — the dirname stays wt-issue-N forever, but the branch
# actually checked out (and its PR) is something else. This reproduces that
# scenario with a mocked `gh` (no network/auth needed) and asserts the
# script reaps based on the ACTUAL checked-out branch's PR state, not the
# dirname-derived one.
test_repurposed_worktree_reap() {
    local name="repurposed-worktree PR lookup"
    echo "Checking $name..."

    local tmproot
    tmproot="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmproot'" RETURN

    local upstream="$tmproot/upstream.git"
    local project="$tmproot/project"
    local wt="$tmproot/wt-issue-42"

    git -c init.defaultBranch=main init -q --bare "$upstream" || { red "  ✗ $name: bare init failed"; FAIL=$((FAIL + 1)); return; }
    git -c init.defaultBranch=main clone -q "$upstream" "$project" || { red "  ✗ $name: clone failed"; FAIL=$((FAIL + 1)); return; }
    (
        cd "$project" &&
        git config user.email test@example.com &&
        git config user.name "Test" &&
        echo x > x && git add x && git commit -qm initial &&
        git push -q origin main
    ) >/dev/null 2>&1 || { red "  ✗ $name: initial commit/push failed"; FAIL=$((FAIL + 1)); return; }

    git -C "$project" worktree add -q "$wt" -b fix/issue-42 >/dev/null 2>&1 || { red "  ✗ $name: worktree add failed"; FAIL=$((FAIL + 1)); return; }
    (
        cd "$wt" &&
        echo y > y && git add y && git commit -qm "issue-42 work" &&
        git push -q origin fix/issue-42
    ) >/dev/null 2>&1 || { red "  ✗ $name: fix/issue-42 setup failed"; FAIL=$((FAIL + 1)); return; }

    # Repurpose: same worktree dir, different branch (no new worktree
    # provisioned) — the pattern surfaced in issue #97.
    (
        cd "$wt" &&
        git checkout -q -B fix/something-else &&
        echo z > z && git add z && git commit -qm "different work" &&
        git push -q origin fix/something-else
    ) >/dev/null 2>&1 || { red "  ✗ $name: repurpose setup failed"; FAIL=$((FAIL + 1)); return; }

    # Fake `gh`: only fix/something-else (the ACTUAL branch) has a
    # finalized PR. fix/issue-42 (the dirname-derived branch) has none —
    # mirrors the real scenario where the original PR's branch is long
    # gone from origin.
    local fakebin="$tmproot/fakebin"
    mkdir -p "$fakebin"
    cat > "$fakebin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    printf 'fix/something-else\tMERGED\n'
    exit 0
fi
exit 1
FAKEGH
    chmod +x "$fakebin/gh"

    local out rc
    out="$(PATH="$fakebin:$PATH" "$LLM_SWARM_DIR/scripts/reap-orphan-worktrees.sh" \
            --dry-run --min-age-days 0 --project "$project" 2>&1)" && rc=0 || rc=$?

    if [ "$rc" -ne 0 ]; then
        red "  ✗ $name: script exited $rc"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! echo "$out" | grep -q "wt-issue-42.*reap"; then
        red "  ✗ $name: expected wt-issue-42 to be a reap candidate (checked wrong branch?)"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! echo "$out" | grep -q "fix/something-else"; then
        red "  ✗ $name: reap reasoning didn't reference the actual checked-out branch"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi

    green "  ✓ $name: Passed"
    PASS=$((PASS + 1))
}
test_repurposed_worktree_reap

echo ""
echo "Summary: $PASS passed, $FAIL failed."
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
