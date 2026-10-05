#!/usr/bin/env bash
#
# test-shape-agent-pgid-isolation.sh — Regression test for issue #529.
#
# Without job control, every foreground command worker-listener.sh runs
# (claude/gemini/codex) shares THIS script's own process group — a plain
# fork/exec never calls setpgid. An agent that resolves its own pgid and
# runs `kill -TERM -<pgid>` meaning to stop only the command tree it
# started (the 2026-10-01 corpusminder incident: a Codex worker killing a
# Gradle test run it had launched) therefore also kills the listener and
# everything else sharing that group — pane dead, container torn down, the
# in-flight brief stranded in processing/ with no outcome ever written.
#
# The fix is `set -m` near the top of worker-listener.sh: it turns on job
# control (off by default for non-interactive bash), so every foreground
# command dispatch_agent() runs gets its OWN new process group — a
# `kill -<pgid>` from inside it can then only reach its own descendants.
#
# This test drives the real listener loop end-to-end (like
# test-shape-noop-detect.sh) against a stub `codex` binary that resolves
# its own pgid and sends itself exactly the signal the incident did, with
# no real Codex CLI invocation needed.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

command -v jq >/dev/null 2>&1 || red "jq required for outcome JSON validation"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t shape-pgid-isolation-XXXXXX)
LISTENER_PIDS=()
cleanup() {
    for pid in "${LISTENER_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

wait_for() {
    local desc="$1" cmd="$2" max=20
    for ((i=0; i<max; i++)); do
        if eval "$cmd"; then return 0; fi
        sleep 0.5
    done
    red "timeout waiting for: $desc"
}

drop_v2() {
    local dir="$1" task_id="$2" body="$3"
    local tmp
    tmp=$(mktemp -p "$dir/.swarm/tasks/inbox" .tmp.XXXX.md)
    printf '%s\n' "$body" > "$tmp"
    mv "$tmp" "$dir/.swarm/tasks/inbox/$task_id.md"
}

# --- Stub `codex` CLI --------------------------------------------------------
# Mirrors dispatch_agent()'s headless codex invocation: `codex exec ... <task
# text as the final argv>`. Reads the final argv (the task body) to decide
# its own behavior, so one listener instance can run a self-kill task
# followed by a normal one without needing to restart it or mutate its env.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
task="${*: -1}"
if [[ "$task" == *SELFKILL_MARKER* ]]; then
    pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
    printf '%s\n' "$pgid" > "$STUB_PGID_FILE"
    kill -TERM -"$pgid"
    # Unreachable if the fix works (we die from our own signal above);
    # reachable only when the listener still shares our pgid and some
    # scheduling quirk let us resume — a buggy-fix canary, not the
    # expected path.
    sleep 1
    echo "codex stub SURVIVED ITS OWN GROUP KILL (fix not effective)" >&2
    exit 1
fi
exit 0
STUB
chmod +x "$TEST_DIR/bin/codex"
export PATH="$TEST_DIR/bin:$PATH"
STUB_PGID_FILE="$TEST_DIR/stub.pgid"
export STUB_PGID_FILE

start_listener() {   # $1 = dir
    local dir="$1"
    mkdir -p "$dir/.swarm/tasks/inbox" "$dir/.swarm/tasks/processing" "$dir/.swarm/tasks/done" "$dir/.swarm/tasks/status"
    ( cd "$dir" && env WORKER_HEADLESS=1 HOME="$dir/home" WORKER_CHECK=0 "$LISTENER" codex > listener.log 2>&1 ) &
    LISTENER_PIDS+=($!)
    sleep 0.5
}

heading "Fixture: bare origin.git + worktree clones"
cd "$TEST_DIR"
mkdir seed && cd seed
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
cd "$TEST_DIR"
git clone -q --bare seed origin.git
for wt in wt-a wt-b; do
    git clone -q origin.git "$wt"
    mkdir -p "$wt/home"
done
green "fixture ready: origin.git + worktree clones, each with its own \$HOME"

# ============================================================================
heading "Test A (#529 regression): agent's own 'kill -<pgid>' leaves the listener alive"
# ============================================================================
start_listener "$TEST_DIR/wt-a"
LISTENER_PID="${LISTENER_PIDS[-1]}"
cd "$TEST_DIR/wt-a"

drop_v2 . "k1" '## Task

Run the tests, then stop them.

SELFKILL_MARKER'
wait_for "k1 outcome" '[ -f .swarm/tasks/done/k1.err.json ]'

kill -0 "$LISTENER_PID" 2>/dev/null \
    || red "k1: the listener process ($LISTENER_PID) died along with the agent's own process group — the bug this test guards against"
green "listener process ($LISTENER_PID) is still alive after the agent killed its own process group"

[ -s "$STUB_PGID_FILE" ] || red "k1: stub never recorded its own pgid — dispatch may not have reached the stub"
STUB_PGID="$(cat "$STUB_PGID_FILE")"
LISTENER_PGID="$(ps -o pgid= -p "$LISTENER_PID" | tr -d ' ')"
[ "$STUB_PGID" != "$LISTENER_PGID" ] \
    || red "k1: dispatched agent's pgid ($STUB_PGID) equals the listener's own pgid ($LISTENER_PGID) — set -m isolation is not in effect"
green "dispatched agent's own pgid ($STUB_PGID) differs from the listener's ($LISTENER_PGID) — isolated as intended"

jq -e '
    .outcome == "err"
    and .exit_code == 143
    and (.reason | test("agent-process-killed"))
    and (.reason | test("signal 15"))
' .swarm/tasks/done/k1.err.json >/dev/null \
    || { cat .swarm/tasks/done/k1.err.json; red "k1: run was not recorded as a failed, signal-named outcome"; }
green "k1 recorded as outcome=err, exit_code=143, reason names signal 15 (SIGTERM)"

# ============================================================================
heading "Test B: the SAME listener instance still drains a normal task afterward"
# ============================================================================
drop_v2 . "k2" '## Task

Just a normal task, no self-kill.'
wait_for "k2 outcome" '[ -f .swarm/tasks/done/k2.ok.json ]'
jq -e '.outcome == "ok"' .swarm/tasks/done/k2.ok.json >/dev/null \
    || { cat .swarm/tasks/done/k2.ok.json; red "k2: listener did not resume normal queue draining after surviving k1"; }
green "listener drained a second, unrelated task normally — the main loop was never disrupted"

kill -KILL "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true

# ============================================================================
heading "Test C (no regression): a genuine listener death still strands the brief"
# ============================================================================
# Acceptance criterion: stranded-brief handling for a REAL crash (the whole
# listener process gone, e.g. container death) must be unchanged by this
# fix — set -m only isolates a dispatched agent's OWN process group; it
# does nothing to, and nothing here should change, what happens when the
# listener itself is killed outright while a brief is mid-flight.
cat > "$TEST_DIR/bin/codex" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$TEST_DIR/bin/codex"

start_listener "$TEST_DIR/wt-b"
CRASH_LISTENER_PID="${LISTENER_PIDS[-1]}"
cd "$TEST_DIR/wt-b"

drop_v2 . "s1" '## Task

A long-running task that never gets the chance to finish.'
wait_for "s1 claimed" '[ -f .swarm/tasks/processing/s1.md ]'

# Simulate a container/pane death: kill the listener process itself
# directly, same as before this fix existed.
kill -KILL "$CRASH_LISTENER_PID" 2>/dev/null || true
wait "$CRASH_LISTENER_PID" 2>/dev/null || true
sleep 0.5

[ -f .swarm/tasks/processing/s1.md ] \
    || red "s1: brief unexpectedly left processing/ after a simulated listener crash"
[ ! -e .swarm/tasks/done/s1.ok.json ] && [ ! -e .swarm/tasks/done/s1.err.json ] \
    || red "s1: an outcome was written despite the listener having been killed outright"
green "a genuine listener death still leaves the brief stranded in processing/ with no outcome — unchanged"

# ============================================================================
heading "All agent-pgid-isolation shape tests passed"
# ============================================================================
green "agent's own group-kill survives the listener, queue draining resumes, genuine crashes still strand the brief as before"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
