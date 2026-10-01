#!/usr/bin/env bash
#
# test-shape-provision-stale-container.sh — Regression test for issue #493:
# a leftover same-name container (or a dead-paned window) silently kills a
# re-provisioned worker's pane, with provision-worker.sh still exiting 0.
#
# Covers the two new functions provision-worker.sh adds for this issue:
#   check_stale_container       (Do item 1) pre-spawn: clear a leftover
#                                container under this issue's exact name,
#                                or refuse if it's genuinely still tracked
#                                by a live window.
#   post_spawn_health_check     (Do item 2) post-spawn: a dead pane or a
#                                container that never came up must make the
#                                script exit non-zero, not 0.
#
# Why a real tmux server rather than a PATH/function stub for pane state:
# same reasoning as test-shape-watcher-respawn.sh — pane_dead and
# remain-on-exit are tmux's own behavior, not something worth re-asserting
# via a stub that already encodes the answer. `docker` IS stubbed (via
# PATH, same technique as test-watcher-autoclose.sh's FAKE_GH/FAKE_TMUX):
# container state is something this test controls directly, and real
# containers have no place in a unit test.
#
# Same extraction technique as test-shape-stranded-brief-sweep.sh /
# test-shape-stale-runner.sh: function bodies are lifted from
# provision-worker.sh with sed (never hand-copied), so a rename or a
# behavior edit that breaks the contract fails here instead of drifting
# silently.
#
# Requires: tmux, docker (image/daemon never touched — only the stub runs).
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
[ -r "$PROVISION" ] || red "provision-worker.sh not readable: $PROVISION"
command -v tmux >/dev/null 2>&1 || red "tmux not found — required by this feature and this test"

# Own tmux server — a failing test can never touch an operator's swarm
# sockets (llm-* sessions live on -L swarm-<project>).
SOCKET="test-provstale-$$"
SESSION="provstale-$$"
TEST_DIR=$(mktemp -d -t shape-provision-stale-container-XXXXXX)
cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    sed -n "/^${1}() {/,/^}/p" "$PROVISION"
}
for fn in check_stale_container post_spawn_health_check; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract '$fn' from $PROVISION — has it been renamed?"
    eval "$body"
    [ "$(type -t "$fn")" = "function" ] || red "'$fn' did not eval into a function"
done

# The extracted functions call bare `tmux`; point that at our private server.
tmux() { command tmux -L "$SOCKET" "$@"; }
command tmux -L "$SOCKET" new-session -d -s "$SESSION" -n util
# remain-on-exit is a window option; -g (server-scoped) is what actually
# takes effect for windows created afterward — `-t session` alone does not
# (confirmed experimentally; same `-g` llm-start.sh uses at line ~857).
command tmux -L "$SOCKET" set-option -g remain-on-exit on
SESSION_NAME="$SESSION"

# --- log_event stub: same on-disk contract as the real one (append-only,
# never fatal) — matches test-shape-stranded-brief-sweep.sh's own stand-in.
EVENTS_LOG="$TEST_DIR/events.log"
: > "$EVENTS_LOG"
log_event() {
    local cat="$1"; shift
    printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$cat" "$*" >> "$EVENTS_LOG"
}

# --- Fake `docker`: a tiny PATH stub tracking container state in a flat
# "<name> <running|stopped>" file, covering exactly the invocation shapes
# check_stale_container/post_spawn_health_check use (ps [-a] --filter
# name=^X$ --format {{.Names}}, stop, rm -f). DOCKER_RM_NOOP=1 simulates a
# stop/rm that doesn't actually clear the name yet (the --rm auto-removal
# race the fand-etl incident hit on its first recovery retry).
mkdir -p "$TEST_DIR/bin"
DOCKER_STATE_FILE="$TEST_DIR/docker-state.txt"
: > "$DOCKER_STATE_FILE"
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
STATE="$DOCKER_STATE_FILE"
case "$1" in
    ps)
        shift
        all=0; name=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -a) all=1 ;;
                --filter) shift; name="${1#name=^}"; name="${name%\$}" ;;
            esac
            shift
        done
        if [ "$all" = 1 ]; then
            awk -v n="$name" '$1==n {print $1}' "$STATE" 2>/dev/null
        else
            awk -v n="$name" '$1==n && $2=="running" {print $1}' "$STATE" 2>/dev/null
        fi
        ;;
    stop)
        [ "${DOCKER_RM_NOOP:-0}" = "1" ] && exit 0
        name="$2"
        awk -v n="$name" '{ if ($1==n) print n" stopped"; else print }' "$STATE" > "$STATE.tmp" 2>/dev/null
        mv "$STATE.tmp" "$STATE"
        ;;
    rm)
        [ "${DOCKER_RM_NOOP:-0}" = "1" ] && exit 0
        name="${*: -1}"
        awk -v n="$name" '$1!=n' "$STATE" > "$STATE.tmp" 2>/dev/null
        mv "$STATE.tmp" "$STATE"
        ;;
    image)
        # `docker image inspect <name>` — DOCKER_IMAGE_MISSING=1 simulates a
        # cold host that hasn't built the worker image yet.
        [ "${DOCKER_IMAGE_MISSING:-0}" = "1" ] && exit 1
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TEST_DIR/bin/docker"
export DOCKER_STATE_FILE
export PATH="$TEST_DIR/bin:$PATH"

