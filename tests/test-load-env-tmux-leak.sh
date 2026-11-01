#!/usr/bin/env bash
# Issue #660: keys _load-env.sh fills from .env.example must not leak into a
# tmux server's global env, or they mask <project>/.swarm/.env overrides.
# Replays the llm-start.sh subshell-unset pattern against a throwaway socket.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v tmux >/dev/null || { echo "SKIP: no tmux"; exit 0; }
T="$(mktemp -d)"; SOCK="t660-$$"
trap 'command tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/sb" "$T/proj/.swarm"
echo 'SANDBOX_KOTLIN_DAEMON_XMX=1536m' > "$T/sb/.env.example"
echo 'SANDBOX_KOTLIN_DAEMON_XMX=4096m' > "$T/proj/.swarm/.env"
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }

# 1. project tier wins when loaded without the leak
v="$(env -u SANDBOX_KOTLIN_DAEMON_XMX LLM_SWARM_DIR="$T/sb" bash -c '. "$0/scripts/_load-env.sh" "$1"; echo "$SANDBOX_KOTLIN_DAEMON_XMX"' "$ROOT" "$T/proj")"
[ "$v" = 4096m ] && ok "project override wins" || bad "project override got $v"

# 2. server started from a loader-polluted shell, with the llm-start scrub
(
  unset SANDBOX_KOTLIN_DAEMON_XMX; export LLM_SWARM_DIR="$T/sb"
  . "$ROOT/scripts/_load-env.sh" "$T/nonexistent"
  for _k in ${SWARM_ENV_FILE_KEYS:-}; do unset "$_k"; done
  command tmux -L "$SOCK" -f /dev/null new-session -d -s s
)
g="$(command tmux -L "$SOCK" show-environment -g SANDBOX_KOTLIN_DAEMON_XMX 2>&1 || true)"
case "$g" in *1536m*) bad "default leaked into tmux global env: $g";; *) ok "default not in tmux global env";; esac

# 3. a deliberate caller export is kept
command tmux -L "$SOCK" kill-server 2>/dev/null || true
(
  export SANDBOX_KOTLIN_DAEMON_XMX=2048m LLM_SWARM_DIR="$T/sb"
  . "$ROOT/scripts/_load-env.sh" "$T/nonexistent"
  for _k in ${SWARM_ENV_FILE_KEYS:-}; do unset "$_k"; done
  command tmux -L "$SOCK" -f /dev/null new-session -d -s s
)
g="$(command tmux -L "$SOCK" show-environment -g SANDBOX_KOTLIN_DAEMON_XMX 2>&1 || true)"
case "$g" in *2048m*) ok "deliberate export kept";; *) bad "deliberate export lost: $g";; esac
exit $fail
