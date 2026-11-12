#!/usr/bin/env bash
# batch-run.sh — run a command inside the user-level batch.slice (issue #491).
#
# Host-side builds started from a coordinator pane (Gradle daemons, npm,
# kotlin daemons) land in tmux-spawn-*.scope under user.slice at full weight,
# bypassing the batch.slice guard (cpu/io weight 20) that already fences the
# Docker workers and the CI runners. Running the coordinator itself through
# this wrapper makes every child it forks inherit the slice.
#
# Usage: batch-run.sh <command> [args...]
#
# Falls back to a plain `exec "$@"` when `systemd-run --user` is unusable
# (kdeyoga, containers, no user manager), so it is always safe to prefix.
# CPU weight applies at once; IO weight is a no-op until user@.service
# delegates the io controller (a root-side drop-in; see README).
#
# Env:
#   BATCH_SLICE_WEIGHT   CPUWeight/IOWeight set on the slice (default 20)
set -uo pipefail
[ $# -gt 0 ] || { echo "usage: batch-run.sh <command> [args...]" >&2; exit 2; }

if command -v systemd-run >/dev/null 2>&1 &&
   systemd-run --user --scope --slice=batch.slice --quiet -- true >/dev/null 2>&1; then
    w="${BATCH_SLICE_WEIGHT:-20}"
    # Idempotent, best-effort: creates/updates the user-level slice. No root.
    systemctl --user set-property batch.slice "CPUWeight=$w" "IOWeight=$w" >/dev/null 2>&1 || true
    exec systemd-run --user --scope --slice=batch.slice --quiet -- "$@"
fi
exec "$@"
