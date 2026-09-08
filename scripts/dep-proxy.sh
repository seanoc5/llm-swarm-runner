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
#   DEP_PROXY_NETWORK         docker network to run it on (default: llm-swarm-dep-proxy-net)
#   DEP_PROXY_IMAGE           nginx image to run (default: nginx:1.27-alpine)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

CONTAINER_NAME="${DEP_PROXY_CONTAINER_NAME:-llm-swarm-dep-proxy}"
PORT="${DEP_PROXY_PORT:-8081}"
CACHE_DIR="${DEP_PROXY_CACHE_DIR:-$HOME/.cache/llm-swarm-dep-proxy}"
# nginx.conf resolves the upstream hostnames dynamically (`resolver
# 127.0.0.11 ...`, Docker's embedded DNS) so it can re-resolve them
# periodically rather than baking in whatever IP was current at container
# start. That embedded resolver only exists on a user-defined network —
# Docker's default bridge network (what a plain `docker run` with no
# --network gets) has no DNS server at 127.0.0.11 at all, which silently
# turns every proxied request into a resolver error (caught in testing:
# nginx logs "recv() failed (111: Connection refused) while resolving" and
# every fetch 502s, while /healthz — served directly by nginx, not proxied
# — keeps reporting healthy throughout).
NETWORK_NAME="${DEP_PROXY_NETWORK:-llm-swarm-dep-proxy-net}"
IMAGE="${DEP_PROXY_IMAGE:-nginx:1.27-alpine}"

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

cmd_up() {
    mkdir -p "$CACHE_DIR"
    # nginx's worker process writes cache entries as its own container-
    # internal uid (101 in this image), not ours — the master runs as root
    # and can create the deeper proxy_cache_path subdirectories fine, but
    # if THIS top-level bind-mount source isn't at least world-traversable,
    # the worker can't reach anything under it and every request silently
    # 500s ("open() ... Permission denied" in nginx's error log) despite
    # /healthz reporting fine. A restrictive umask (or a pre-existing dir
    # someone locked down by hand) would otherwise hit exactly that, so
    # force it rather than trust whatever mkdir -p happened to produce.
    chmod 0755 "$CACHE_DIR"
    if is_running; then
        echo "already running: $CONTAINER_NAME (http://127.0.0.1:$PORT)"
        return 0
    fi
    # Stale stopped container from a previous run (e.g. host reboot) — clear
    # it so the name isn't taken.
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true

    docker network inspect "$NETWORK_NAME" &>/dev/null || docker network create "$NETWORK_NAME" >/dev/null

    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network "$NETWORK_NAME" \
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

    # /healthz is answered by nginx itself and never touches the resolver or
    # either upstream, so it stays "ok" even when proxying is fully broken
    # (e.g. the container landed on a network with no DNS resolver for the
    # `resolver` directive above — every proxied request 502s while healthz
    # keeps passing). Fetch one small, real, known-stable artifact through
    # the proxy to catch that class of failure that healthz can't see.
    # curl already writes "000" via -w on a connection failure (and exits
    # non-zero) — an `|| echo "000"` fallback here appended a SECOND "000",
    # producing "000000" (misses the `000)` case below, falls through to the
    # `*)` FAILED branch). `|| true` just absorbs curl's non-zero exit so
    # `set -e` doesn't kill the script, without adding any extra output.
    probe_code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$PORT/maven2/org/apache/maven/maven-core/3.9.6/maven-core-3.9.6.pom" 2>/dev/null || true)
    case "$probe_code" in
        200)
            echo "upstream probe (maven2): ok (200)"
            ;;
        000)
            echo "upstream probe (maven2): skipped (no response — offline, or no network egress from this shell)"
            ;;
        *)
            echo "upstream probe (maven2): FAILED (HTTP $probe_code — proxy is up but can't reach the real upstream; check nginx.conf's resolver / the docker network)"
            exit 1
            ;;
    esac
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
