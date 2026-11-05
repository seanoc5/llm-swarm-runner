# ADR 0006 — Split the coordinator into short work runs and a separate operator conversation

- **Status:** Proposed. Design only: nothing here changes behaviour until the
  operator approves it.
- **Date:** 2026-11-05.
- **Deciders:** llm-swarm-runner maintainers (the operator decides).
- **Issue:** [#745](https://github.com/seanoc5/llm-swarm-runner/issues/745)
- **Related:** [#743](https://github.com/seanoc5/llm-swarm-runner/issues/743)
  (watcher-side batching; step one of this design),
  [#744](https://github.com/seanoc5/llm-swarm-runner/issues/744) (clean
  conversation view; a bridge this may replace),
  [#421](https://github.com/seanoc5/llm-swarm-runner/issues/421) (`SendMessage`
  doorbell), [#730](https://github.com/seanoc5/llm-swarm-runner/issues/730)
  (quiet wakes), [#715](https://github.com/seanoc5/llm-swarm-runner/issues/715)
  (background tasks off by default),
  [ADR 0005](./0005-coordinator-messaging-without-send-keys.md) (the wake
  problem this ADR tries to remove rather than patch).

## Recommendation

**Yes, but as a one-swarm trial after #743 has run for a week, not as a
rewrite.** Confidence about 65%. Blast radius of the trial: one low-traffic
swarm, behind one setting, rolled back with two commands.

Why not "no": the evidence says the wake plumbing is the main source of both
problems the issue names, and patching it (#743, #421) can reduce it but not
remove it. Why not "yes, build it all now": the two numbers that decide the
payoff (tokens per fresh run, and whether a run with no chat memory triages as
well) are only half measured. Section "What would change this recommendation"
lists the stop conditions.

## Context (plain language)

One chat session does two jobs: it talks to the operator, and it runs an
automatic loop (read the inbox, merge, dispatch workers, write a digest). Chat
input is a keyboard box, so every automatic wake has to be typed into it, and
that single fact produced the whole stack of workarounds.

Measured in this repo's own `.swarm/events.log` (174,002 lines, 2026-05-26 to
2026-11-05):

- 239 wakes actually rang the coordinator, and 32,398 events were wake
  bookkeeping (skip, defer, retry, resubmit, deferred_stale): about 135
  bookkeeping events per real wake.
- 20,794 of those were `coord.wake.skip reason=composer_dirty`, the
  "operator has half-typed text, don't paste" gate.
- 49,355 more were `coord.compact.skip`, the same busy-pane problem for
  `/compact` injection.

Three mechanisms now decide when to ring (the watcher's typed doorbell, the
Stop hook, the background waiter), and #715 broke one of them without anyone
noticing (#743's "What's wrong": corpusminder ran degraded after its
2026-11-05 restart).

Readability: per #730, wake turns were about 73% of corpusminder's session
tokens over Nov 1-4 (127M cache-read vs 47M for operator turns), and 95 of 209
wake replies said nothing new.

## Proposal under evaluation

- **Work runs.** The watcher starts a short non-interactive coordinator run
  when the batching rules say it's time. The run triages the inbox, merges,
  dispatches, writes `.swarm/needs-you.md` and exits. Its output goes to a log
  file that is the operator's system-log view.
- **Conversation session.** A separate session only the operator types into.
  It reads `.swarm/needs-you.md` and is never woken.

The waiter, the Stop hook's wake role and the background-task dependency then
have no job.

## The nine questions

### 1. What state survives between runs, and where it lives

A work run starts with no memory, so everything it needs must be a file. Most
of that already is one; three things are not.

Already on disk (no change): the inbox and its `processed/` archive
(`.swarm/coord-inbox/`), worker briefs and outcomes
(`.swarm/tasks/`), live truth from `tmux list-windows` and `gh pr list`
(`prompts/coordinator.md` already says never to assert in-flight status from
memory), and the standing Needs-you list (`.swarm/needs-you.md`, #730).

Today only in chat memory, so new files are needed:

- **Previous digest** (the "Moved since last wake" row diffs against it) ->
  `.swarm/work-run/last-digest.md`, rewritten at the end of each run.
- **Operator's standing instructions given in chat** ("hold #123", "don't
  dispatch the migration work tonight") -> `.swarm/operator-notes.md`, appended
  by the conversation session, read at the start of every run. Without this a
  fresh run silently ignores things the operator said.
- **Run bookkeeping** (last start, last finish, exit code, token usage) ->
  `.swarm/work-run/runs.log`, one line per run.

### 2. Fresh run or resumed session, and the token cost

**Recommendation: fresh run each time, fed by the files above.** A resumed
session works (tested below) but rebuilds exactly the growing context that
makes today's wakes expensive.

| Number | Value | Status |
|---|---|---|
| Today, cache-read tokens per wake turn, this repo's coordinator (33 wake turns in one transcript) | 40.4M / 33 = about 1.22M; 296 API calls = about 9 calls per wake; average context 137k tokens per call | Measured |
| Same, second transcript (19 wake turns) | 17.6M / 19 = about 0.93M; 142 calls; average context about 124k | Measured |
| Fresh `claude -p` with the real rendered coordinator prompt (31 KB), project loaded, one no-tool reply | 37,338 input tokens, all served from cache, $0.0038 on Sonnet 5.5 | Measured (cache was warm) |
| Same with a bare one-line system prompt | 21.8k input tokens (10.8k cache-write, 11.0k cache-read) | Measured |
| Fresh run doing a real triage: about 9 calls, context growing from 37k to about 60k | about 0.45M cache-read tokens, i.e. 2-3x fewer than today per wake | **Estimated**; only the 37k start is measured |
| Cache-write cost when runs are more than an hour apart (the cache lifetime this session uses is 1 h) | up to about 37k written per run | Estimated |
| `--resume <id>` with `-p` restores memory | "kumquat" recalled; session id unchanged | Measured, one trial |

How I counted wake turns: user messages whose text starts with `Inbox:`.
That matched 33 of 107 doorbells in the first transcript, so these are a
mechanically classifiable subset, not a full census. Treat the per-wake figures
as "about 1M, give or take", not as an audited total.

The per-run saving also compounds with batching: #743 caps wakes at one per
900 s for non-urgent items (at most 96 a day), and a fresh run never carries
yesterday's conversation.

### 3. Locking, so a work run and the conversation can't act at once

Two kinds of lock, both `flock` on files under `.swarm/` (the project already
has 26 lines using `flock` in the watcher):

- **Single-flight run lock** (`.swarm/work-run.lock`), held by the watcher for
  the length of a run. A second start attempt while a run is going does not
  ring anything; it leaves the inbox as is and the watcher checks again when the
  run exits. This replaces the whole pane-busy/debounce/retry family.
- **Action lock** (`.swarm/coord-actions.lock`), held for seconds, only around
  the irreversible step: inside `scripts/swarm-merge.sh`, after the gates pass,
  re-read the PR head and merge state and run `gh pr merge` under the lock. The
  lock must not wrap `ci-wait.sh`, which can block 570 s and would stall the
  operator's own merges.

Two rules cut the remaining overlap:

- **Who merges what.** The work run performs only the opt-in automerges
  (`SWARM_AUTOMERGE_LOW`, `SWARM_AUTOMERGE_MEDIUM`). Everything the operator
  must say explicitly (`merge PR N`, 🔴 `merge PR N red`) is done by the
  conversation session, in the operator's own turn. This also keeps
  `prompts/worker.md`'s rule that a 🔴 merge is never relayed by a coordinator
  true by construction.
- **Dispatch idempotence.** The conversation session queues work only through
  `requeue.sh` / `provision-worker.sh`. Whether those refuse a duplicate for an
  issue that already has a window or claim is **not verified here**; it is a
  trial-prep check (see the plan).

### 4. How decisions reach a work run, and urgent items reach the operator

Operator to run: the conversation session writes a note through a small helper
(new, `scripts/operator-note.sh`) that drops an inbox file named
`<ts>-operator-<pid>-<rand>.md`. The existing classifier already treats any
unknown kind as urgent (docs/quiet-wakes.md), so a note starts a run at once
with no change to the batching rules. Standing instructions go to
`.swarm/operator-notes.md` (section 1).

Run to operator, never by waking the conversation:

1. `.swarm/needs-you.md` is rewritten by the run when the list changes
   (exists today).
2. The tmux window flag already used for workers (`@swarm_flag`,
   `scripts/_window-flags.sh`) is set on the conversation window for urgent
   kinds, so the operator sees it in the status bar.
3. A `UserPromptSubmit` hook on the conversation session adds one line of
   context ("Needs-you changed since your last message: 2 new items") on the
   operator's next message. **Tested here:** a hook returning
   `additionalContext` reached the model under `claude -p`; I did not test the
   interactive REPL, though the hook contract is the same.

For gemini/codex/agy there is no such hook; their chat prompt says to
`cat .swarm/needs-you.md` at the start of each turn.

### 5. What `COORDINATOR_HEADLESS=1` already provides, and what it lacks

Tested by running `scripts/coordinator-claude.sh` with it set, with the real
prompt, plus direct `claude -p` runs.

Provides (tested): one non-interactive run, prints the reply, exits 0
(`ready.`); `--settings` hooks fire under `-p` (UserPromptSubmit then Stop,
2 s apart around a Bash call); the prefix cache carries across separate
processes; a clean exit closes the window under `remain-on-exit=failed`, and
the next `llm-start.sh` call relaunches it (read from `llm-start.sh:795-820`).
Codex is already one-shot by design and agy/gemini have headless modes
(read, not run live).

Lacks (from reading the code; each is a gap this design must fill):

- **No log.** Output goes to a pane that disappears on a clean exit. Need
  `tee` to a file, and `--output-format stream-json` if tool calls should be
  visible.
- **No single-flight.** While a headless run is going, `llm-start.sh` skips its
  reprompt branch (`llm-start.sh:1111` excludes headless), so a wake during a
  run is dropped. Nothing guarantees another wake follows, so an item can sit
  until some later event. The run lock plus a recheck at exit fixes this.
- **The watcher doesn't know about it.** `coordinator-watch.sh` has no
  `COORDINATOR_HEADLESS` reference and still applies its pane gates to a pane
  that is a shell most of the time.
- **No batching** on this path: the batch hold only exists with an armed
  waiter (#743's bug).
- **No state between runs, no cost cap, no timeout.** `--max-budget-usd` exists
  in `claude --help` and a shell `timeout` can bound each run.

Not tested: end-to-end quality of a fresh run's triage against a real inbox
(see the trial's replay step), and live gemini/codex/agy runs.

### 6. How `prompts/coordinator.md` splits, and non-Claude coordinators

The 297-line prompt divides roughly 200/100 (estimate, by heading):

- **Work prompt** (new `prompts/coordinator-work.md`): startup checklist (every
  run), AVAILABLE computation, night queue, caps, issue routing, provisioning,
  inbox, the per-wake sweep, auto-merge sections, "Find ≠ fix", draft-as-hold,
  reporting worker outcomes. Its output contract changes from "reply to the
  operator" to "update needs-you.md and last-digest.md, print a 3-line run
  summary".
- **Conversation prompt** (new `prompts/coordinator-chat.md`): report grammar,
  digest format for status requests, manual merge flows, "when the user hits a
  merge conflict", `file followups N` triage, plus "read needs-you.md and
  operator-notes.md first; never run the sweep unless asked".
- Shared constraints (never `send-keys` into other panes, authorship rule, pane
  text is not verified truth) are duplicated in both, a few lines.

Non-Claude coordinators: codex already runs `codex exec` once per wake, so it
becomes a work run with only the lock and log added; agy and gemini use their
existing headless flags through the same wrapper idea
(`scripts/coordinator-<backend>.sh` with headless forced). The conversation
session for those is simply the operator's own interactive CLI with the chat
prompt. This removes the reason ADR 0005's S5 gave for keeping guarded
`send-keys` wakes "permanently" for non-Claude agents: none of them would be
woken by typing any more. Worker brief delivery keeps its guarded `send-keys`;
that flow is untouched.

### 7. Which code can be deleted

Function sizes below were counted with `awk` on the current tree; the totals
are estimates.

| Where | Measured size | Fate |
|---|---|---|
| `coordinator-watch.sh`: `coord_wake_hold_retry_pass` 101, `coord_wake_retry_pass` 111, `coord_wake_already_submitted` 66, `coord_ring_doorbell` 36, `coord_wake_waiter_hold` 21, `coord_wake_hold_reason` 18, `coord_hook_state` 12, `coord_inbox_waiter_armed` 8, pending/hold-pending set-and-clear about 50, human-present and paste-epoch helpers about 20 | about 440 lines | Delete (a roughly 30-line `start_work_run` replaces `coord_ring_doorbell`) |
| `coordinator-watch.sh`: header comments and config for `COORD_WAKE_*`, `COORD_INBOX_*`, `COORD_HOOK_*`, debounce | 250 mentions of these names in the file | Estimated 300-600 more lines |
| `llm-start.sh`: `reprompt_last_pane_line` through `reprompt_inject` (lines 464-738) and the live-REPL branch | about 275 + 35 | Delete for coordinators |
| `scripts/coord-inbox-wait.sh` (the waiter) | 137 | Delete |
| `scripts/coord-hook.sh` | 120 | Shrink to the needs-you injection (about 40 est.) |
| `scripts/_coord-inbox-batch.sh` (batching rules) | 143 | **Keep**: the watcher reuses it to decide when to start a run |
| Tests: `test-llm-start-reprompt.sh` 679, `test-wake-presence-gate.sh` 339, `test-coord-inbox-wait.sh` 214 | 1,232 | Delete; parts of `test-coordinator-inbox.sh` (499) and `test-coordinator-auto-compact.sh` (1,207, if coordinator compaction goes too) are further candidates |

Rough total: **1,000-1,400 lines of product code and 1,250-2,400 lines of
tests removed, against roughly 300-400 lines added** (run launcher with lock and
log, operator-note helper, slimmer hook, prompt reorganisation). Coordinator
auto-compact is likely unnecessary because work runs are short and the
conversation session is operator-paced; worker auto-compact stays.

Not deleted: the inbox files and their writers, the outbox/status/done bus
(ADR 0002), `_coord-inbox-batch.sh`, worker brief delivery.

The hold and retry logic the issue singles out is the first row: it exists
only because a typed message might collide with a human or a running turn, and
a started process cannot collide with either.

### 8. Comparison with #421 (`SendMessage` doorbell)

#421 changes how the bell is rung, not what is ringing:

- It likely fixes typing collisions (the `composer_dirty` class, 20,794 of the
  32,398 bookkeeping events measured above).
- It does not fix mixed output, which is the readability half of the problem:
  the coordinator's tool calls and the operator's chat stay in one pane.
- It does not fix resident-context cost (about 1M cache-read tokens per wake).
- ADR 0005's own addendum (Q3/Q4) left open whether a message can start a turn
  in a pane with nothing in flight. The split sidesteps that question because
  no one needs to start a turn in an idle chat session.

If the trial succeeds, #421 is superseded for coordinators; until then leave
it open. #744 (clean view) stays a small bridge and should not grow: under the
split the conversation session is already clean by construction.

### 9. Trial plan

**Where.** One low-traffic swarm that is not corpusminder. I couldn't see other
swarms' logs from this sandbox, so pick by data on the host: count
`grep -c ' coord.inbox.write' <project>/.swarm/events.log` per candidate and
take the lowest non-zero. SAMlytics is a guess, not a finding.

**How.** One setting, `COORD_MODE=split` (default `resident`), in that
project's `.swarm/.env`, which is its only source of truth. In split mode the watcher starts work runs and
`llm-start.sh` launches only the conversation session.

**Prerequisites (each shippable and reversible alone):**

- A1. #743 merged and a week of corpusminder data (wake count, token share).
- A2. Run wrapper: lock, `tee` to `.swarm/work-run/<ts>.log`, `timeout`,
  `--max-budget-usd`, one usage line per run in `runs.log`.
- A3. Action lock inside `swarm-merge.sh` (section 3) and a check that
  `provision-worker.sh` / `requeue.sh` refuse duplicates.
- A4. Prompt split (section 6) and `operator-note.sh`.
- A5. Replay test: run a fresh work run against a copy of a real inbox from a
  past day and compare its actions with what the resident coordinator did.

**Success measures (7 days, against the same swarm's previous 7 days):**

- B1. Zero lost items: no inbox file older than batch window + 15 min.
- B2. Wake bookkeeping events per real run under 5 (baseline here: about 135).
- B3. Coordinator tokens per handled item at least 2x lower (from `runs.log`
  against transcript totals).
- B4. Zero `composer_dirty` events and zero typed text in the conversation
  session that the operator did not type.
- B5. Zero double merges or duplicate dispatches; lock waits logged.
- B6. Urgent items start a run within 60 s; green-PR time to merge no worse
  than baseline plus the batch window.

**Rollback.** Kill the coordinator window first
(`tmux kill-window -t llm-<project>:coordinator`, so a wake between steps cannot
reach the live chat session), then delete the `COORD_MODE` line from the
project's `.swarm/.env` (the only place the mode is read; env and tmux values
are ignored), then `cd <project> && <sandbox>/llm-start.sh`. The watcher is not restarted; it reads
the file at its next wake. The new files are inert in resident mode and need no
migration. Roll back at once on any lost item or duplicate merge/dispatch, or
if urgent items take more than 5 minutes to start a run.

## Options compared

- **A. Do nothing beyond #743.** Pros: no new moving parts; batching is already
  the right first step. Cons: keeps the typed-wake stack, mixed output and
  resident-context cost; every future wake bug lands in this stack.
- **B. #421 only (`SendMessage` doorbell).** Pros: smaller than the split;
  fixes the typing collisions. Cons: output still mixed, cost unchanged,
  idle-pane question unresolved.
- **C. Split with fresh runs (this ADR).** Pros: removes the cause of both
  problems; 2-3x fewer tokens per wake (estimated); deletes more than it adds.
  Cons: needs a new state-file discipline, a lock, two prompts; the operator
  loses the live view of the coordinator working (replaced by `tail -f` on the
  run log); triage quality of a memoryless run is unproven.
- **D. Split with resumed runs (`--resume`).** Pros: keeps memory across runs
  with no state files. Cons: brings back the context growth that costs about
  125-137k tokens per call today; the one resume trial here showed a 7.6k
  cache-write on the second call, so a warm-cache saving is not guaranteed.

**Recommend C**, as the trial above; A is the fallback if the trial fails.

## What would change this recommendation

Switch to "don't do this" (stay on A, optionally add B) if any of these shows
up before or during the trial:

- The replay (A5) shows fresh runs missing things the resident coordinator
  caught, and operator-notes plus last-digest don't close the gap.
- Measured fresh-run tokens come in above about 60% of today's per-wake
  figure. Then the cost case is gone and only readability and deletion remain.
- #743 alone brings wake turns well under 50% of session tokens and nobody has
  seen a wake-plumbing incident for a month. Then the remaining benefit is
  readability and about 1,000 lines of deletion, and that may not justify the
  migration.

## Findings from this investigation

- #743's description says the batch hold returns early when the waiter is
  unarmed; confirmed at `scripts/coordinator-watch.sh:9670-9671`.
- A wake sent during a headless run is dropped, not queued
  (`llm-start.sh:1111`), so `COORDINATOR_HEADLESS=1` is unsafe to use as it
  stands.
- Fresh processes share a warm prompt cache: the second `claude -p` with the
  same system prompt read all 37k tokens from cache.

## Not tested

- A fresh run's triage quality on a real inbox.
- Live gemini, codex and agy headless runs.
- The `additionalContext` hook in the interactive REPL (tested under `-p`).
- Whether `provision-worker.sh` / `requeue.sh` refuse duplicates.
- The per-run cost on Opus 5.5 (the coordinator default); measurements used
  Sonnet 5.5 to keep the cost of testing small.
