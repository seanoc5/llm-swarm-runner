#!/usr/bin/env bash
#
# test-shape-compose-down.sh — Non-LLM shape tests for
# _compose-down-for-worktree.sh (issue #105 teardown helper, issue #303
# multi-filename + label-sweep hardening) and its --no-compose-down
# opt-out wired into kill-worktree.sh.
#
# Stubs `docker` via PATH override for the shape tests below — no real
# compose stack, no daemon required. A final real-docker regression test
# (issue #303 acceptance criterion) runs against the actual docker daemon
# when one is reachable; it self-skips otherwise.
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

REAL_DOCKER="$(command -v docker || true)"

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
#
# Handles the three call shapes the script makes:
#   docker compose -f <file> --project-directory <wt> down ...   (may fail)
#   docker ps -aq --filter label=com.docker.compose.project=<p>  (label sweep)
#   docker volume ls -q --filter label=com.docker.compose.project=<p>
#   docker rm -f -v <ids> / docker volume rm -f <ids>
#
# STUB_CONTAINERS_FILE / STUB_VOLUMES_FILE / STUB_NETWORKS_FILE (if
# present) supply the ids the sweep "finds"; FAIL_COMPOSE_FLAG (if
# present) makes `compose ... down` fail/exit non-zero to exercise the
# WARN + fallback-to-sweep path.

export DOCKER_LOG="$TEST_DIR/docker.log"
export STUB_CONTAINERS_FILE="$TEST_DIR/stub-containers"
export STUB_VOLUMES_FILE="$TEST_DIR/stub-volumes"
export STUB_NETWORKS_FILE="$TEST_DIR/stub-networks"
export FAIL_COMPOSE_FLAG="$TEST_DIR/fail-compose"
: > "$DOCKER_LOG"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
    compose)
        [ -f "$FAIL_COMPOSE_FLAG" ] && exit 1
        exit 0
        ;;
    ps)
        [ -f "$STUB_CONTAINERS_FILE" ] && cat "$STUB_CONTAINERS_FILE"
        exit 0
        ;;
    volume)
        if [ "$2" = "ls" ]; then
            [ -f "$STUB_VOLUMES_FILE" ] && cat "$STUB_VOLUMES_FILE"
        fi
        exit 0
        ;;
    network)
        if [ "$2" = "ls" ]; then
            [ -f "$STUB_NETWORKS_FILE" ] && cat "$STUB_NETWORKS_FILE"
        fi
        exit 0
        ;;
    rm)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH"

reset_stub() {
    : > "$DOCKER_LOG"
    rm -f "$STUB_CONTAINERS_FILE" "$STUB_VOLUMES_FILE" "$STUB_NETWORKS_FILE" "$FAIL_COMPOSE_FLAG"
}

