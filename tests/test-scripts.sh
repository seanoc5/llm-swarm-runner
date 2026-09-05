#!/usr/bin/env bash
#
# test-scripts.sh — Sanity checks for the orchestration scripts.
set -euo pipefail

# The functional reap-orphan-worktrees.sh tests below build their fixture
# worktrees directly under $tmproot (flat layout: $tmproot/wt-issue-N) —
# pin the grouping so reap-orphan-worktrees.sh's swarm_worktree_parent()
# scans that same directory regardless of the shipped .env.example default
# (project, since issue #271) or an operator's project-grouped shell env.
export SWARM_WORKTREE_GROUPING=flat

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
    else
        red "  WARN: shellcheck not installed — lint gate SKIPPED for $script"
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

    # 4. Specific logic checks for sandbox.sh
    if [[ "$script" == *"sandbox.sh" ]]; then
        # Workers are foreground-only: the docker run env must disable claude
        # background Bash tasks, and the opts array must actually be expanded
        # in the docker run invocation (#301).
        if ! grep -q 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1' "$script"; then
            red "  ✗ $script: Missing CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 in worker env"
            FAIL=$((FAIL + 1))
            return
        fi
        if ! grep -q 'FOREGROUND_ONLY_ENV_OPTS\[@\]' "$script"; then
            red "  ✗ $script: FOREGROUND_ONLY_ENV_OPTS defined but not passed to docker run"
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

# --- Functional: dangling git registration reap (issue #225) ----------------
#
# After a Docker daemon restart (#217), a worktree directory can survive
# while its `.git` file's link back to the main repo's `.git/worktrees/<name>`
# administrative area is gone — every git command run INSIDE the worktree
# then fails with exit 128 (verified directly: both `git status --porcelain`
# and `git rev-parse --git-dir` do). Before this fix, reap-orphan-worktrees.sh
# had no branch for this — the clean-tree check and branch lookup would just
# misbehave/skip it forever. Reproduces the corruption by removing the main
# repo's admin dir for the worktree, then asserts the script reaps it by
# rm -rf'ing the worktree dir plus its own (already-gone) admin dir (not
# kill-worktree.sh's `git worktree remove`, which also needs a working
# registration) once the dirname-derived branch's PR is finalized.
test_dangling_registration_reap() {
    local name="dangling git registration reap"
    echo "Checking $name..."

    local tmproot
    tmproot="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmproot'" RETURN

    local project="$tmproot/project"
    local wt="$tmproot/wt-issue-747"

    git -c init.defaultBranch=main init -q "$project" || { red "  ✗ $name: init failed"; FAIL=$((FAIL + 1)); return; }
    (
        cd "$project" &&
        git config user.email test@example.com &&
        git config user.name "Test" &&
        echo x > x && git add x && git commit -qm initial
    ) >/dev/null 2>&1 || { red "  ✗ $name: initial commit failed"; FAIL=$((FAIL + 1)); return; }

    git -C "$project" worktree add -q -b fix/issue-747 "$wt" >/dev/null 2>&1 \
        || { red "  ✗ $name: worktree add failed"; FAIL=$((FAIL + 1)); return; }

    # Corrupt the registration by removing the main repo's administrative
    # area for this worktree — confirmed to reproduce the exact #217 symptom
    # (git -C "$wt" <anything> exits 128).
    rm -rf "$project/.git/worktrees/wt-issue-747"
    if git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
        red "  ✗ $name: fixture setup didn't actually corrupt the registration"
        FAIL=$((FAIL + 1))
        return
    fi

    # Fake `gh`: fix/issue-747's PR is MERGED (finalized) — reap-eligible.
    local fakebin="$tmproot/fakebin"
    mkdir -p "$fakebin"
    cat > "$fakebin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    printf 'fix/issue-747\tMERGED\n'
    exit 0
fi
exit 1
FAKEGH
    chmod +x "$fakebin/gh"

    # Dry-run first: must flag it as a reap candidate without touching it.
    local out rc
    out="$(PATH="$fakebin:$PATH" "$LLM_SWARM_DIR/scripts/reap-orphan-worktrees.sh" \
            --dry-run --min-age-days 0 --project "$project" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        red "  ✗ $name: dry-run exited $rc"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! echo "$out" | grep -q "wt-issue-747.*dangling.*reap"; then
        red "  ✗ $name: expected wt-issue-747 flagged as a dangling-registration reap candidate"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    [ -d "$wt" ] || { red "  ✗ $name: dry-run must not remove anything"; FAIL=$((FAIL + 1)); return; }

    # Real run: must actually remove the directory + local branch without
    # going anywhere near kill-worktree.sh's git-worktree-remove path.
    out="$(PATH="$fakebin:$PATH" "$LLM_SWARM_DIR/scripts/reap-orphan-worktrees.sh" \
            --yes --min-age-days 0 --project "$project" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        red "  ✗ $name: real run exited $rc"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if [ -d "$wt" ]; then
        red "  ✗ $name: dangling worktree directory was not removed"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if git -C "$project" show-ref --verify --quiet refs/heads/fix/issue-747; then
        red "  ✗ $name: local branch fix/issue-747 was not deleted"
        FAIL=$((FAIL + 1))
        return
    fi

    green "  ✓ $name: Passed"
    PASS=$((PASS + 1))
}
test_dangling_registration_reap

