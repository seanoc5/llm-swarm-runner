#!/usr/bin/env bash
#
# dep-proxy.sh — control the local caching Maven/Gradle repository proxy (#331)
#
# Runs an nginx container (dep-proxy/nginx.conf) bound to 127.0.0.1 on the
# host. Every sandbox worker container already runs with --network host
# (sandbox.sh), so it's reachable inside a worker as plain
# http://localhost:<port> with zero extra networking config — see
# sandbox.sh's SANDBOX_DEP_PROXY_URL handling for how workers get pointed at
# it via a Gradle init script.
#
# This closes the gap the read-only SANDBOX_DEP_CACHE seed mount (#330)
# cannot: a cache MISS (a version bump that isn't in anyone's seed yet)
# still stampedes upstream from every worker that misses it at once.
# proxy_cache_lock in nginx.conf collapses those concurrent misses into one
# upstream fetch.
#
# Usage:
#   scripts/dep-proxy.sh up       # start (idempotent — no-ops if running)
#   scripts/dep-proxy.sh down     # stop and remove the container
#   scripts/dep-proxy.sh status   # running? + a /healthz probe
#   scripts/dep-proxy.sh logs     # follow the nginx access/error log (foreground)
#
# Env overrides:
#   DEP_PROXY_PORT            host port to bind (default: 8081)
#   DEP_PROXY_CACHE_DIR       on-disk cache dir (default: $HOME/.cache/llm-swarm-dep-proxy)
#   DEP_PROXY_CONTAINER_NAME  docker container name (default: llm-swarm-dep-proxy)
#   DEP_PROXY_IMAGE           nginx image to run (default: nginx:1.27-alpine)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

CONTAINER_NAME="${DEP_PROXY_CONTAINER_NAME:-llm-swarm-dep-proxy}"
PORT="${DEP_PROXY_PORT:-8081}"
CACHE_DIR="${DEP_PROXY_CACHE_DIR:-$HOME/.cache/llm-swarm-dep-proxy}"
IMAGE="${DEP_PROXY_IMAGE:-nginx:1.27-alpine}"

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

cmd_up() {
    mkdir -p "$CACHE_DIR"
    if is_running; then
        echo "already running: $CONTAINER_NAME (http://127.0.0.1:$PORT)"
        return 0
    fi
    # Stale stopped container from a previous run (e.g. host reboot) — clear
    # it so the name isn't taken.
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true

    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "127.0.0.1:$PORT:8080" \
        -v "$SCRIPT_DIR/dep-proxy/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$CACHE_DIR:/var/cache/nginx" \
        "$IMAGE" >/dev/null

    echo "started: $CONTAINER_NAME on http://127.0.0.1:$PORT (cache: $CACHE_DIR)"
    echo "point workers at it with: SANDBOX_DEP_PROXY_URL=http://localhost:$PORT"
}

cmd_down() {
    # Check existence ourselves rather than branching on `docker rm -f`'s
    # exit code: newer docker CLI versions treat `rm -f` on a nonexistent
    # container as success (matching `rm -f` filesystem semantics), so that
    # exit code can't distinguish "stopped it" from "was never running".
    if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
        docker rm -f "$CONTAINER_NAME" &>/dev/null
        echo "stopped: $CONTAINER_NAME"
    else
        echo "not running: $CONTAINER_NAME"
    fi
}

cmd_status() {
    if ! is_running; then
        echo "not running: $CONTAINER_NAME"
        exit 1
    fi
    docker ps --filter "name=^${CONTAINER_NAME}\$" --format 'running: {{.Names}}  {{.Status}}  {{.Ports}}'
    du -sh "$CACHE_DIR" 2>/dev/null | awk '{print "cache size: " $1}' || true
    if curl -fsS -m 5 "http://127.0.0.1:$PORT/healthz" >/dev/null; then
        echo "healthz: ok"
    else
        echo "healthz: FAILED (container is up but not answering)"
        exit 1
    fi
}

cmd_logs() {
    docker logs -f "$CONTAINER_NAME"
}

case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    logs)   cmd_logs ;;
    *)      usage; exit 1 ;;
esac
