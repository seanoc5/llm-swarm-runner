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
#
# 2026-09-29: worker budget 20000 -> 22000. The five days after #463 added
# 2.2KB (four rule-per-incident commits); bumped rather than trimmed so the
# regrowth question gets one deliberate answer (issue #509) instead of a
# 200-byte shave.
#
# 2026-10-05: coordinator budget 25000 -> 26000. coordinator.md had already
# drifted to 25427 bytes (over budget, pre-existing — unrelated to issue
# #467) before this change added one clause for #467's stuck-timeout-retry
# sweep; same "bump with a reason, don't shave a one-clause rule to fit"
# call as the worker bump above. coordinator.md's own regrowth still owes
# issue #509 a full answer; this bump is not that answer.
#
# 2026-10-05: worker budget 22000 -> 22300. Six rounds of automated
# self-review on #467's "Stop after two timeouts" rule each caught a real
# correctness gap (a false-positive-prone example, pane output folding
# able to hide the marker, an exit-code-masking bug in the example itself)
# — fixes, not incident narrative, but still didn't fit the headroom.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_MAX="${WORKER_MD_MAX_BYTES:-22300}"
COORD_MAX="${COORDINATOR_MD_MAX_BYTES:-26000}"
BARE_MAX="${WORKER_BARE_MD_MAX_BYTES:-11000}"   # issue #510 trial prompt; ~7.5KB is script-parsed contract

check() {
    local file="$1" max="$2" size
    size="$(wc -c < "$ROOT/$file")"
    [ "$size" -le "$max" ] \
        || red "$file is $size bytes, over its $max-byte budget (see header comment)"
    green "$file: $size / $max bytes"
}

check prompts/worker.md "$WORKER_MAX"
check prompts/coordinator.md "$COORD_MAX"
check prompts/worker-bare.md "$BARE_MAX"