# issue #493, self-review (7th pass): host_admission_check (provision-worker.sh)
# writes $HOST_STATE_DIR/pending-<container> before a spawn attempt; a failed
# attempt must remove it again (exit-2 and exit-4 paths) rather than leave it
# to double-count toward HOST_MAX_WORKERS until HOST_PENDING_TTL_SECS expires.
# A test-local dir keeps this isolated from any real host state.
export HOST_STATE_DIR="$TEST_DIR/host-state"
mkdir -p "$HOST_STATE_DIR"

# Helper: wait for a just-spawned window's pane to reach pane_dead=<want> —
# avoids a timing-dependent sleep for the genuinely-async tmux state change.
wait_pane_dead() {
    local win="$1" want="$2"
    for _ in $(seq 1 50); do
        [ "$(command tmux -L "$SOCKET" list-panes -t "$SESSION:$win" -F '#{pane_dead}' 2>/dev/null | head -1)" = "$want" ] && return 0
        sleep 0.1
    done
    return 1
}

# ============================================================================
heading "Test 1: no container at all -> no-op, nothing logged"
# ============================================================================
: > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
check_stale_container 201 swarm-provstale-iss-201
[ -z "$(cat "$EVENTS_LOG")" ] || red "expected no log_event call for a nonexistent container, got: $(cat "$EVENTS_LOG")"
green "no container under this name -> silent no-op"

# ============================================================================
heading "Test 2: stale container (stopped), no tracking window -> cleared"
# ============================================================================
echo "swarm-provstale-iss-202 stopped" > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
check_stale_container 202 swarm-provstale-iss-202
[ -z "$(awk -v n=swarm-provstale-iss-202 '$1==n' "$DOCKER_STATE_FILE")" ] \
    || red "expected the stale container entry gone after check_stale_container, state: $(cat "$DOCKER_STATE_FILE")"
grep -q 'provision.stale_container.*issue=202.*state=cleared' "$EVENTS_LOG" \
    || red "expected a state=cleared log line, got: $(cat "$EVENTS_LOG")"
green "a stale stopped container with no tracking window is cleared before spawn"

# ============================================================================
heading "Test 3: container running under a window whose pane is genuinely ALIVE -> refuse (exit 5), container untouched"
# ============================================================================
command tmux -L "$SOCKET" new-window -d -t "$SESSION" -n iss-203 "sleep 100"
echo "swarm-provstale-iss-203 running" > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
: > "$HOST_STATE_DIR/pending-swarm-provstale-iss-203"
rc=0
out="$(check_stale_container 203 swarm-provstale-iss-203 2>&1)" || rc=$?
[ "$rc" -eq 5 ] || red "expected a dedicated exit 5 for a container whose window is genuinely alive (self-review, 10th pass — plain exit 2 already means a different, far more common 'nothing running' refusal elsewhere in this script), got rc=$rc, output: $out"
echo "$out" | grep -qi 'requeue.sh' || red "expected the refusal to point at requeue.sh: $out"
[ -n "$(awk -v n=swarm-provstale-iss-203 '$1==n && $2=="running"' "$DOCKER_STATE_FILE")" ] \
    || red "a live worker's container must NOT be stopped: $(cat "$DOCKER_STATE_FILE")"
