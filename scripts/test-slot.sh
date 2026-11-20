#!/usr/bin/env bash
# test-slot.sh — run a command while holding one of N machine-wide "test slots".
#
# Why (issue #1026): on 2026-11-19 nine workers ran full Gradle suites at once
# (load average 157, swap 41/47 GiB). A counting semaphore capping concurrent
# test runs stops the thrash; total work is unchanged, it just queues.
#
# Usage:
#   test-slot.sh [--slots N] [--wait SECS] [--] <command...>
#
# Each slot is a flock(1) lock on $TEST_SLOT_DIR/slot-<i>. A slot is released
# by the kernel when the command exits (even on kill; the command runs with fd 8
# closed so a leftover background child cannot hold it), so a crashed worker
# never leaks one. The command's exit status is passed through.
#
# If no slot frees up within --wait seconds, the command is NOT run and the
# script exits 75 (EX_TEMPFAIL) after writing an `fyi` outbox note (when run
# inside a worktree) so the coordinator sees the queueing. Pick --wait below
# the Bash tool timeout that wraps the call (wait + test run must fit).
#
# Env (flags win):
#   TEST_SLOT_COUNT   slots (default 3)
#   TEST_SLOT_WAIT    max seconds to wait for a slot (default 240)
#   TEST_SLOT_DIR     (host-only: ignored in <project>/.swarm/.env, as is TEST_SLOT_COUNT) lock dir (default ${HOST_STATE_DIR:-$TMPDIR/llm-swarm-host-<uid>}/test-slots).
#                     It must be the SAME directory for every worker on the host:
#                     under sandbox containers that means a path on a shared mount.
#   TEST_SLOT_DISABLE=1  run the command directly, no slot (escape hatch)
#
# Exit: command's status; 75 no slot in time; 2 usage error.

set -uo pipefail

# shellcheck source=_load-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_load-env.sh" "$PWD"

slots="${TEST_SLOT_COUNT:-3}"
wait_secs="${TEST_SLOT_WAIT:-240}"
state_dir="${HOST_STATE_DIR:-${TMPDIR:-/tmp}/llm-swarm-host-$(id -u)}"
slot_dir="${TEST_SLOT_DIR:-$state_dir/test-slots}"

while [ $# -gt 0 ]; do
    case "$1" in
        --slots) slots="${2:-}"; shift 2 || exit 2 ;;
        --wait)  wait_secs="${2:-}"; shift 2 || exit 2 ;;
        --)      shift; break ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *)       break ;;
    esac
done

[ $# -gt 0 ] || { echo "test-slot.sh: no command given" >&2; exit 2; }
case "$slots" in ''|*[!0-9]*|0) echo "test-slot.sh: --slots must be a positive integer" >&2; exit 2 ;; esac
case "$wait_secs" in ''|*[!0-9]*) echo "test-slot.sh: --wait must be a non-negative integer" >&2; exit 2 ;; esac

if [ "${TEST_SLOT_DISABLE:-0}" = "1" ]; then
    exec "$@"
fi
command -v flock >/dev/null 2>&1 || { echo "test-slot.sh: flock not found, running without a slot" >&2; exec "$@"; }

mkdir -p "$slot_dir" 2>/dev/null || { echo "test-slot.sh: cannot create $slot_dir, running without a slot" >&2; exec "$@"; }

deadline=$(( $(date +%s) + wait_secs ))
announced=0
while :; do
    i=1
    while [ "$i" -le "$slots" ]; do
        # fd 8 stays open (and locked) for the life of this shell; the command
        # runs as a child with fd 8 closed (8>&-), so a background process it
        # leaves behind cannot keep the lock after the command exits (#1030).
        exec 8>"$slot_dir/slot-$i" || break 2
        if flock -n 8; then
            echo "test-slot.sh: got slot $i/$slots ($slot_dir)" >&2
            "$@" 8>&-
            exit $?
        fi
        exec 8>&-
        i=$(( i + 1 ))
    done
    if [ "$announced" = 0 ]; then
        echo "test-slot.sh: all $slots test slots busy, waiting up to ${wait_secs}s" >&2
        announced=1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "test-slot.sh: no test slot free after ${wait_secs}s; not running: $*" >&2
        if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -d "$top/.swarm/tasks" ]; then
            outbox="$top/.swarm/tasks/outbox"
            mkdir -p "$outbox"
            tmp="$(mktemp -p "$outbox" .tmp.XXXXXX)"
            cat > "$tmp" <<EOF
---
kind: fyi
task_id: ${TASK_ID:-unknown}
ts: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
test-slot: all $slots machine-wide test slots stayed busy for ${wait_secs}s, so this worker did not run its tests (command: $*). Retry later or raise TEST_SLOT_COUNT.
EOF
            mv "$tmp" "$outbox/$(date -u +%Y%m%dT%H%M%SZ)-test-slot-wait.md"
        fi
        exit 75
    fi
    sleep 2
done
echo "test-slot.sh: could not open lock files in $slot_dir, running without a slot" >&2
exec "$@"
