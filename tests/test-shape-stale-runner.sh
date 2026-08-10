#!/usr/bin/env bash
#
# test-shape-stale-runner.sh — Regression test for issue #251.
#
# worker-listener.sh injects prompts/worker.md from $LLM_SWARM_DIR (the
# runner sandbox's own checkout) as a system prompt on every task dispatch.
# Unlike per-project worktrees (which provision-worker.sh always branches
# fresh off origin/<default>), $LLM_SWARM_DIR is a long-lived checkout that
# only advances when something explicitly pulls it — so it can silently
# fall behind origin/master and inject stale worker conventions into every
# dispatched agent without anyone noticing.
#
# refresh_stale_runner_checkout() (worker-listener.sh) guards against this:
# fast-forward when safe, WARN-only otherwise, never block launch. This test
# extracts the function verbatim (sed, not a hand-retyped copy — same trick
# as test-coordinator-auto-compact.sh / test-pr-predates-worktree.sh) and
# exercises it against real fixture git repos with a file:// remote.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -f "$LISTENER" ] || red "worker-listener.sh not found: $LISTENER"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t shape-stale-runner-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    sed -n "/^refresh_stale_runner_checkout() {/,/^}/p" "$LISTENER"
}
body="$(extract_fn)"
[ -n "$body" ] || red "could not extract refresh_stale_runner_checkout() from $LISTENER — has it been renamed?"
eval "$body"

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

# ──────────────────────── Fixture: bare origin + runner clone ────────────────────────

heading "Setup: bare origin.git + runner clone (stands in for \$LLM_SWARM_DIR) + pusher clone"
cd "$TEST_DIR"
mkdir seed && cd seed
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
git clone -q --bare . "$TEST_DIR/origin.git"
cd "$TEST_DIR"
git clone -q origin.git runner
git clone -q origin.git pusher
green "fixture ready: origin.git, runner/, pusher/"

# ──────────────────────── Test 1: clean + behind → fast-forward ────────────────────────

heading "Test 1: clean runner checkout behind origin/master → fast-forwards"
cd "$TEST_DIR/pusher"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "PR #231: new skeleton"
git push -q origin master
NEW_SHA="$(git rev-parse HEAD)"

out="$(LLM_SWARM_DIR="$TEST_DIR/runner" refresh_stale_runner_checkout 2>&1)"
runner_sha="$(git -C "$TEST_DIR/runner" rev-parse HEAD)"
check "runner fast-forwarded to origin/master's new commit" '[ "$runner_sha" = "$NEW_SHA" ]'
check "output announces the fast-forward" 'grep -q "Fast-forwarded" <<<"$out"'

# ──────────────────────── Test 2: diverged → WARN only, no mutation ────────────────────────

heading "Test 2: diverged runner checkout → WARN only, no mutation"
cd "$TEST_DIR/pusher"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "another origin commit"
git push -q origin master
cd "$TEST_DIR/runner"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "local-only commit, never pushed"
DIVERGED_SHA="$(git rev-parse HEAD)"

out="$(LLM_SWARM_DIR="$TEST_DIR/runner" refresh_stale_runner_checkout 2>&1)"
runner_sha="$(git -C "$TEST_DIR/runner" rev-parse HEAD)"
check "diverged runner checkout left untouched" '[ "$runner_sha" = "$DIVERGED_SHA" ]'
check "output warns about divergence" 'grep -qi "WARN stale-prompts.*diverged" <<<"$out"'

# Reset runner back to a clean, in-sync state for the next tests.
cd "$TEST_DIR/runner"
git reset -q --hard origin/master

# ──────────────────────── Test 3: dirty working tree → WARN only, no mutation ────────────────────────

heading "Test 3: dirty runner checkout behind origin → WARN only, no mutation"
cd "$TEST_DIR/pusher"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "yet another origin commit"
git push -q origin master
cd "$TEST_DIR/runner"
echo "uncommitted local edit" > dirty.txt
CLEAN_SHA="$(git rev-parse HEAD)"

out="$(LLM_SWARM_DIR="$TEST_DIR/runner" refresh_stale_runner_checkout 2>&1)"
runner_sha="$(git rev-parse HEAD)"
check "dirty runner checkout left unmerged" '[ "$runner_sha" = "$CLEAN_SHA" ]'
check "dirty file still present (no stash/mutation)" '[ -f dirty.txt ]'
check "output warns about uncommitted changes" 'grep -qi "WARN stale-prompts.*uncommitted changes" <<<"$out"'
rm -f dirty.txt

# ──────────────────────── Test 4: remote unreachable → degrade, don't block ────────────────────────

heading "Test 4: remote unreachable → single WARN line, launch proceeds"
mkdir -p "$TEST_DIR/offline-runner"
cd "$TEST_DIR/offline-runner"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
git remote add origin "$TEST_DIR/does-not-exist.git"

rc=0
out="$(LLM_SWARM_DIR="$TEST_DIR/offline-runner" refresh_stale_runner_checkout 2>&1)" || rc=$?
check "function returns 0 (does not block launch) when remote unreachable" '[ "$rc" -eq 0 ]'
check "output warns about unreachable remote" 'grep -qi "WARN stale-prompts.*unreachable" <<<"$out"'

# ──────────────────────── Test 5: unset/non-git \$LLM_SWARM_DIR → silent no-op ────────────────────────

heading "Test 5: unset or non-git \$LLM_SWARM_DIR → silent no-op"
out="$(unset LLM_SWARM_DIR; refresh_stale_runner_checkout 2>&1)"
check "no output when \$LLM_SWARM_DIR is unset" '[ -z "$out" ]'

mkdir -p "$TEST_DIR/not-a-repo"
out="$(LLM_SWARM_DIR="$TEST_DIR/not-a-repo" refresh_stale_runner_checkout 2>&1)"
check "no output when \$LLM_SWARM_DIR is not a git checkout" '[ -z "$out" ]'

# ──────────────────────── Test 6: already up to date → no-op, no noise ────────────────────────

heading "Test 6: runner already up to date with origin/master → no-op"
cd "$TEST_DIR/runner"
git fetch -q origin
git merge -q --ff-only origin/master
UPTODATE_SHA="$(git rev-parse HEAD)"
out="$(LLM_SWARM_DIR="$TEST_DIR/runner" refresh_stale_runner_checkout 2>&1)"
runner_sha="$(git rev-parse HEAD)"
check "HEAD unchanged when already up to date" '[ "$runner_sha" = "$UPTODATE_SHA" ]'
check "no WARN/Fast-forwarded noise when already current" '[ -z "$out" ]'

heading "Results: $PASS checks passed"
green "All checks passed."
