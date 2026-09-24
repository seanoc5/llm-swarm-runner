#!/usr/bin/env bash
#
# test-shape-prompt-budget.sh — size budget for the always-loaded prompts.
#
# worker.md is every worker's system prompt and coordinator.md every
# coordinator's. Both were trimmed in 2026-07 (#207), regrew to ~52KB/~58KB
# by 2026-09 one incident paragraph at a time, and were trimmed again. This
# makes regrowth a visible decision: raise the budget here in the same PR,
# with a reason, or put the new text in a script, a docs/ page, or a
# one-clause rule instead of an incident narrative.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_MAX="${WORKER_MD_MAX_BYTES:-20000}"
COORD_MAX="${COORDINATOR_MD_MAX_BYTES:-25000}"

check() {
    local file="$1" max="$2" size
    size="$(wc -c < "$ROOT/$file")"
    [ "$size" -le "$max" ] \
        || red "$file is $size bytes, over its $max-byte budget (see header comment)"
    green "$file: $size / $max bytes"
}

check prompts/worker.md "$WORKER_MAX"
check prompts/coordinator.md "$COORD_MAX"