grep -q 'provision.stale_container.*issue=203.*state=window_alive' "$EVENTS_LOG" \
    || red "expected a state=window_alive log line, got: $(cat "$EVENTS_LOG")"
[ -e "$HOST_STATE_DIR/pending-swarm-provstale-iss-203" ] \
    && red "exit 5 (window_alive) must remove this attempt's pending marker (self-review, 7th pass)"
command tmux -L "$SOCKET" kill-window -t "$SESSION:iss-203" 2>/dev/null || true
green "a container tracked by a genuinely live window is left alone; provisioning refuses instead of killing a live worker, and clears its own pending marker"

# ============================================================================
heading "Test 4: container running under a window whose pane is DEAD -> cleared anyway (the fand-etl shape)"
# ============================================================================
command tmux -L "$SOCKET" new-window -d -t "$SESSION" -n iss-204 "true"
wait_pane_dead iss-204 1 || red "setup: expected window iss-204's pane to go dead"
echo "swarm-provstale-iss-204 running" > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
check_stale_container 204 swarm-provstale-iss-204
[ -z "$(awk -v n=swarm-provstale-iss-204 '$1==n' "$DOCKER_STATE_FILE")" ] \
    || red "expected the container cleared once its tracking window's pane is dead, state: $(cat "$DOCKER_STATE_FILE")"
grep -q 'provision.stale_container.*issue=204.*state=cleared' "$EVENTS_LOG" \
    || red "expected a state=cleared log line for the dead-paned case, got: $(cat "$EVENTS_LOG")"
command tmux -L "$SOCKET" kill-window -t "$SESSION:iss-204" 2>/dev/null || true
green "a window whose pane already died does not protect its container — cleared the same as no window at all"

# ============================================================================
heading "Test 5: removal races --rm's own auto-removal -> times out and exits 2 (fand-etl's first retry)"
# ============================================================================
echo "swarm-provstale-iss-205 stopped" > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
: > "$HOST_STATE_DIR/pending-swarm-provstale-iss-205"
rc=0
out="$(DOCKER_RM_NOOP=1 PROVISION_STALE_CONTAINER_WAIT_SECS=1 check_stale_container 205 swarm-provstale-iss-205 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || red "expected exit 2 on a removal timeout, got rc=$rc, output: $out"
grep -q 'provision.stale_container.*issue=205.*state=removal_timeout' "$EVENTS_LOG" \
    || red "expected a state=removal_timeout log line, got: $(cat "$EVENTS_LOG")"
[ -e "$HOST_STATE_DIR/pending-swarm-provstale-iss-205" ] \
    && red "exit 2 (removal_timeout) must remove this attempt's pending marker (self-review, 7th pass)"
green "a name that never actually clears (the --rm race) times out and exits 2 rather than spawning into it blind, and clears its own pending marker"

# ============================================================================
heading "Test 6: post_spawn_health_check — pane alive + container running -> succeeds silently"
# ============================================================================
command tmux -L "$SOCKET" new-window -d -t "$SESSION" -n iss-301 "sleep 100"
echo "swarm-provstale-iss-301 running" > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
echo "queued" > "$TEST_DIR/brief-301.md"
PROVISION_SPAWN_CHECK_SECS=0.1 post_spawn_health_check 301 iss-301 swarm-provstale-iss-301 "$TEST_DIR/brief-301.md"
[ -z "$(cat "$EVENTS_LOG")" ] || red "expected no log_event call for a healthy spawn, got: $(cat "$EVENTS_LOG")"
[ -f "$TEST_DIR/brief-301.md" ] || red "a healthy spawn must never remove the brief it was given"
command tmux -L "$SOCKET" list-windows -t "$SESSION" -F '#W' | grep -qx iss-301 \
    || red "a healthy spawn must never kill its own window"
command tmux -L "$SOCKET" kill-window -t "$SESSION:iss-301" 2>/dev/null || true
green "a live pane with a running container passes silently; its brief and window are untouched"