# ============================================================================
heading "Test 1: no compose file — says so, sweeps by label, no leftovers"
# ============================================================================
mkdir -p "$TEST_DIR/wt-no-compose"
reset_stub
OUT=$("$COMPOSE_DOWN" "$TEST_DIR/wt-no-compose" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 with no compose file, got $RC"
echo "$OUT" | grep -q "no compose file in $TEST_DIR/wt-no-compose" \
    || red "expected an explicit 'no compose file' line (never a silent no-op), got: $OUT"
echo "$OUT" | grep -q "checking for a labelled stack anyway" \
    || red "expected the label-sweep fallback to be announced, got: $OUT"
grep -q "^ps -aq --filter label=com.docker.compose.project=wt-no-compose$" "$DOCKER_LOG" \
    || red "expected a 'docker ps --filter label=...' sweep call; got: $(cat "$DOCKER_LOG")"
grep -q "^volume ls -q --filter label=com.docker.compose.project=wt-no-compose$" "$DOCKER_LOG" \
    || red "expected a 'docker volume ls --filter label=...' sweep call; got: $(cat "$DOCKER_LOG")"
grep -q "^rm " "$DOCKER_LOG" && red "no leftovers were stubbed — 'docker rm' should not have run"
green "no compose file: no silent no-op, label sweep runs and finds nothing to remove"

# ============================================================================
heading "Test 2: label sweep removes leftovers even with no compose file"
# ============================================================================
reset_stub
printf 'deadbeef0001\n' > "$STUB_CONTAINERS_FILE"
printf 'wt-no-compose_pgdata\n' > "$STUB_VOLUMES_FILE"
OUT=$("$COMPOSE_DOWN" "$TEST_DIR/wt-no-compose" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC"
echo "$OUT" | grep -q "sweep: removing 1 leftover container(s)" \
    || red "expected the sweep to report the leftover container, got: $OUT"
echo "$OUT" | grep -q "sweep: removing 1 leftover volume(s)" \
    || red "expected the sweep to report the leftover volume, got: $OUT"
grep -q "^rm -f -v deadbeef0001$" "$DOCKER_LOG" \
    || red "expected 'docker rm -f -v deadbeef0001'; got: $(cat "$DOCKER_LOG")"
grep -q "^volume rm -f wt-no-compose_pgdata$" "$DOCKER_LOG" \
    || red "expected 'docker volume rm -f wt-no-compose_pgdata'; got: $(cat "$DOCKER_LOG")"
green "label sweep removes containers/volumes tagged for the project, absent any compose file"

# ============================================================================
heading "Test 3: compose file discovery covers every standard/non-standard name"
# ============================================================================
for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml docker-compose.test.yml; do
    WTN="$TEST_DIR/wt-$name"
    mkdir -p "$WTN"
    : > "$WTN/$name"
    reset_stub
    OUT=$("$COMPOSE_DOWN" "$WTN" 2>&1) && RC=0 || RC=$?
    [ "$RC" -eq 0 ] || red "[$name] expected exit 0, got $RC"
    echo "$OUT" | grep -q "found $WTN/$name" \
        || red "[$name] expected 'found <compose file>' line, got: $OUT"
    grep -q "^compose -f $WTN/$name --project-directory $WTN down --remove-orphans --volumes$" "$DOCKER_LOG" \
        || red "[$name] expected the compose down invocation to use this exact file; got: $(cat "$DOCKER_LOG")"
    green "discovered and used $name"
done

# ============================================================================
heading "Test 4: standard-name precedence when multiple compose files exist"
# ============================================================================
WTP="$TEST_DIR/wt-precedence"
mkdir -p "$WTP"
: > "$WTP/docker-compose.yml"
: > "$WTP/compose.yaml"
reset_stub
OUT=$("$COMPOSE_DOWN" "$WTP" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC"
echo "$OUT" | grep -q "found $WTP/compose.yaml" \
    || red "expected compose.yaml (highest precedence) to win over docker-compose.yml, got: $OUT"
green "compose.yaml takes precedence over docker-compose.yml, matching \`docker compose\`'s own order"

# ============================================================================
heading "Test 5: COMPOSE_PROJECT_NAME from .env is honoured"
# ============================================================================
WTE="$TEST_DIR/wt-envname"
mkdir -p "$WTE"
: > "$WTE/docker-compose.yml"
printf 'SOME_OTHER_VAR=x\nCOMPOSE_PROJECT_NAME="custom-proj-name"\n' > "$WTE/.env"
reset_stub
OUT=$("$COMPOSE_DOWN" "$WTE" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC"
echo "$OUT" | grep -q "project custom-proj-name" \
    || red "expected the .env COMPOSE_PROJECT_NAME to override the basename-derived name, got: $OUT"
grep -q "label=com.docker.compose.project=custom-proj-name" "$DOCKER_LOG" \
    || red "expected the label sweep to filter on the .env project name; got: $(cat "$DOCKER_LOG")"
grep -q "label=com.docker.compose.project=wt-envname" "$DOCKER_LOG" \
    && red ".env project name should replace the worktree-basename fallback, not just add to it"
green ".env COMPOSE_PROJECT_NAME wins over the worktree basename, for both compose down and the sweep"

# ============================================================================
heading "Test 6: compose down failure/timeout still runs the label sweep"
# ============================================================================
WTF="$TEST_DIR/wt-fail"
mkdir -p "$WTF"
: > "$WTF/docker-compose.yml"
reset_stub
: > "$FAIL_COMPOSE_FLAG"
printf 'leftover-container\n' > "$STUB_CONTAINERS_FILE"
OUT=$("$COMPOSE_DOWN" "$WTF" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0 even when docker compose fails/times out, got $RC"
echo "$OUT" | grep -q "WARN: compose down failed or timed out" \
    || red "expected a WARN line on compose-down failure, got: $OUT"
echo "$OUT" | grep -q "falling back to label sweep" \
    || red "expected the WARN to say it's falling back to the label sweep, got: $OUT"
echo "$OUT" | grep -q "sweep: removing 1 leftover container(s)" \
    || red "expected the sweep to still run and remove the leftover after the compose failure, got: $OUT"
green "a failed/timed-out compose down no longer abandons cleanup — the label sweep still runs"

# ============================================================================
heading "Test 7: label sweep only ever targets this project's label"
# ============================================================================
reset_stub
OUT=$("$COMPOSE_DOWN" "$TEST_DIR/wt-no-compose" 2>&1) && RC=0 || RC=$?
FILTERS=$(grep -oE 'label=com\.docker\.compose\.project=[^ ]+' "$DOCKER_LOG" | sort -u)
COUNT=$(printf '%s\n' "$FILTERS" | grep -c .)
[ "$COUNT" -eq 1 ] || red "expected every docker call to filter on exactly one project label, got: $FILTERS"
echo "$FILTERS" | grep -q "^label=com\.docker\.compose\.project=wt-no-compose$" \
    || red "expected the filter to name wt-no-compose, got: $FILTERS"
green "every ps/volume-ls/network-ls/rm call is scoped to this worktree's single project label"

# ============================================================================
heading "Test 8: project name is normalized the way docker compose normalizes it"
# ============================================================================
# docker compose lowercases the project name and replaces any character
# outside [a-z0-9_-] with '_' before stamping the label. A worktree/.env
# name that isn't already lowercase-safe must be normalized the same way,
# or the sweep's filter never matches what compose actually wrote.
WTU="$TEST_DIR/wt-Upper.Name"
mkdir -p "$WTU"
reset_stub
OUT=$("$COMPOSE_DOWN" "$WTU" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC"
grep -q "label=com\.docker\.compose\.project=wt-upper_name" "$DOCKER_LOG" \
    || red "expected the filter to use the normalized name wt-upper_name; got: $(cat "$DOCKER_LOG")"
grep -q "label=com\.docker\.compose\.project=wt-Upper.Name" "$DOCKER_LOG" \
    && red "raw un-normalized worktree name leaked into the label filter"
green "worktree basename wt-Upper.Name normalizes to wt-upper_name for the label filter (hyphens are valid, dots/uppercase are not)"

WTE2="$TEST_DIR/wt-envcase"
mkdir -p "$WTE2"
printf 'COMPOSE_PROJECT_NAME=Custom.Proj\n' > "$WTE2/.env"
reset_stub
OUT=$("$COMPOSE_DOWN" "$WTE2" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC"
grep -q "label=com\.docker\.compose\.project=custom_proj" "$DOCKER_LOG" \
    || red "expected the .env project name to normalize to custom_proj too; got: $(cat "$DOCKER_LOG")"
green ".env COMPOSE_PROJECT_NAME is normalized the same way, not just the worktree-basename fallback"

# ============================================================================
heading "Test 9: label sweep also removes leftover networks"
# ============================================================================
reset_stub
printf 'net-deadbeef\n' > "$STUB_NETWORKS_FILE"
OUT=$("$COMPOSE_DOWN" "$TEST_DIR/wt-no-compose" 2>&1) && RC=0 || RC=$?
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC"
echo "$OUT" | grep -q "sweep: removing 1 leftover network(s)" \
    || red "expected the sweep to report the leftover network, got: $OUT"
grep -q "^network rm net-deadbeef$" "$DOCKER_LOG" \
    || red "expected 'docker network rm net-deadbeef'; got: $(cat "$DOCKER_LOG")"
green "label sweep removes leftover networks tagged for the project, alongside containers/volumes"

reset_stub

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
heading "Test 10: kill-worktree.sh --no-compose-down skips the teardown"
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
heading "Test 11: kill-worktree.sh (default) runs compose-down before removal"
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

# ══════════════════════ Real-docker regression test (issue #303) ═══════════
#
# Acceptance criterion: create a worktree with docker-compose.yaml, bring
# up a named-volume stack, reap it, assert zero volumes remain matching
# com.docker.compose.project=<project>. Needs the real docker daemon —
# skips cleanly when one isn't reachable (e.g. no docker-in-docker here).

heading "Test 12: real-docker regression — named volume is gone after teardown"
if [ -z "$REAL_DOCKER" ] || ! "$REAL_DOCKER" info >/dev/null 2>&1; then
    yellow "SKIP: no reachable docker daemon in this environment"
else
    RWT="$TEST_DIR/wt-real-regress"
    mkdir -p "$RWT"
    PROJ="wt-issue-303-regress-$$"
    cat > "$RWT/docker-compose.yaml" <<EOF
services:
  app:
    image: busybox:latest
    command: ["sh", "-c", "echo hi > /data/marker && sleep 3600"]
    volumes:
      - appdata:/data
volumes:
  appdata: {}
EOF
    printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJ" > "$RWT/.env"

    # PATH still has the stub docker prepended from the shape tests above —
    # use the real binary explicitly for this integration test.
    "$REAL_DOCKER" compose -f "$RWT/docker-compose.yaml" --project-directory "$RWT" \
        --project-name "$PROJ" up -d --quiet-pull >/dev/null
    VOL_BEFORE=$("$REAL_DOCKER" volume ls -q --filter "label=com.docker.compose.project=$PROJ")
    [ -n "$VOL_BEFORE" ] || red "setup failed: expected a named volume for project $PROJ to exist"

    PATH="$(dirname "$REAL_DOCKER"):$PATH" "$COMPOSE_DOWN" "$RWT" >"$TEST_DIR/regress-out.log" 2>&1 \
        || red "compose-down helper exited non-zero: $(cat "$TEST_DIR/regress-out.log")"

    VOL_AFTER=$("$REAL_DOCKER" volume ls -q --filter "label=com.docker.compose.project=$PROJ")
    CONT_AFTER=$("$REAL_DOCKER" ps -aq --filter "label=com.docker.compose.project=$PROJ")
    [ -z "$VOL_AFTER" ] || { "$REAL_DOCKER" volume rm -f $VOL_AFTER >/dev/null 2>&1; red "volume(s) survived teardown: $VOL_AFTER"; }
    [ -z "$CONT_AFTER" ] || { "$REAL_DOCKER" rm -f -v $CONT_AFTER >/dev/null 2>&1; red "container(s) survived teardown: $CONT_AFTER"; }
    green "real docker-compose.yaml stack + named volume: zero volumes/containers remain for project $PROJ"
fi

# ============================================================================
heading "All compose-down shape tests passed"
# ============================================================================
green "discovery / label sweep / .env project name / failure-fallback / kill-worktree.sh wiring"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
