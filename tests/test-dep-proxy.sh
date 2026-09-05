#!/usr/bin/env bash
#
# test-dep-proxy.sh — Shape tests for scripts/dep-proxy.sh (#331): container
# lifecycle (up/down/status) and idempotency. Runs a real nginx container on
# a scratch port so it doesn't collide with a real dep-proxy instance that
# might already be running on the default port. Does not depend on network
# egress to Maven Central / Gradle Plugin Portal — that behavior is
# documented and was hand-verified against the real upstreams (see PR body);
# this suite only exercises the container-control mechanics.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEP_PROXY="$REPO_ROOT/scripts/dep-proxy.sh"
PASS=0
FAIL=0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS + 1)); green "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); red "  ✗ $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

if [ ! -S /var/run/docker.sock ]; then
    yellow "skipping: /var/run/docker.sock not present"
    exit 0
fi

export DEP_PROXY_CONTAINER_NAME="llm-swarm-dep-proxy-test-$$"
export DEP_PROXY_PORT="18199"
export DEP_PROXY_CACHE_DIR
DEP_PROXY_CACHE_DIR="$(mktemp -d -p "$REPO_ROOT")"

cleanup() {
    docker rm -f "$DEP_PROXY_CONTAINER_NAME" &>/dev/null || true
    rm -rf "$DEP_PROXY_CACHE_DIR"
}
trap cleanup EXIT

echo "[ dep-proxy.sh lifecycle ]"

output=$("$DEP_PROXY" status 2>&1) && ec=0 || ec=$?
[[ $ec -ne 0 && "$output" == *"not running"* ]] \
    && pass "status: not-running before up (exit != 0)" \
    || fail "status: not-running before up (exit != 0)" "$output"

output=$("$DEP_PROXY" up 2>&1)
sleep 1
[[ "$output" == *"started:"* && "$output" == *"$DEP_PROXY_PORT"* ]] \
    && pass "up: starts the container" "$output" \
    || fail "up: starts the container" "$output"

output=$("$DEP_PROXY" status 2>&1) && ec=0 || ec=$?
[[ $ec -eq 0 && "$output" == *"healthz: ok"* ]] \
    && pass "status: running + healthz ok after up" \
    || fail "status: running + healthz ok after up" "$output"

output=$("$DEP_PROXY" up 2>&1)
[[ "$output" == *"already running"* ]] \
    && pass "up: idempotent (no duplicate container on second call)" \
    || fail "up: idempotent (no duplicate container on second call)" "$output"

count=$(docker ps --format '{{.Names}}' | grep -c "^${DEP_PROXY_CONTAINER_NAME}\$" || true)
[[ "$count" == "1" ]] \
    && pass "up: exactly one container running after repeated up" \
    || fail "up: exactly one container running after repeated up" "count=$count"

output=$("$DEP_PROXY" down 2>&1)
[[ "$output" == *"stopped:"* ]] \
    && pass "down: stops the container" "$output" \
    || fail "down: stops the container" "$output"

output=$("$DEP_PROXY" status 2>&1) && ec=0 || ec=$?
[[ $ec -ne 0 && "$output" == *"not running"* ]] \
    && pass "status: not-running after down" \
    || fail "status: not-running after down" "$output"

output=$("$DEP_PROXY" down 2>&1)
[[ "$output" == *"not running"* ]] \
    && pass "down: idempotent on an already-stopped proxy" "$output" \
    || fail "down: idempotent on an already-stopped proxy" "$output"

echo ""
echo "=== Results ==="
if [ "$FAIL" -eq 0 ]; then
    green "  Passed: $PASS / $((PASS + FAIL))"
else
    red "  Passed: $PASS / $((PASS + FAIL))"
fi
exit $((FAIL > 0 ? 1 : 0))
