#!/usr/bin/env bash
#
# test-worker-listener-claude-config.sh — issue #630.
#
# A container's ~/.claude.json (single-file bind mount) can be left at 0 bytes
# when the CLI is interrupted mid-save. worker-listener.sh must validate it
# before EVERY claude launch: restore from the newest valid .tmp.* (then the
# last-known-good copy), log worker.config.repaired, and launch normally; if
# nothing valid exists, fail the launch with an err outcome naming the cause
# rather than parking at the "invalid JSON" dialog.
#
# Real listener loop with a fake `claude` on PATH (records that it launched).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(dirname "$SCRIPT_DIR")"
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
TEST_DIR="$(mktemp -d -t worker-listener-cfg-XXXXXX)"
LISTENER_PID=""
cleanup() {
    [ -n "$LISTENER_PID" ] && { kill "$LISTENER_PID" 2>/dev/null || true; wait "$LISTENER_PID" 2>/dev/null || true; }
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [ -f "${LOG:-/nonexistent}" ] && cat "$LOG" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/home"
cat > "$TEST_DIR/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
echo launched >> "$FAKE_CLAUDE_LOG"
FAKE
chmod +x "$TEST_DIR/bin/claude"

new_wt() {  # new_wt <name>
    WT="$TEST_DIR/$1/wt-issue-630"
    mkdir -p "$WT/.swarm/tasks"/{inbox,processing,status,done}
    LOG="$WT/listener.log"
    export FAKE_CLAUDE_LOG="$WT/claude-launches"
}
run_listener() {  # run_listener <task-id>
    ( cd "$WT"
      printf 'do nothing\n' > .swarm/tasks/inbox/.tmp.brief
      mv .swarm/tasks/inbox/.tmp.brief ".swarm/tasks/inbox/$1.md"
      env PATH="$TEST_DIR/bin:$PATH" LLM_SWARM_DIR= WORKER_MODEL= WORKER_HEADLESS=1 WORKER_CHECK=0 \
          CLAUDE_CONFIG_FILE="$TEST_DIR/home/.claude.json" \
          bash "$RUNNER/scripts/worker-listener.sh" claude > listener.log 2>&1 &
      echo $! > listener.pid )
    LISTENER_PID="$(cat "$WT/listener.pid")"
    for ((i = 0; i < 100; i++)); do
        compgen -G "$WT/.swarm/tasks/done/$1.*.json" >/dev/null && break
        kill -0 "$LISTENER_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
}

# The fake claude does no work, so the no-op floor may still record err
# (agent-startup-failure); what matters is that the launch was NOT blocked.
assert_launched_not_blocked() {
    compgen -G "$WT/.swarm/tasks/done/$1.*.json" >/dev/null || fail "no outcome recorded for $1"
    [ -f "$FAKE_CLAUDE_LOG" ] || fail "claude never launched for $1"
    ! grep -q claude-config-unrecoverable "$WT"/.swarm/tasks/done/$1.*.json || fail "launch for $1 was blocked"
}

CFG="$TEST_DIR/home/.claude.json"

# --- Case 1: 0-byte config + complete leftover .tmp.* -> restored, launch ok
new_wt case1
rm -f "$TEST_DIR"/home/.claude.json*
: > "$CFG"
echo '{"oauthAccount":{"x":1},"older":true}' > "$CFG.tmp.46.aaa"; touch -d '2 min ago' "$CFG.tmp.46.aaa"
echo '{"oauthAccount":{"x":1},"newest":true}' > "$CFG.tmp.47.bbb"
run_listener t630a
assert_launched_not_blocked t630a
jq -e '.newest == true' "$CFG" >/dev/null || fail "case 1: config was not restored from the NEWEST valid .tmp.*"
[ -f "$FAKE_CLAUDE_LOG" ] || fail "case 1: claude never launched"
grep -q "worker.config.repaired" "$WT/listener.log" || fail "case 1: no worker.config.repaired line in the pane log"
grep -rq "worker.config.repaired" "$WT/.swarm/tasks/outbox/" || fail "case 1: no outbox fyi for the coordinator"
green "0-byte config is restored from the newest valid .tmp.*; claude launches; event logged + forwarded"

# --- Case 2: invalid JSON, no .tmp.*, last-known-good copy exists
new_wt case2
rm -f "$TEST_DIR"/home/.claude.json*
echo '{"lkg":true}' > "$CFG.lkg"
printf '{"truncated":' > "$CFG"
run_listener t630b
assert_launched_not_blocked t630b
jq -e '.lkg == true' "$CFG" >/dev/null || fail "case 2: config not restored from last-known-good"
green "invalid-JSON config falls back to the last-known-good copy"

# --- Case 3: healthy config is left alone and snapshotted as last-known-good
new_wt case3
rm -f "$TEST_DIR"/home/.claude.json*
echo '{"healthy":true}' > "$CFG"
run_listener t630c
jq -e '.healthy == true' "$CFG.lkg" >/dev/null || fail "case 3: healthy config not snapshotted to .lkg"
grep -q "worker.config.repaired" "$WT/listener.log" && fail "case 3: spurious repair on a healthy config"
green "healthy config is untouched and snapshotted as last-known-good"

# --- Case 4: nothing to restore from -> err outcome naming the cause, no launch
new_wt case4
rm -f "$TEST_DIR"/home/.claude.json*
: > "$CFG"
run_listener t630d
[ -f "$WT/.swarm/tasks/done/t630d.err.json" ] || fail "case 4: expected err outcome"
[ ! -f "$FAKE_CLAUDE_LOG" ] || fail "case 4: claude launched despite an unusable config"
jq -e '.reason | startswith("claude-config-unrecoverable")' "$WT/.swarm/tasks/done/t630d.err.json" >/dev/null \
    || fail "case 4: err outcome does not name the cause: $(cat "$WT"/.swarm/tasks/done/t630d.err.json)"
green "unrecoverable config fails the launch with err reason claude-config-unrecoverable (no silent stall)"

# --- Case 5: a stale orphan .tmp.* must not beat a fresher last-known-good
new_wt case5
rm -f "$TEST_DIR"/home/.claude.json*
echo '{"stale_tmp":true}' > "$CFG.tmp.9.old"; touch -d '3 days ago' "$CFG.tmp.9.old"
echo '{"fresh_lkg":true}' > "$CFG.lkg"
: > "$CFG"
run_listener t630e
jq -e '.fresh_lkg == true' "$CFG" >/dev/null || fail "case 5: stale .tmp.* beat the fresher last-known-good"
green "restore picks the freshest of .tmp.* and last-known-good by mtime"
