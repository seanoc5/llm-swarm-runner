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
# 2026-10-05: worker budget 22000 -> 22300, then -> 22700. Repeated rounds
# of automated self-review on #467's "Stop after two timeouts" rule each
# caught a real correctness gap (a false-positive-prone example, pane
# output folding able to hide the marker, an exit-code-masking bug in the
# example itself, the rule's own decision-needed message being able to
# retrigger the watcher it was written to satisfy) — fixes, not incident
# narrative, but still didn't fit the headroom. (Exact round count lives
# in PR #545's own "Decisions made" section, not here — duplicating it as
# a number in two places is what caused that PR's own round-9 self-review
# to catch this file and the PR body disagreeing.)
#
# 2026-10-06: worker budget 22700 -> 23700. Issue #473 added two one-clause
# rules (self-review round cap, CI-green-before-ready) under "Self-review
# before merge" plus a one-clause draft-first-checklist pointer to them;
# trimmed first, still ~700 bytes over even after trimming twice.
#
# 2026-10-15: worker budget 23700 -> 24000, worker-bare 11000 -> 11300.
# Issue #635 adds the one-line **Next:** who-acts rule (plus trigger check)
# to both worker prompts and folds the routine "Your move: merge decision"
# example into it; ~400 bytes over, and the rule is the fix itself.
#
# 2026-10-17: worker budget 24000 -> 24100. Issue #634 adds one sentence
# saying a brief's "Issue comments" section can supersede the body and the
# issue author's latest comment wins on conflict — already near-minimal
# after trimming once; only ~50 bytes over even so.
#
# 2026-10-22: coordinator budget 26000 -> 26200. Issue #656 adds one
# sentence: re-check mergeable before listing a merge (the 2026-10-22
# corpusminder #1513 stale "merge" advice). #655 had already spent the
# last headroom on delta-only wake reports, trimming a paragraph to fit.
# coordinator.md's regrowth still owes issue #509 its answer.
# 2026-10-26: coordinator budget 26200 -> 26800. One paragraph for the
# opt-in SWARM_AUTOMERGE_MEDIUM path (operator-approved 🟡 automerge); its
# gates live in swarm-merge.sh --auto-medium, not in the prompt. Same
# PR: worker-bare 11300 -> 11400 for the add-only Flyway 🟡 carve-out.
# 2026-11-01: coordinator budget 26800 -> 28000. Operator-approved night
# queue: one short section (batch-approved `night-ok` issues dispatched
# overnight without asking; dispatch/filing is act-then-report; evening
# stale-`blocked` sweep; weekly epic-carve batch) after only 6 of 496 PRs
# landed 03:00-09:00 across four app swarms.
# 2026-11-01: coordinator budget 28000 -> 30000. Operator-approved stopgap
# (temporary headroom, not a new baseline): #694 and #696 together landed
# at 28036. The operator plans to revise and shrink coordinator.md; lower
# this back when that lands (issue #509).
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_MAX="${WORKER_MD_MAX_BYTES:-24100}"
COORD_MAX="${COORDINATOR_MD_MAX_BYTES:-30000}"
BARE_MAX="${WORKER_BARE_MD_MAX_BYTES:-11400}"   # issue #510 trial prompt; ~7.5KB is script-parsed contract

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
