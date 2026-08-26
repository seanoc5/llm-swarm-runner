#!/usr/bin/env bash
#
# test-shape-noop-detect.sh — Regression test for issue #287.
#
# worker-listener.sh recorded outcome=ok whenever the dispatched agent
# exited 0, even when it never actually engaged with the task (e.g. a
# claude CLI startup dialog — corrupt config, trust prompt, login screen,
# see #286 — idles, gets dismissed, and exits 0 having done nothing). The
# coordinator then saw a false success.
#
# check_min_interaction() + the write_outcome() gating it added fixes this
# for the claude agent: when a task would otherwise be "ok" with no
# executed check, no new commits ahead of the default branch, and no
# worker-authored status file, the listener falls back to checking whether
# claude's own session transcript under ~/.claude/projects/<slug>/ actually
# grew during the dispatch. This test drives the real listener loop
# end-to-end (like test-shape-swarm.sh / test-shape-checks.sh) against a
# stub `claude` binary whose behavior is controlled by $CLAUDE_STUB_MODE,
# so no real Claude Code CLI invocation is needed.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

command -v jq >/dev/null 2>&1 || red "jq required for outcome JSON validation"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable: $LISTENER"

TEST_DIR=$(mktemp -d -t shape-noop-detect-XXXXXX)
LISTENER_PIDS=()
cleanup() {
    for pid in "${LISTENER_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
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

# --- Stub `claude` CLI ------------------------------------------------------
# Ignores every argument (headless dispatch passes --model/-p/etc) and just
# acts on $CLAUDE_STUB_MODE, so it's robust to dispatch_agent()'s exact flags.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
slug="$(printf '%s' "$PWD" | tr '/' '-')"
dir="$HOME/.claude/projects/$slug"
case "${CLAUDE_STUB_MODE:-real}" in
    noop)
        # Startup-dialog failure: exits 0, never wrote a transcript.
        exit 0
        ;;
    thin)
        mkdir -p "$dir"
        printf '{}' > "$dir/session-thin.jsonl"
        exit 0
        ;;
    real)
        mkdir -p "$dir"
        head -c 2000 /dev/zero | tr '\0' 'x' > "$dir/session-real.jsonl"
        exit 0
        ;;
    *)
        echo "unknown CLAUDE_STUB_MODE: ${CLAUDE_STUB_MODE:-}" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$TEST_DIR/bin/claude"
export PATH="$TEST_DIR/bin:$PATH"

