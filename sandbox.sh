#!/usr/bin/env bash
#
# sandbox.sh — Generalized LLM Sandbox
set -euo pipefail

# --- Configuration ---
# Default to current directory if no path is provided
PROJECT_DIR="$(realpath "${1:-$PWD}")"
if [ $# -gt 0 ]; then shift; fi

# Determine the agent (claude, gemini, codex, listener, or bash)
AGENT="bash"
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "claude" || "$1" == "gemini" || "$1" == "codex" || "$1" == "listener" ]]; then
        AGENT="$1"
        shift
    fi
fi

IMAGE="llm-swarm-runner:latest"

# Build if image doesn't exist
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "Building sandbox image..."
    # Assumes Dockerfile is in the same directory as this script
    docker build -t "$IMAGE" "$(dirname "$0")"
fi

# Ensure host config dirs exist for persistence
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.npm-global"
if [ ! -f "$HOME/.bash_history_sandbox" ]; then
    touch "$HOME/.bash_history_sandbox"
fi
touch "$HOME/.claude.json"

# --- Mount strategy ---
# Maps host configs into the container's standard home (/home/sandbox)
MOUNTS=(
    -v "$PROJECT_DIR:$PROJECT_DIR:rw"
    -v "$HOME/.claude:/home/sandbox/.claude:rw"
    -v "$HOME/.claude.json:/home/sandbox/.claude.json:rw"
    -v "$HOME/.codex:/home/sandbox/.codex:rw"
    -v "$HOME/.ssh:$HOME/.ssh:ro"
    -v "$HOME/.ssh:/home/sandbox/.ssh:ro"
    -v "$HOME/.gitconfig:/home/sandbox/.gitconfig:ro"
    -v "$HOME/.config/gh:/home/sandbox/.config/gh:ro"
    -v "$HOME/.bash_history_sandbox:/home/sandbox/.bash_history:rw"
    -v "$HOME/.npm-global:/home/sandbox/.npm-global:rw"
    -v "$HOME/.npm:/home/sandbox/.npm:rw"
)

# ~/.gemini holds gemini-cli's settings.json (auth + MCP server config).
# Mount it ro when present so gemini workers inherit the host's MCP servers
# (e.g. open-brain) without re-configuring per-container. Skipped silently
# if the dir doesn't exist on the host.
if [ -d "$HOME/.gemini" ]; then
    MOUNTS+=(-v "$HOME/.gemini:/home/sandbox/.gemini:ro")
fi

# --- Git Worktree Support ---
# Git worktrees use a .git file containing an absolute path pointing to the
# main repository's .git directory. If this directory is outside PROJECT_DIR,
# it must be mounted for git to function inside the sandbox.
if command -v git &>/dev/null && git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    # Try --path-format=absolute (git 2.31+) fallback to realpath
    _git_common_dir="$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || realpath "$(git -C "$PROJECT_DIR" rev-parse --git-common-dir)")"
    
    # Check if the common dir was resolved, exists, and is outside PROJECT_DIR
    if [ -n "$_git_common_dir" ] && [ -d "$_git_common_dir" ]; then
        # Use realpath to handle any symlinks or relative paths for strict prefix comparison
        _proj_real="$(realpath "$PROJECT_DIR")"
        _git_real="$(realpath "$_git_common_dir")"
        if [[ "$_git_real" != "$_proj_real"* ]]; then
            MOUNTS+=("-v" "$_git_real:$_git_real:rw")
        fi
    fi
fi

# Ensure the sandbox script directory is mounted so helper scripts (like worker-listener.sh) are available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
MOUNTS+=( "-v" "$SCRIPT_DIR:$SCRIPT_DIR:ro" )

# Expose the sandbox install path and the docs subtree to the worker as env
# vars. The sandbox repo is already bind-mounted ro above (same path in
# container as on host), so $LLM_SWARM_DOCS resolves to a real directory
# inside the container. Workers use it to locate the reference-docs index
# (prompts/refs.md) and the docs themselves (e.g. docs/VCS/git-github.md).
SANDBOX_DOCS_ENV_OPTS=(
    -e "LLM_SWARM_DIR=$SCRIPT_DIR"
    -e "LLM_SWARM_DOCS=$SCRIPT_DIR/docs"
)

