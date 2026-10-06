#!/usr/bin/env bash
#
# test-worker-listener-processing-reap.sh — issue #559 acceptance criterion
# "stale processing/ entries are cleaned up or explained".
#
# A processing/<id>.md whose outcome already landed in done/<id>.{ok,err}.json
# means some earlier mv of the brief itself into done/ silently failed (both
# task-done.sh's own move and worker-listener.sh's own fallback mv tolerate a
# missing source with `|| true`, so a genuinely failed destination write
# leaves the stale .md behind with no error surfaced anywhere). Nothing else
# ever revisits processing/ once its outcome is recorded, so a stale entry
# sits there forever — and coordinator-watch.sh's worker_current_task_
# terminal()/worker_task_done() both treat a non-empty processing/ as "task
# still in flight" by design, permanently wedging WORKER_AUTO_DELIVER/
# WORKER_AUTO_COMPACT for that window even though the task genuinely
# finished. reap_stale_processing_entries() (worker-listener.sh) self-heals
# this on every main-loop iteration.
#
# Real listener loop (WORKER_HEADLESS=1, "bash" agent backend — same
# technique as test-shape-worker-result.sh), no model/network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$(mktemp -d -t worker-listener-reap-XXXXXX)"
LISTENER_PID=""
cleanup() {
    if [ -n "$LISTENER_PID" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    fi
    if [ "${KEEP:-0}" = 1 ]; then
        echo "Fixtures: $TEST_DIR"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

mkdir -p "$TEST_DIR/wt-issue-901/.swarm/tasks/inbox" \
         "$TEST_DIR/wt-issue-901/.swarm/tasks/processing" \
         "$TEST_DIR/wt-issue-901/.swarm/tasks/status" \
         "$TEST_DIR/wt-issue-901/.swarm/tasks/done"
cd "$TEST_DIR/wt-issue-901"

# Seed the exact anomaly: a brief still sitting in processing/ whose
# outcome has ALREADY been recorded in done/ — the mv that should have
# archived the .md there silently failed on some earlier run.
STALE_ID="20261005-234655-901"
echo "a brief whose outcome already landed, but whose .md never moved" \
    > ".swarm/tasks/processing/$STALE_ID.md"
printf '{"task_id":"%s","outcome":"ok","finished":"2026-10-05T23:46:55Z","source":"task-done.sh"}' \
    "$STALE_ID" > ".swarm/tasks/done/$STALE_ID.ok.json"

env LLM_SWARM_DIR= WORKER_MODEL= WORKER_HEADLESS=1 WORKER_CHECK=0 \
    bash "$RUNNER/scripts/worker-listener.sh" bash > listener.log 2>&1 &
LISTENER_PID=$!

reaped=0
for ((attempt = 0; attempt < 50; attempt++)); do
    if [ ! -e ".swarm/tasks/processing/$STALE_ID.md" ]; then
        reaped=1
        break
    fi
    kill -0 "$LISTENER_PID" 2>/dev/null || { cat listener.log; fail "listener exited before reaping"; }
    sleep 0.1
done
[ "$reaped" = 1 ] || { cat listener.log; fail "stale processing/$STALE_ID.md was never reaped"; }
green "stale processing/ entry (outcome already in done/) is moved out within a few poll ticks"

[ -f ".swarm/tasks/done/$STALE_ID.md" ] || fail "reaped brief was not archived to done/$STALE_ID.md"
green "reaped brief lands at done/$STALE_ID.md (audit trail preserved, not deleted)"

[ -e ".swarm/tasks/done/$STALE_ID.ok.json" ] || fail "pre-existing outcome record was disturbed"
green "the outcome record itself is untouched (reap only moves the brief, never rewrites the outcome)"

# The reap must not interfere with ordinary, unrelated task processing: a
# real new brief dropped into inbox/ afterward still gets claimed and
# completed normally.
printf 'true\n' > .swarm/tasks/inbox/.tmp.brief
mv .swarm/tasks/inbox/.tmp.brief .swarm/tasks/inbox/fresh-901.md
claimed=0
for ((attempt = 0; attempt < 50; attempt++)); do
    if [ -e ".swarm/tasks/done/fresh-901.ok.json" ]; then
        claimed=1
        break
    fi
    kill -0 "$LISTENER_PID" 2>/dev/null || { cat listener.log; fail "listener exited before claiming the fresh brief"; }
    sleep 0.1
done
[ "$claimed" = 1 ] || { cat listener.log; fail "a fresh brief dropped after the reap was never claimed"; }
green "a genuinely new brief dropped afterward is still claimed and completed normally"

echo
green "All checks passed."