start_listener() {   # $1 = dir; rest = env VAR=VAL pairs
    local dir="$1"; shift
    mkdir -p "$dir/.swarm/tasks/inbox" "$dir/.swarm/tasks/processing" "$dir/.swarm/tasks/done" "$dir/.swarm/tasks/status"
    ( cd "$dir" && env WORKER_HEADLESS=1 HOME="$dir/home" "$@" "$LISTENER" claude > listener.log 2>&1 ) &
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
for wt in wt-a wt-b wt-c wt-d wt-e wt-f; do
    git clone -q origin.git "$wt"
    mkdir -p "$wt/home"
done
green "fixture ready: origin.git + wt-a..wt-f clones, each with its own \$HOME"

# ============================================================================
heading "Test A (#287 regression): startup-failure noop → outcome flips to err"
# ============================================================================
start_listener "$TEST_DIR/wt-a" CLAUDE_STUB_MODE=noop
cd "$TEST_DIR/wt-a"
drop_v2 . "a1" '## Task

Do something.'
wait_for "a1 outcome" '[ -f .swarm/tasks/done/a1.err.json ]'
jq -e '
    .outcome == "err"
    and .exit_code == 0
    and (.reason | test("agent-startup-failure"))
' .swarm/tasks/done/a1.err.json >/dev/null \
    || { cat .swarm/tasks/done/a1.err.json; red "a1: exit-0 startup-failure noop was not caught"; }
[ ! -f .swarm/tasks/done/a1.ok.json ] || red "a1: spurious ok.json"
green "exit 0 + no transcript + no commits + no status file → err.json with agent-startup-failure reason"

# ============================================================================
heading "Test B (false-positive guard): real interaction, no commits → stays ok"
# ============================================================================
start_listener "$TEST_DIR/wt-b" CLAUDE_STUB_MODE=real
cd "$TEST_DIR/wt-b"
drop_v2 . "b1" '## Task

Investigate and report back; no code changes needed.'
wait_for "b1 outcome" '[ -f .swarm/tasks/done/b1.ok.json ]'
jq -e '.outcome == "ok" and .reason == null' .swarm/tasks/done/b1.ok.json >/dev/null \
    || { cat .swarm/tasks/done/b1.ok.json; red "b1: legitimate no-commit success was wrongly flagged"; }
green "exit 0 + real transcript growth, no commits → stays ok, reason null"

# ============================================================================
heading "Test C: transcript too small (sliver) is still caught"
# ============================================================================
start_listener "$TEST_DIR/wt-c" CLAUDE_STUB_MODE=thin
cd "$TEST_DIR/wt-c"
drop_v2 . "c1" '## Task

Do something.'
wait_for "c1 outcome" '[ -f .swarm/tasks/done/c1.err.json ]'
jq -e '.outcome == "err" and (.reason | test("sliver|only"))' .swarm/tasks/done/c1.err.json >/dev/null \
    || { cat .swarm/tasks/done/c1.err.json; red "c1: undersized transcript was not caught"; }
green "transcript written but far too small → still err.json"

# ============================================================================
heading "Test D: worker-authored status file is trusted, never overridden"
# ============================================================================
start_listener "$TEST_DIR/wt-d" CLAUDE_STUB_MODE=noop
cd "$TEST_DIR/wt-d"
mkdir -p .swarm/tasks/status
cat > .swarm/tasks/status/d1.json <<'EOF'
{"task_id": "d1", "state": "done-no-pr", "pr": null, "ts": "2026-01-01T00:00:00Z", "note": "investigated, no change needed"}
EOF
drop_v2 . "d1" '## Task

Do something.'
wait_for "d1 outcome" '[ -f .swarm/tasks/done/d1.ok.json ]'
jq -e '.outcome == "ok" and .reason == null' .swarm/tasks/done/d1.ok.json >/dev/null \
    || { cat .swarm/tasks/done/d1.ok.json; red "d1: status file present but tripwire still overrode outcome"; }
green "pre-existing worker status file → tripwire skipped, stays ok"

# ============================================================================
heading "Test E: kill switch WORKER_NOOP_DETECT=0 preserves old behavior"
# ============================================================================
start_listener "$TEST_DIR/wt-e" CLAUDE_STUB_MODE=noop WORKER_NOOP_DETECT=0
cd "$TEST_DIR/wt-e"
drop_v2 . "e1" '## Task

Do something.'
wait_for "e1 outcome" '[ -f .swarm/tasks/done/e1.ok.json ]'
jq -e '.outcome == "ok" and .reason == null' .swarm/tasks/done/e1.ok.json >/dev/null \
    || { cat .swarm/tasks/done/e1.ok.json; red "e1: WORKER_NOOP_DETECT=0 did not disable the tripwire"; }
green "WORKER_NOOP_DETECT=0: exit-0 noop still recorded ok (old behavior)"

# ============================================================================
heading "Test F: a passed executed check always wins, regardless of transcript"
# ============================================================================
start_listener "$TEST_DIR/wt-f" CLAUDE_STUB_MODE=noop
cd "$TEST_DIR/wt-f"
drop_v2 . "f1" '## Task

Do something.
<!-- SWARM_CHECK: true -->'
wait_for "f1 outcome" '[ -f .swarm/tasks/done/f1.ok.json ]'
jq -e '.outcome == "ok" and .check_exit == 0 and .reason == null' .swarm/tasks/done/f1.ok.json >/dev/null \
    || { cat .swarm/tasks/done/f1.ok.json; red "f1: passed check should short-circuit the tripwire"; }
green "executed check passed → tripwire never consulted, stays ok"

# ============================================================================
heading "All noop-detection shape tests passed"
# ============================================================================
green "startup-failure caught, real work not flagged, sliver caught, status file trusted, kill switch works, passed check wins"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