# ============================================================================
heading "Test 7: post_spawn_health_check — pane DEAD (the collision shape) -> exit 4"
# ============================================================================
command tmux -L "$SOCKET" new-window -d -t "$SESSION" -n iss-302 "exit 125"
wait_pane_dead iss-302 1 || red "setup: expected window iss-302's pane to go dead"
: > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
echo "queued" > "$TEST_DIR/brief-302.md"
: > "$HOST_STATE_DIR/pending-swarm-provstale-iss-302"
rc=0
out="$(PROVISION_SPAWN_CHECK_SECS=0.1 post_spawn_health_check 302 iss-302 swarm-provstale-iss-302 "$TEST_DIR/brief-302.md" 2>&1)" || rc=$?
[ "$rc" -eq 4 ] || red "expected exit 4 for a dead pane right after spawn, got rc=$rc, output: $out"
echo "$out" | grep -qi 'pane_dead=1' || red "expected the error to report pane_dead=1: $out"
grep -q 'worker.start.failed.*issue=302.*pane_dead=1.*brief_removed=1' "$EVENTS_LOG" \
    || red "expected a worker.start.failed log line with brief_removed=1, got: $(cat "$EVENTS_LOG")"
[ -f "$TEST_DIR/brief-302.md" ] && red "a failed spawn must remove its unclaimed brief so a retry doesn't duplicate it"
! command tmux -L "$SOCKET" list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx iss-302 \
    || red "a failed spawn must kill its window so a late-arriving pane doesn't park with an empty inbox"
[ -e "$HOST_STATE_DIR/pending-swarm-provstale-iss-302" ] \
    && red "exit 4 must remove this attempt's pending marker (self-review, 7th pass)"
green "a dead pane right after spawn exits 4 (not 0), logs worker.start.failed, kills the window, removes the unclaimed brief, and clears its pending marker — the exact gap the fand-etl incident fell through"

# ============================================================================
heading "Test 8: post_spawn_health_check — pane alive but container never came up -> exit 4"
# ============================================================================
command tmux -L "$SOCKET" new-window -d -t "$SESSION" -n iss-303 "sleep 100"
: > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
echo "queued" > "$TEST_DIR/brief-303.md"
rc=0
out="$(PROVISION_SPAWN_CHECK_SECS=0.1 post_spawn_health_check 303 iss-303 swarm-provstale-iss-303 "$TEST_DIR/brief-303.md" 2>&1)" || rc=$?
[ "$rc" -eq 4 ] || red "expected exit 4 when the container never came up, got rc=$rc, output: $out"
echo "$out" | grep -qi 'container_running=0' || red "expected the error to report container_running=0: $out"
[ -f "$TEST_DIR/brief-303.md" ] && red "a failed spawn (container never started) must also remove its unclaimed brief"
! command tmux -L "$SOCKET" list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx iss-303 \
    || red "a failed spawn must kill its window even when the pane itself was still alive (container just never started)"
green "a pane that's alive but whose container never started still exits 4, kills the window, and removes its unclaimed brief"

# ============================================================================
heading "Test 9: post_spawn_health_check — worker image not built yet -> skips the check entirely (self-review, 5th pass)"
# ============================================================================
command tmux -L "$SOCKET" new-window -d -t "$SESSION" -n iss-304 "sleep 100"
: > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
echo "queued" > "$TEST_DIR/brief-304.md"
out="$(DOCKER_IMAGE_MISSING=1 PROVISION_SPAWN_CHECK_SECS=0.1 post_spawn_health_check 304 iss-304 swarm-provstale-iss-304 "$TEST_DIR/brief-304.md" 2>&1)"
[ -z "$(cat "$EVENTS_LOG")" ] || red "expected no log_event call when the check skips itself for a missing image, got: $(cat "$EVENTS_LOG")"
echo "$out" | grep -qi 'not built yet' || red "expected a skip notice mentioning the missing image: $out"
[ -f "$TEST_DIR/brief-304.md" ] || red "skipping the check for a missing image must never remove the brief"
command tmux -L "$SOCKET" list-windows -t "$SESSION" -F '#W' | grep -qx iss-304 \
    || red "skipping the check for a missing image must never kill the window — the container may still be building"
command tmux -L "$SOCKET" kill-window -t "$SESSION:iss-304" 2>/dev/null || true
green "a cold host without the worker image yet skips the health check rather than killing an in-progress build"

