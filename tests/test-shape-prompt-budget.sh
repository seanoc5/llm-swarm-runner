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
# 2026-11-01: worker budget 24100 -> 24200. Issue #587 adds one sentence
# telling a worker with an empty $TASK_ID to read it from the brief's
# "[swarm] task_id=" header line; ~20 bytes over after shortening it twice.
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
# 2026-11-05: coordinator budget 30000 -> 30800. Issue #730 (quiet wakes):
# a "Woke for:" opening line, a standing .swarm/needs-you.md list and a
# quiet-reply rule beside the kept no-ceremony bullet (used when a wake has no
# "Woke for:"); ~680 bytes net after tightening twice. Further detail lives in docs/quiet-wakes.md. Still
# a stopgap until #509 shrinks the file.
#
# 2026-11-05: coordinator budget 30800 -> 31200. Issue #756 (dead watcher goes
# unnoticed): one sweep line plus one paragraph telling the coordinator what
# the WARN means; ~450 bytes. Still a stopgap until #509 shrinks the file.
#
# 2026-11-05: worker budget 24200 -> 24300. Issue #757 adds one line: a draft
# PR's handoff Action leads with "still draft, waiting on CI|pr-ready" (a
# green-looking handoff on a stalled civicstrata draft read as ready).
#
# 2026-11-05: worker-bare 11400 -> 11600. Issue #573 adds the two 🔴 merge
# safety rules worker.md already had (no coordinator-relayed approval; a
# push after approval voids it) to the bare prompt's 🔴 row, ~130 bytes.
#
# 2026-11-05: issue #767 adds the split-mode prompts (ADR 0006 section 6):
# coordinator-shared.md (rules both read), coordinator-work.md (the
# non-interactive run) and coordinator-chat.md (the conversation session).
# coordinator.md is untouched, so resident mode costs nothing new. Work was
# extracted from coordinator.md, so it starts near the old size; the budgets
# below hold the split files where they landed. Retiring coordinator.md once
# split is the default (and lowering its budget) is the issue #509 answer.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 2026-11-10: coordinator budget 31200 -> 31400, coordinator-work 24000 ->
# 24200. Issue #802 adds one sentence (~160 bytes) to each: give every slice
# of a multi-slice issue its own issue and branch. Still a stopgap until #509.
#
WORKER_MAX="${WORKER_MD_MAX_BYTES:-24300}"
COORD_MAX="${COORDINATOR_MD_MAX_BYTES:-31400}"
BARE_MAX="${WORKER_BARE_MD_MAX_BYTES:-11600}"   # issue #510 trial prompt; ~7.5KB is script-parsed contract
SHARED_MAX="${COORD_SHARED_MD_MAX_BYTES:-5600}"   # issue #767 split prompts
WORK_MAX="${COORD_WORK_MD_MAX_BYTES:-24200}"
CHAT_MAX="${COORD_CHAT_MD_MAX_BYTES:-5000}"

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
check prompts/coordinator-shared.md "$SHARED_MAX"
check prompts/coordinator-work.md "$WORK_MAX"
check prompts/coordinator-chat.md "$CHAT_MAX"