# Allow for additional mounts via environment variable
if [ -n "${EXTRA_MOUNTS:-}" ]; then
    IFS=',' read -ra ADDR <<< "$EXTRA_MOUNTS"
    for mount_spec in "${ADDR[@]}"; do
        # Trim leading/trailing whitespace
        shopt -s extglob
        mount_spec="${mount_spec##*( )}"
        mount_spec="${mount_spec%%*( )}"
        shopt -u extglob

        # 1. Separate options (:ro, :rw)
        options=""
        path_spec="$mount_spec"
        if [[ "$path_spec" == *:ro ]]; then
            options=":ro"
            path_spec="${path_spec%:ro}"
        elif [[ "$path_spec" == *:rw ]]; then
            options=":rw"
            path_spec="${path_spec%:rw}"
        fi

        # 2. Separate host and container paths
        host_path="$path_spec"
        container_path=""
        if [[ "$path_spec" == *":"* ]]; then
            # Use non-greedy matching from the right for host_path
            # and greedy matching from the left for container_path.
            # This handles paths with multiple colons correctly.
            host_path="${path_spec%:*}"
            container_path="${path_spec##*:}"
        fi

        # 3. If container path is empty (e.g., from "host:" or just "host"),
        #    default it to the host_path.
        if [ -z "$container_path" ]; then
            container_path="$host_path"
        fi

        # 4. Final validation for host_path.
        if [ -z "$host_path" ]; then
            echo "Error: Invalid mount specification. Host path cannot be empty in '$mount_spec'" >&2
            exit 1
        fi

        # 5. Assemble the final, valid mount string for Docker
        final_mount="${host_path}:${container_path}${options}"
        MOUNTS+=("-v" "$final_mount")
    done
fi

# Project-specific environment variables
ENV_FILE_OPT=()
if [ -f "$PROJECT_DIR/.sandbox-env" ]; then
    echo "Env file:  $PROJECT_DIR/.sandbox-env"
    ENV_FILE_OPT=(--env-file "$PROJECT_DIR/.sandbox-env")
fi

# Pass-through env vars the worker agents read. `-e VAR` (no value) tells
# Docker to pull the value from this caller's environment if set, otherwise
# omit — so we never embed values in argv.
# The WORKER_CHECK*/SWARM_EVAL_LOG group feeds worker-listener.sh's
# acceptance-check + eval-log machinery (docs/ringer-adoptions.md #1/#3);
# provision-worker.sh forwards them from <project>/.swarm/.env onto our
# command line. `-e` here outranks any --env-file (.sandbox-env) value for
# the same key — host config wins when both are set.
WORKER_ENV_OPTS=()
for _v in WORKER_HEADLESS WORKER_CMD WORKER_MODEL WORKER_SELF_REVIEW OPENAI_API_KEY \
          WORKER_CHECK WORKER_CHECK_CMD WORKER_CHECK_TIMEOUT WORKER_CHECK_RETRY SWARM_EVAL_LOG; do
    if [ -n "${!_v:-}" ]; then
        WORKER_ENV_OPTS+=(-e "$_v")
    fi
done

# Docker-outside-of-Docker: mount the host socket so Testcontainers and docker CLI work.
# --group-add gives the sandbox user permission to write to the socket.
# TESTCONTAINERS_HOST_OVERRIDE=localhost is needed with --network host so Testcontainers
# resolves mapped ports against localhost rather than the bridge IP.
# _JAVA_OPTIONS=-Dapi.version=1.45 pins the Docker Engine API version negotiated by
# Testcontainers' shaded docker-java (which otherwise defaults to 1.32 — rejected by
# Docker Engine 25+, minimum 1.40). Projects can override by setting their own
# systemProperty("api.version", ...) on the test JVM (project-level wins).
DOCKER_SOCK_OPTS=()
if [ -S /var/run/docker.sock ]; then
    DOCKER_SOCK_OPTS=(
        -v /var/run/docker.sock:/var/run/docker.sock
        --group-add "$(stat -c '%g' /var/run/docker.sock)"
        -e DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
        -e TESTCONTAINERS_HOST_OVERRIDE=localhost
        -e _JAVA_OPTIONS=-Dapi.version=1.45
    )
fi

# GitHub CLI token — gh stores the token in the system keyring on Linux, not in
# ~/.config/gh/hosts.yml, so mounting the config dir isn't enough. Read it here
# from the host and pass it in as GH_TOKEN so the CLI works without re-authing.
#
# SECURITY: We export GH_TOKEN into our own env and pass `-e GH_TOKEN` (no value)
# to docker. Docker then reads the value from our env at run time, so the token
# never appears in the container's argv (which would be visible via `ps -ef`,
# /proc/<pid>/cmdline, audit logs, and shell history).
GH_TOKEN_OPTS=()
if command -v gh &>/dev/null; then
    _gh_token=$(gh auth token 2>/dev/null)
    if [ -n "$_gh_token" ]; then
        export GH_TOKEN="$_gh_token"
        GH_TOKEN_OPTS=(-e GH_TOKEN)
    fi
    unset _gh_token
fi

