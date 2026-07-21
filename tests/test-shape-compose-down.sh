#!/usr/bin/env bash
#
# test-shape-compose-down.sh — Non-LLM shape tests for
# _compose-down-for-worktree.sh (issue #105 teardown helper) and its
# --no-compose-down opt-out wired into kill-worktree.sh.
#
# Stubs `docker` via PATH override — no real compose stack, no daemon.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

# Don't inherit an operator's project-grouped swarm setting.
export SWARM_WORKTREE_GROUPING=flat

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DOWN="$SCRIPT_DIR/../scripts/_compose-down-for-worktree.sh"
KILLWT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
[ -x "$COMPOSE_DOWN" ] || red "not executable: $COMPOSE_DOWN"
[ -x "$KILLWT" ]       || red "not executable: $KILLWT"

TEST_DIR=$(mktemp -d -t shape-compose-down-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────── Stub docker on PATH ───────────────────────────

export DOCKER_LOG="$TEST_DIR/docker.log"
: > "$DOCKER_LOG"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
exit 0
EOF
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH"

# ============================================================================
heading "Test 1: no-op when the worktree has no compose file"
# ============================================================================
mkdir -p "$TEST_DIR/wt-no-compose"
: > "$DOCKER_LOG"
OUT=$("$COMPOSE_DOWN" "$TEST_DIR/wt-no-compose" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 with no compose file, got $RC"
[ -z "$OUT" ] || red "expected no output when no compose file present, got: $OUT"
[ -s "$DOCKER_LOG" ] && red "docker was invoked despite no compose file"
green "no-op, exit 0, docker never invoked"

# ============================================================================
heading "Test 2: invokes docker compose down when a compose file exists"
# ============================================================================
mkdir -p "$TEST_DIR/wt-with-compose"
: > "$TEST_DIR/wt-with-compose/docker-compose.yml"
: > "$DOCKER_LOG"
OUT=$("$COMPOSE_DOWN" "$TEST_DIR/wt-with-compose" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC"
echo "$OUT" | grep -q "found $TEST_DIR/wt-with-compose/docker-compose.yml" \
    || red "expected 'found <compose file>' line, got: $OUT"
echo "$OUT" | grep -q "compose down (project wt-with-compose)" \
    || red "expected success line naming the project, got: $OUT"
grep -q "compose -f $TEST_DIR/wt-with-compose/docker-compose.yml --project-directory $TEST_DIR/wt-with-compose down --remove-orphans --volumes" "$DOCKER_LOG" \
    || red "expected 'docker compose ... down --remove-orphans --volumes' call; got: $(cat "$DOCKER_LOG")"
green "docker compose down invoked with the right file/project-directory/flags"

# ============================================================================
heading "Test 3: always exits 0 even when docker compose fails"
# ============================================================================
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
exit 1
EOF
chmod +x "$TEST_DIR/bin/docker"
: > "$DOCKER_LOG"
OUT=$("$COMPOSE_DOWN" "$TEST_DIR/wt-with-compose" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 even when docker compose fails, got $RC"
echo "$OUT" | grep -q "WARN: compose down failed" || red "expected WARN line on failure, got: $OUT"
green "docker compose failure is a warning, not fatal"

# Restore the always-succeed stub for the kill-worktree.sh tests below.
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
exit 0
EOF
chmod +x "$TEST_DIR/bin/docker"

# ─────────────────── kill-worktree.sh --no-compose-down wiring ─────────────

heading "Setup: fixture repo + worktree with a compose file"
cd "$TEST_DIR"
mkdir myproject && cd myproject
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
git worktree add -q -b fix/issue-77 ../wt-issue-77 master
WT="$TEST_DIR/wt-issue-77"
: > "$WT/docker-compose.yml"
green "fixture ready: myproject + wt-issue-77 (with docker-compose.yml)"

# ============================================================================
heading "Test 4: kill-worktree.sh --no-compose-down skips the teardown"
# ============================================================================
cd "$TEST_DIR/myproject"
: > "$DOCKER_LOG"
"$KILLWT" 77 . --no-compose-down >"$TEST_DIR/kill-out.log" 2>&1 || red "kill-worktree exit non-zero"
grep -q "skipping compose down (--no-compose-down)" "$TEST_DIR/kill-out.log" \
    || red "expected 'skipping compose down' line; got: $(cat "$TEST_DIR/kill-out.log")"
[ -s "$DOCKER_LOG" ] && red "docker was invoked despite --no-compose-down"
[ ! -d "$WT" ] || red "worktree should have been removed"
green "--no-compose-down: teardown skipped, docker never invoked, worktree still removed"

# ============================================================================
heading "Test 5: kill-worktree.sh (default) runs compose-down before removal"
# ============================================================================
cd "$TEST_DIR/myproject"
git worktree add -q -b fix/issue-78 ../wt-issue-78 master
WT78="$TEST_DIR/wt-issue-78"
: > "$WT78/docker-compose.yml"
: > "$DOCKER_LOG"
"$KILLWT" 78 . >"$TEST_DIR/kill-out.log" 2>&1 || red "kill-worktree exit non-zero"
grep -q "compose down" "$TEST_DIR/kill-out.log" \
    || red "expected compose-down helper output in kill-worktree log"
[ -s "$DOCKER_LOG" ] || red "expected docker to be invoked when no --no-compose-down given"
grep -q "wt-issue-78" "$DOCKER_LOG" || red "expected the compose call to reference wt-issue-78"
[ ! -d "$WT78" ] || red "worktree should have been removed"
green "default (no flag): docker compose down invoked, then worktree removed"

# ============================================================================
heading "All compose-down shape tests passed"
# ============================================================================
green "no-op / invoke / non-fatal-failure + kill-worktree.sh --no-compose-down wiring"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
