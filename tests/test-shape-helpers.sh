#!/usr/bin/env bash
#
# test-shape-helpers.sh — Non-LLM shape tests for requeue.sh + kill-worktree.sh
#
# Sets up a fixture git repo with a worktree, exercises both helpers across
# their main branches (numeric vs path arg, stdin vs file brief, missing
# inputs, idempotent re-runs), and asserts on filesystem state + stdout.
#
# Pairs with test-shape-swarm.sh, which covers worker-listener.sh.
set -euo pipefail

# These assertions exercise the legacy flat layout. Do not inherit an
# operator's project-grouped swarm setting from the calling shell.
export SWARM_WORKTREE_GROUPING=flat

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUEUE="$SCRIPT_DIR/../scripts/requeue.sh"
KILLWT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
[ -x "$REQUEUE" ] || red "requeue.sh not executable: $REQUEUE"
[ -x "$KILLWT" ]  || red "kill-worktree.sh not executable: $KILLWT"

TEST_DIR=$(mktemp -d -t shape-helpers-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

heading "Setup: fixture repo + worktree on issue #99"
cd "$TEST_DIR"
mkdir myproject && cd myproject
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
git worktree add -q -b fix/issue-99 ../wt-issue-99 master
WT="$TEST_DIR/wt-issue-99"
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing" "$WT/.swarm/tasks/done"
green "fixture ready: main repo + wt-issue-99 + queue dirs"

# ────────────────────────── requeue.sh ──────────────────────────

heading "Test 1: requeue.sh by numeric issue, brief from stdin"
echo "test brief from stdin" | "$REQUEUE" 99 - >/tmp/requeue-out 2>&1 || red "requeue exit non-zero"
mapfile -t inbox < <(ls "$WT"/.swarm/tasks/inbox/*.md 2>/dev/null)
[ "${#inbox[@]}" -eq 1 ] || red "expected 1 inbox file, got ${#inbox[@]}"
basename "${inbox[0]}" | grep -qE '^[0-9]{8}-[0-9]{6}-99\.md$' \
    || red "filename missing -99 issue hint: $(basename "${inbox[0]}")"
grep -q "test brief from stdin" "${inbox[0]}" || red "stdin brief content missing"
green "numeric arg resolves to ../wt-issue-N; stdin brief; filename has -99 hint"

heading "Test 2: requeue.sh by path arg, brief from file"
brief_file=$(mktemp)
echo "brief from file" > "$brief_file"
"$REQUEUE" "$WT" "$brief_file" >/tmp/requeue-out 2>&1 || red "requeue path form exit non-zero"
new_brief=$(grep -l "brief from file" "$WT"/.swarm/tasks/inbox/*.md | head -1)
[ -n "$new_brief" ] || red "file brief not found in inbox"
basename "$new_brief" | grep -qE '^[0-9]{8}-[0-9]{6}\.md$' \
    || red "filename should NOT have -<issue> suffix when called with path: $(basename "$new_brief")"
green "path arg uses given dir; file brief; no issue suffix in filename"

heading "Test 3: requeue.sh rejects missing worktree"
if "$REQUEUE" /no/such/worktree - <<<"x" >/tmp/requeue-out 2>&1; then
    red "should have failed for missing worktree dir"
fi
grep -q "ERROR: worktree not found" /tmp/requeue-out || red "missing expected error string"
green "exits non-zero with 'ERROR: worktree not found'"

heading "Test 4: requeue.sh rejects missing brief file"
if "$REQUEUE" "$WT" /no/such/brief.md >/tmp/requeue-out 2>&1; then
    red "should have failed for missing brief file"
fi
grep -q "ERROR: brief file not found" /tmp/requeue-out || red "missing expected error string"
# Confirm no leftover .tmp.* in inbox after the failed run
shopt -s nullglob
leftovers=("$WT"/.swarm/tasks/inbox/.tmp.*)
shopt -u nullglob
[ "${#leftovers[@]}" -eq 0 ] || red "leftover .tmp.* in inbox after failed brief: ${#leftovers[@]}"
green "exits with 'ERROR: brief file not found'; no .tmp.* leaked"

# ────────────────────────── kill-worktree.sh ──────────────────────────

heading "Test 5: kill-worktree.sh removes worktree + branch"
cd "$TEST_DIR/myproject"
"$KILLWT" 99 >/tmp/kill-out 2>&1 || red "kill-worktree exit non-zero"
[ ! -d "$WT" ] || red "worktree directory still exists"
if git -C "$TEST_DIR/myproject" show-ref --verify --quiet refs/heads/fix/issue-99; then
    red "branch fix/issue-99 still exists"
fi
grep -q "removed worktree" /tmp/kill-out || red "missing 'removed worktree' line"
grep -q "deleted branch"   /tmp/kill-out || red "missing 'deleted branch' line"
green "worktree dir removed, branch deleted, success lines printed"

heading "Test 6: kill-worktree.sh reports commits-ahead before deletion"
cd "$TEST_DIR/myproject"
git worktree add -q -b fix/issue-99 ../wt-issue-99 master
git -C "$TEST_DIR/wt-issue-99" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "wip"
"$KILLWT" 99 >/tmp/kill-out 2>&1 || red "kill-worktree (re-run) exit non-zero"
grep -qE 'Worktree state: 1 commit\(s\) ahead of master, 0 uncommitted' /tmp/kill-out \
    || red "expected 'Worktree state: 1 commit(s) ahead of master, 0 uncommitted'; got: $(grep Worktree /tmp/kill-out || echo none)"
green "reports commits-ahead/uncommitted before destruction"

heading "Test 7: kill-worktree.sh idempotent on missing pieces"
cd "$TEST_DIR/myproject"
"$KILLWT" 99 >/tmp/kill-out 2>&1 || red "idempotent re-run exited non-zero"
grep -q "worktree dir not present (skipped)" /tmp/kill-out \
    || red "expected idempotent skip for missing worktree"
grep -q "branch fix/issue-99 not present (skipped)" /tmp/kill-out \
    || red "expected idempotent skip for missing branch fix/issue-99"
green "idempotent re-run succeeds with 'skipped' notes"

heading "All shape-helper tests passed"
echo "  requeue.sh: numeric+path args, stdin+file briefs, error paths, no .tmp leaks"
echo "  kill-worktree.sh: removal, commits-ahead reporting, idempotency"
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