# SSH Agent Forwarding
SSH_OPTS=()
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    SSH_OPTS=(-v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock" -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock)
fi

# TTY handling
INTERACTIVE_FLAGS=()
if [ -t 0 ]; then
    INTERACTIVE_FLAGS=("-it")
fi

# Optional deterministic container name. Set by provision-worker.sh so that
# external tooling (e.g. the tmux Ctrl-Z binding for iss-* windows) can
# `docker exec` into a known name. Unset for ad-hoc invocations.
NAME_OPT=()
if [ -n "${WORKER_CONTAINER_NAME:-}" ]; then
    NAME_OPT=(--name "$WORKER_CONTAINER_NAME")
fi

# Memory governor. Added after the 2026-08-01 incident where a fand-etl
# worker's full-suite pytest grew past 31 GB RSS, exhausted host RAM, and
# stalled the desktop on NVMe writeback (seanoc5/fand-etl#684). A cap makes
# a runaway process OOM-kill inside its own container (exit 137 in the
# worker log) instead of taking the host down. --memory-swap is set equal
# to --memory on purpose: without it the cgroup overflows into swap and
# recreates exactly the host-wide IO stall the cap exists to prevent.
#
# The 8g default is sized for the smallest host we expect to support
# (16 GB RAM: half for one worker, half for the OS and everything else).
# It doubles as an early tripwire: a suite that needs more than 8 GB is
# usually load-everything-into-memory code smell worth a look before it
# grows into a 31 GB one. Beefy hosts raise it at provision time
# (e.g. SANDBOX_MEM_LIMIT=24g on a 128 GB box); "0" disables the cap
# entirely (ad-hoc debugging only).
MEM_OPTS=()
SANDBOX_MEM_LIMIT="${SANDBOX_MEM_LIMIT:-8g}"
if [ "$SANDBOX_MEM_LIMIT" != "0" ]; then
    MEM_OPTS=(--memory "$SANDBOX_MEM_LIMIT" --memory-swap "$SANDBOX_MEM_LIMIT")
fi

# Get the directory of this script so we can find worker-listener.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Worker agent selection. WORKER_CMD chooses the LLM CLI the listener will
# dispatch to (default claude). The listener picks up the choice from its
# first arg here; WORKER_MODEL is read by the listener directly from the
# container's env (already passed-through above via WORKER_ENV_OPTS).
WORKER_AGENT="${WORKER_CMD:-claude}"

# Construct command as an array
CMD_ARRAY=()
if [[ $# -eq 0 ]]; then
    case "$AGENT" in
        claude)   CMD_ARRAY=("claude" "--dangerously-skip-permissions") ;;
        gemini)   CMD_ARRAY=("gemini" "--yolo") ;;
        codex)    CMD_ARRAY=("codex" "--dangerously-bypass-approvals-and-sandbox" "--no-alt-screen") ;;
        listener) CMD_ARRAY=("$SCRIPT_DIR/scripts/worker-listener.sh" "$WORKER_AGENT") ;;
        *)        CMD_ARRAY=("bash" "-i") ;;
    esac
else
    case "$AGENT" in
        claude)   CMD_ARRAY=("claude" "$@" "--dangerously-skip-permissions") ;;
        gemini)   CMD_ARRAY=("gemini" "$@" "--yolo") ;;
        codex)    CMD_ARRAY=("codex" "$@" "--dangerously-bypass-approvals-and-sandbox" "--no-alt-screen") ;;
        listener) CMD_ARRAY=("$SCRIPT_DIR/scripts/worker-listener.sh" "$@" "--dangerously-skip-permissions") ;;
        *)        CMD_ARRAY=("bash" "-c" "$*") ;;
    esac
fi

echo "--- LLM Sandbox Session ---"
echo "Project:  $PROJECT_DIR"
echo "Agent:    $AGENT"
echo "---------------------------"

exec docker run "${INTERACTIVE_FLAGS[@]}" --rm --init \
    "${NAME_OPT[@]}" \
    "${MEM_OPTS[@]}" \
    --network host \
    --user "$(id -u):$(id -g)" \
    --workdir "$PROJECT_DIR" \
    "${ENV_FILE_OPT[@]}" \
    "${GH_TOKEN_OPTS[@]}" \
    "${DOCKER_SOCK_OPTS[@]}" \
    "${SSH_OPTS[@]}" \
    "${WORKER_ENV_OPTS[@]}" \
    "${SANDBOX_DOCS_ENV_OPTS[@]}" \
    "${MOUNTS[@]}" \
    -e "TERM=$TERM" \
    -e "COLORTERM=${COLORTERM:-}" \
    -e "BROWSER=echo" \
    "$IMAGE" \
    "${CMD_ARRAY[@]}"