# ============================================================================
heading "Test 10: post_spawn_health_check — window has vanished entirely (not just dead-paned) -> exit 4, not a set -e abort (self-review, 6th pass)"
# ============================================================================
# No window named iss-305 was ever created: remain-on-exit only keeps a
# window around for a pane that exits NON-zero, so a pane that exits 0
# leaves tmux list-panes with nothing to query at all, not pane_dead=1.
#
# Deliberately NOT the `out="$(fn ...)" || rc=$?` idiom Tests 6-9 use: that
# idiom itself happens to suppress the exact `set -e` abort bug under test
# here (calling a function from inside a command substitution whose own
# exit status will be checked disables errexit for everything inside it —
# confirmed experimentally while writing this test). provision-worker.sh's
# real call site is a bare, unconditional statement
# (`post_spawn_health_check "$ISSUE" ...`, no `||`/capture around it), so
# this test reproduces that exact shape instead: a genuinely separate bash
# subprocess, invoked as a plain statement with its exit status read
# afterward, not through `||` on the invocation itself.
: > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
echo "queued" > "$TEST_DIR/brief-305.md"
cat > "$TEST_DIR/run-305.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SESSION_NAME="$SESSION"
log_event() {
    local cat="\$1"; shift
    printf '%s  %-15s %s\n' "\$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "\$cat" "\$*" >> "$EVENTS_LOG"
}
tmux() { command tmux -L "$SOCKET" "\$@"; }
$(extract_fn post_spawn_health_check)
PROVISION_SPAWN_CHECK_SECS=0.1 post_spawn_health_check 305 iss-305 swarm-provstale-iss-305 "$TEST_DIR/brief-305.md"
EOF
set +e
bash "$TEST_DIR/run-305.sh" > "$TEST_DIR/out-305.log" 2>&1
rc=$?
set -e
out="$(cat "$TEST_DIR/out-305.log")"
[ "$rc" -eq 4 ] || red "a vanished window must still exit 4, not a set -e abort (rc=1) from tmux list-panes failing outright: rc=$rc, output: $out"
grep -q 'worker.start.failed.*issue=305.*brief_removed=1' "$EVENTS_LOG" \
    || red "expected worker.start.failed to still be logged for a vanished window, got: $(cat "$EVENTS_LOG")"
[ -f "$TEST_DIR/brief-305.md" ] && red "a vanished window must also remove its unclaimed brief, not just a dead-paned one"
green "a window that has vanished entirely (not just a dead pane) is treated as a failed spawn, not a shell-crashing set -e abort"

# ============================================================================
heading "Test 11: post_spawn_health_check — pane DEAD but container came up anyway -> container is also removed (self-review, 9th pass)"
# ============================================================================
# A container that was merely slow (not dead) can still start after its
# pane already died; left running, it would sit uncounted by any worker but
# still visible to `docker ps`, double-counting against HOST_MAX_WORKERS
# and able to draw a spawn_stagger refusal on retry — the same shape as the
# pending-marker leak fixed above, but for the container itself.
command tmux -L "$SOCKET" new-window -d -t "$SESSION" -n iss-306 "exit 125"
wait_pane_dead iss-306 1 || red "setup: expected window iss-306's pane to go dead"
echo "swarm-provstale-iss-306 running" > "$DOCKER_STATE_FILE"
: > "$EVENTS_LOG"
echo "queued" > "$TEST_DIR/brief-306.md"
rc=0
out="$(PROVISION_SPAWN_CHECK_SECS=0.1 post_spawn_health_check 306 iss-306 swarm-provstale-iss-306 "$TEST_DIR/brief-306.md" 2>&1)" || rc=$?
[ "$rc" -eq 4 ] || red "expected exit 4 for a dead pane with a container that did come up, got rc=$rc, output: $out"
[ -z "$(awk -v n=swarm-provstale-iss-306 '$1==n' "$DOCKER_STATE_FILE")" ] \
    || red "a failed spawn must remove the container too, not just the window, state: $(cat "$DOCKER_STATE_FILE")"
green "a dead pane whose container still came up has that container removed too — no orphan left for a retry to collide with"

# ============================================================================
heading "All provision-worker.sh stale-container / post-spawn health tests passed"
# ============================================================================
green "check_stale_container(): clears a leftover same-name container before spawn, refuses only when it's genuinely still live"
green "post_spawn_health_check(): a dead pane or a never-started container makes provision-worker.sh exit 4, not 0 (issue #493)"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
