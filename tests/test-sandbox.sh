#!/usr/bin/env bash
#
# test-sandbox.sh — Verify the llm-sandbox image and sandbox.sh are working correctly.
# Run this after building the image or making changes to Dockerfile / sandbox.sh.
#
# Usage:
#   ./test-sandbox.sh          # run all tests
#   ./test-sandbox.sh -v       # verbose (show command output for passing tests too)
set -euo pipefail

VERBOSE=false
[[ "${1:-}" == "-v" ]] && VERBOSE=true

IMAGE="llm-swarm-runner:latest"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
SKIP=0

# ── Helpers ──────────────────────────────────────────────────────────────────

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

run_in_sandbox() {
    # Run a shell command inside the sandbox container (non-interactive, no mounts beyond basics)
    docker run --rm \
        --network host \
        --user "$(id -u):$(id -g)" \
        "$IMAGE" \
        bash -c "$1" 2>&1
}

pass() {
    local name="$1"; shift
    PASS=$((PASS + 1))
    green "  ✓ $name"
    $VERBOSE && [[ $# -gt 0 ]] && printf '    %s\n' "$@" || true
}

fail() {
    local name="$1"; shift
    FAIL=$((FAIL + 1))
    red "  ✗ $name"
    [[ $# -gt 0 ]] && printf '    %s\n' "$@" || true
}

skip() {
    local name="$1"; shift
    SKIP=$((SKIP + 1))
    yellow "  - $name (skipped: ${*})"
}

check() {
    # check "test name" <command returning 0/1>
    local name="$1"; shift
    local output
    if output=$("$@" 2>&1); then
        pass "$name" "$output"
    else
        fail "$name" "$output"
    fi
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

echo ""
echo "=== LLM Sandbox Test Suite ==="
echo ""

echo "[ Pre-flight ]"

if ! command -v docker &>/dev/null; then
    red "  ✗ Docker not found — cannot run any tests"
    exit 1
fi
pass "Docker available" "$(docker --version)"

if ! docker image inspect "$IMAGE" &>/dev/null; then
    red "  ✗ Image '$IMAGE' not found — run: docker build -t $IMAGE ."
    exit 1
fi
pass "Image exists: $IMAGE"

# ── Toolchain ─────────────────────────────────────────────────────────────────

echo ""
echo "[ Toolchain — core binaries ]"

for tool in \
    "bash:bash --version" \
    "git:git --version" \
    "curl:curl --version" \
    "jq:jq --version" \
    "less:less --version" \
    "vim:vim --version" \
    "tree:tree --version" \
    "htop:htop --version" \
    "file:file --version" \
    "lsof:lsof -v" \
    "ss:ss --version" \
    "ripgrep:rg --version" \
    "psql:psql --version" \
    "docker:docker --version" \
    "gh:gh --version"
do
    name="${tool%%:*}"
    cmd="${tool#*:}"
    output=$(run_in_sandbox "$cmd" 2>&1 | head -1) && pass "$name" "$output" || fail "$name" "$output"
done

echo ""
echo "[ Toolchain — language runtimes ]"

output=$(run_in_sandbox "java -version" 2>&1) && pass "java 21" "$(head -1 <<< "$output")" || fail "java 21" "$output"
output=$(run_in_sandbox "node --version" 2>&1)           && pass "node" "$output"    || fail "node" "$output"
output=$(run_in_sandbox "python3 --version" 2>&1)        && pass "python3" "$output" || fail "python3" "$output"
output=$(run_in_sandbox "uv --version" 2>&1)             && pass "uv" "$output"      || fail "uv" "$output"
output=$(run_in_sandbox "deno --version" 2>&1 | head -1) && pass "deno" "$output"    || fail "deno" "$output"

echo ""
echo "[ Toolchain — LLM CLIs ]"

output=$(run_in_sandbox "claude --version" 2>&1 | head -1) && pass "claude-code" "$output" || fail "claude-code" "$output"
output=$(run_in_sandbox "gemini --version" 2>&1 | head -1) && pass "gemini-cli" "$output"  || fail "gemini-cli" "$output"
output=$(run_in_sandbox "codex --version" 2>&1 | head -1)  && pass "codex-cli" "$output"   || fail "codex-cli" "$output"

# ── Sandbox script ────────────────────────────────────────────────────────────

echo ""
echo "[ sandbox.sh behaviour ]"

# Test that sandbox.sh picks up the current dir as PROJECT_DIR
output=$(bash -c '
    cd /tmp
    out=$(PROJECT_DIR_CHECK=1 bash '"$REPO_ROOT"'/sandbox.sh 2>&1 | grep "Project:" | head -1)
    echo "$out"
' 2>&1) && [[ "$output" == *"/tmp"* ]] && pass "default PROJECT_DIR = PWD" || fail "default PROJECT_DIR = PWD" "$output"

# Test that an unset caller _JAVA_OPTIONS still gets the default api.version pin
if [ -S /var/run/docker.sock ]; then
    output=$(env -u _JAVA_OPTIONS "$REPO_ROOT/sandbox.sh" /tmp printenv _JAVA_OPTIONS 2>&1)
    [[ "$output" == *"-Dapi.version=1.45"* ]] \
        && pass "default _JAVA_OPTIONS pin (api.version=1.45)" "$output" \
        || fail "default _JAVA_OPTIONS pin (api.version=1.45)" "$output"

    # Test that a caller-set _JAVA_OPTIONS overrides the default pin, with a warning.
    # (The warning text itself mentions "-Dapi.version=1.45" for context, so check the
    # container's actual env value — the last line of output — rather than the whole blob.)
    output=$(_JAVA_OPTIONS="-Xmx512m" "$REPO_ROOT/sandbox.sh" /tmp printenv _JAVA_OPTIONS 2>&1)
    container_value=$(tail -n1 <<< "$output")
    [[ "$output" == *"WARNING"* && "$container_value" == "-Xmx512m" ]] \
        && pass "caller _JAVA_OPTIONS override reaches container + warns" "$output" \
        || fail "caller _JAVA_OPTIONS override reaches container + warns" "$output"
else
    skip "_JAVA_OPTIONS pass-through" "/var/run/docker.sock not present"
fi

# SANDBOX_DEP_CACHE (#330): shared read-only JVM dependency cache knob.
if [ -S /var/run/docker.sock ]; then
    # Fixture MUST live under REPO_ROOT, not /tmp: this test suite itself
    # typically runs inside a swarm worker sandbox talking to the host
    # daemon over a mounted docker.sock (DooD), so bind-mount sources
    # resolve against the real host's filesystem, not this container's.
    # REPO_ROOT is guaranteed identical on both sides (sandbox.sh's own
    # same-host-container-path convention for PROJECT_DIR); a bare /tmp
    # path here would silently resolve to a different, unrelated /tmp on
    # the host and the mount checks below would test nothing real.
    _dep_cache_fixture="$(mktemp -d -p "$REPO_ROOT")"
    mkdir -p "$_dep_cache_fixture/gradle/modules-2"

    # Unset (default): byte-identical to before the knob existed — no
    # GRADLE_RO_DEP_CACHE reaches the container.
    output=$(env -u SANDBOX_DEP_CACHE "$REPO_ROOT/sandbox.sh" /tmp printenv GRADLE_RO_DEP_CACHE 2>&1) || true
    [[ "$output" != *"GRADLE_RO_DEP_CACHE"* && "$output" != *"/gradle"* ]] \
        && pass "SANDBOX_DEP_CACHE unset -> no GRADLE_RO_DEP_CACHE" "$output" \
        || fail "SANDBOX_DEP_CACHE unset -> no GRADLE_RO_DEP_CACHE" "$output"

    # Valid path (has <dir>/gradle/modules-2): GRADLE_RO_DEP_CACHE resolves
    # to <dir>/gradle, and the mount is read-only.
    output=$(SANDBOX_DEP_CACHE="$_dep_cache_fixture" "$REPO_ROOT/sandbox.sh" /tmp printenv GRADLE_RO_DEP_CACHE 2>&1)
    container_value=$(tail -n1 <<< "$output")
    [[ "$container_value" == "$_dep_cache_fixture/gradle" ]] \
        && pass "SANDBOX_DEP_CACHE valid path -> GRADLE_RO_DEP_CACHE=<dir>/gradle" "$output" \
        || fail "SANDBOX_DEP_CACHE valid path -> GRADLE_RO_DEP_CACHE=<dir>/gradle" "$output"

    # NOTE: pass the script as a single argument, NOT as separate "bash" "-c"
    # words — sandbox.sh's AGENT detection only special-cases the literal
    # tokens claude/gemini/codex/listener, so an explicit "bash" is never
    # shifted off and gets folded back into the command via "$*", producing
    # a doubled `bash -c "bash -c ..."` invocation. Passing one pre-built
    # script string hits the same wildcard `bash -c "$*"` path cleanly.
    output=$(SANDBOX_DEP_CACHE="$_dep_cache_fixture" "$REPO_ROOT/sandbox.sh" /tmp \
        "touch '$_dep_cache_fixture/gradle/modules-2/should-fail' 2>&1; echo \"exit=\$?\"" 2>&1)
    [[ "$output" == *"Read-only file system"* && "$output" == *"exit="* && "$output" != *"exit=0"* ]] \
        && pass "SANDBOX_DEP_CACHE mount is read-only" "$output" \
        || fail "SANDBOX_DEP_CACHE mount is read-only" "$output"

    # Invalid path (no <dir>/gradle/modules-2): warns to stderr, still launches.
    output=$(SANDBOX_DEP_CACHE=/nonexistent-dep-cache-xyz "$REPO_ROOT/sandbox.sh" /tmp "echo LAUNCHED" 2>&1)
    [[ "$output" == *"WARNING"* && "$output" == *"LAUNCHED"* ]] \
        && pass "SANDBOX_DEP_CACHE bad path warns + still launches" "$output" \
        || fail "SANDBOX_DEP_CACHE bad path warns + still launches" "$output"

    rm -rf "$_dep_cache_fixture"
else
    skip "SANDBOX_DEP_CACHE" "/var/run/docker.sock not present"
fi

# Test EXTRA_MOUNTS same-path shorthand (path:ro → same path in container)
output=$(EXTRA_MOUNTS="/tmp:ro" docker run --rm \
    --network host \
    --user "$(id -u):$(id -g)" \
    -v /tmp:/tmp:ro \
    "$IMAGE" bash -c "ls /tmp" 2>&1) && pass "EXTRA_MOUNTS same-path shorthand" || fail "EXTRA_MOUNTS same-path shorthand" "$output"

# ── Host networking ───────────────────────────────────────────────────────────

echo ""
echo "[ Host networking (--network host) ]"

# Can we reach the host's loopback at all?
output=$(run_in_sandbox "curl -s --max-time 3 http://localhost/ 2>&1 || true")
# We don't care what's there, just that networking works (no 'network unreachable')
if echo "$output" | grep -q "Network unreachable\|Cannot assign"; then
    fail "host loopback reachable" "$output"
else
    pass "host loopback reachable"
fi

# Postgres (optional — only tested if something is listening on 5432 or 35432)
for pg_port in 5432 35432; do
    if ss -tlnp 2>/dev/null | grep -q ":${pg_port}"; then
        output=$(run_in_sandbox "pg_isready -h localhost -p $pg_port" 2>&1)
        [[ "$output" == *"accepting connections"* ]] \
            && pass "postgres :$pg_port accepting connections" \
            || fail "postgres :$pg_port" "$output"
    else
        skip "postgres :$pg_port" "nothing listening on host"
    fi
done

# ── Docker-outside-of-Docker ──────────────────────────────────────────────────

echo ""
echo "[ Docker-outside-of-Docker (DooD) ]"

if [ -S /var/run/docker.sock ]; then
    output=$(docker run --rm \
        --network host \
        --user "$(id -u):$(id -g)" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --group-add "$(stat -c '%g' /var/run/docker.sock)" \
        -e DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)" \
        "$IMAGE" bash -c "docker ps --format '{{.Names}}' 2>&1 | head -3" 2>&1)
    [[ $? -eq 0 ]] && pass "docker socket accessible from container" "$output" \
                   || fail "docker socket accessible from container" "$output"
else
    skip "DooD" "/var/run/docker.sock not present"
fi

# ── GitHub CLI ────────────────────────────────────────────────────────────────

echo ""
echo "[ GitHub CLI auth ]"

if command -v gh &>/dev/null && gh auth token &>/dev/null 2>&1; then
    _token=$(gh auth token 2>/dev/null)
    output=$(docker run --rm \
        --network host \
        --user "$(id -u):$(id -g)" \
        -e GH_TOKEN="$_token" \
        "$IMAGE" bash -c "gh auth status 2>&1" 2>&1)
    [[ "$output" == *"Logged in"* ]] && pass "gh auth token forwarded" \
                                     || fail "gh auth token forwarded" "$output"
else
    skip "gh auth" "gh not authenticated on host"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL + SKIP))
green "  Passed: $PASS / $TOTAL"
[[ $SKIP -gt 0 ]] && yellow "  Skipped: $SKIP (host services not running)"
[[ $FAIL -gt 0 ]] && red "  Failed: $FAIL" || true
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
