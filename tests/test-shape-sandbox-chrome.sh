#!/usr/bin/env bash
#
# test-shape-sandbox-chrome.sh — workers must not touch the operator's
# Claude in Chrome bridge (#518). sandbox.sh shadows ~/.claude/chrome with
# a tmpfs and worker-listener.sh passes --no-chrome on every claude launch.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -qE 'type=tmpfs,destination=/home/sandbox/\.claude/chrome' "$ROOT/sandbox.sh" \
    || red "sandbox.sh no longer shadows /home/sandbox/.claude/chrome with a tmpfs"
green "sandbox.sh: tmpfs over ~/.claude/chrome"

launches=$(grep -cE '\| claude "\$\{MODEL_OPTS\[@\]\}"' "$ROOT/scripts/worker-listener.sh")
with_flag=$(grep -E '\| claude "\$\{MODEL_OPTS\[@\]\}"' "$ROOT/scripts/worker-listener.sh" | grep -c -- '--no-chrome')
[ "$launches" -gt 0 ] || red "could not find the claude launch lines in worker-listener.sh"
[ "$launches" -eq "$with_flag" ] || red "worker-listener.sh: $with_flag of $launches claude launches pass --no-chrome"
green "worker-listener.sh: --no-chrome on all $launches claude launches"