# --- Functional: dangling-worktree reap leaves sibling worktrees alone ------
#
# issue #328: three fand-app incidents (2026-09-01) traced live workers'
# `.git/worktrees/<name>` admin dirs disappearing mid-task — with no other
# logged cause — to reap_dangling()'s old cleanup step, a bare
# `git worktree prune`. That call scans and can remove EVERY worktree's
# admin dir in the registry, not just the one being reaped, so it was
# racing concurrent git activity in unrelated, still-active worktrees. The
# fix replaced it with a targeted `rm -rf` of exactly the dangling
# worktree's own admin dir (see reap_dangling's issue #328 comment). This
# test reaps one dangling worktree (wt-issue-747, PR merged) alongside a
# second, healthy, still-active-PR worktree (wt-issue-800) and asserts the
# healthy one's registration survives completely intact.
test_dangling_reap_ignores_sibling_worktree() {
    local name="dangling reap leaves sibling worktree's registration alone"
    echo "Checking $name..."

    local tmproot
    tmproot="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmproot'" RETURN

    local project="$tmproot/project"
    local wt747="$tmproot/wt-issue-747"
    local wt800="$tmproot/wt-issue-800"

    git -c init.defaultBranch=main init -q "$project" || { red "  ✗ $name: init failed"; FAIL=$((FAIL + 1)); return; }
    (
        cd "$project" &&
        git config user.email test@example.com &&
        git config user.name "Test" &&
        echo x > x && git add x && git commit -qm initial
    ) >/dev/null 2>&1 || { red "  ✗ $name: initial commit failed"; FAIL=$((FAIL + 1)); return; }

    git -C "$project" worktree add -q -b fix/issue-747 "$wt747" >/dev/null 2>&1 \
        || { red "  ✗ $name: worktree add (747) failed"; FAIL=$((FAIL + 1)); return; }
    git -C "$project" worktree add -q -b fix/issue-800 "$wt800" >/dev/null 2>&1 \
        || { red "  ✗ $name: worktree add (800) failed"; FAIL=$((FAIL + 1)); return; }

    # Corrupt only 747's registration — 800 stays a normal, healthy,
    # currently-checked-out worktree, standing in for a live worker.
    rm -rf "$project/.git/worktrees/wt-issue-747"
    if git -C "$wt747" rev-parse --git-dir >/dev/null 2>&1; then
        red "  ✗ $name: fixture setup didn't actually corrupt 747's registration"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! git -C "$wt800" rev-parse --git-dir >/dev/null 2>&1; then
        red "  ✗ $name: fixture setup broke 800's registration too (bad fixture)"
        FAIL=$((FAIL + 1))
        return
    fi

    # Fake `gh`: 747's PR is MERGED (reap-eligible); 800's is OPEN (must be
    # left alone — the live-worker stand-in).
    local fakebin="$tmproot/fakebin"
    mkdir -p "$fakebin"
    cat > "$fakebin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    printf 'fix/issue-747\tMERGED\n'
    printf 'fix/issue-800\tOPEN\n'
    exit 0
fi
exit 1
FAKEGH
    chmod +x "$fakebin/gh"

    local out rc
    out="$(PATH="$fakebin:$PATH" "$LLM_SWARM_DIR/scripts/reap-orphan-worktrees.sh" \
            --yes --min-age-days 0 --project "$project" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        red "  ✗ $name: real run exited $rc"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if [ -d "$wt747" ]; then
        red "  ✗ $name: dangling worktree 747 was not removed"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi

    # The actual regression check: 800's admin dir and working tree must be
    # completely untouched by 747's reap.
    if [ ! -d "$wt800" ]; then
        red "  ✗ $name: sibling worktree 800's directory was removed (should be untouched)"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! git -C "$wt800" rev-parse --git-dir >/dev/null 2>&1; then
        red "  ✗ $name: sibling worktree 800's git registration was corrupted by 747's reap"
        echo "$out"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! git -C "$project" worktree list | grep -q "$wt800"; then
        red "  ✗ $name: sibling worktree 800 no longer listed in git worktree list"
        FAIL=$((FAIL + 1))
        return
    fi

    green "  ✓ $name: Passed"
    PASS=$((PASS + 1))
}
test_dangling_reap_ignores_sibling_worktree

echo ""
echo "Summary: $PASS passed, $FAIL failed."
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
