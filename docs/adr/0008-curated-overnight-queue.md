# ADR-0008: Overnight dispatch gap — cause, and a curated overnight queue

- **Status:** Proposed (design only; no code changes in this PR)
- **Date:** 2026-11-11
- **Issue:** [#663](https://github.com/seanoc5/llm-swarm-runner/issues/663)
- **Deciders:** @seanoc5

## Context

Issue #663 observed that five swarms (corpusminder-spring, fand-app, fand-etl,
SAMlytics, civicstrata) created almost no PRs between 03:00 and 09:00 local
(America/New_York) from 2026-10-12 to 10-26, and asked for (1) the cause and
(2) a curated overnight queue: overnight work only from operator-labelled
issues, structured `Do:` follow-ups, and sub-issues of an operator-labelled
epic; no free-form issue invention; a per-swarm nightly cap of about 10.

Terms: **swarm** = one project's coordinator + watcher + workers. **Wake** = the
watcher nudging the coordinator (an LLM session in a tmux pane) to look at its
inbox. **Composer** = the coordinator's input box; the watcher will not type a
wake into it when it looks like it holds a human draft. **Dispatch pause** = the
host-wide marker `nightly-full-tests.sh` writes at 02:05 local so no worker
spawns while the nightly slow-test lanes run (it expires after at most 6 h).

## Findings (Step 1: cause)

Method: PR creation times from `gh pr list` for the five repos, bucketed by
local hour; this repo's `.swarm/events.log`; git history of the runner.
Limit: **only llm-swarm-runner's own `events.log` exists on the host this was
run from.** The other five swarms' logs were not reachable, so per-swarm
attribution below is inferred, not read from their logs.

**F1. The finding reproduces exactly, and it has since closed.** PRs per local
hour over 2026-10-12..26, all five repos: 0h:29 1h:19 2h:21 3h:6 4h:4 5h:0 6h:0
7h:0 8h:1 9h:3. PRs created 03:00–08:59, same-length windows:

| repo | 10-12..26 | 10-27..11-10 |
|---|---|---|
| corpusminder-spring | 6 | 44 |
| fand-etl | 4 | 44 |
| fand-app | 1 | 16 |
| civicstrata | 0 | 7 |
| SAMlytics | 0 | 6 |

By day, 03:00–08:59 PRs were 0 on every day from 10-23 through 11-01 and
nonzero from 11-02 on. All five repos flipped together, so the cause is in the
runner, not in any one repo's backlog.

**F2. Dominant mechanism: the coordinator is only dispatching when woken, and
overnight wakes were dropped.** The coordinator is an LLM session; it
provisions workers only when something wakes it. The watcher types the wake
into the composer and refuses (`coord.wake.skip reason=composer_dirty`) if the
composer looks occupied. Evidence:

- This repo's log, night of 2026-10-14 (03:00–09:00 EDT): 2718
  `composer_dirty` skips, 1359 retries, 70 stale deferrals, **0 wakes
  delivered, 0 workers started.**
- Commit 9e87b88 (PR #665) records the cause of false-dirty composers: Claude
  Code drops the "(shift+tab to cycle)" footer hint while background shells
  run, and the watcher's filter keyed on that hint. It measured corpusminder
  skipping ~170 wakes in one hour on 10-26 while a PR sat merge-ready.
- Fixes then landed: #665 (10-28 footer filter), #667/#668 (10-28/29 hook-based
  busy/idle state and an inbox waiter that wakes an idle coordinator without
  typing), #678 (11-01 night-queue wakes when the pause lifts or slots idle).
  The watchers were restarted 2026-11-01T19:15Z (`watch.timer.start`), the first
  night running all of it was 11-01→11-02, which is the first night with
  03:00–09:00 PRs. Which of #665/#668/#678 mattered most: **cause not
  established** (they shipped and went live together).
- Since the restart, this repo's log shows overnight wakes delivered
  (11-05: 3, 11-06: 2, 11-10: 7) and zero `composer_dirty` skips.

Caveat: other nights in this repo's Oct window have no events in the band at
all (this swarm ran only 14 workers in the whole window), so the 10-14 night is
one clean example, not proof for the other four swarms.

**F3. Second, stacked mechanism: the host-wide dispatch pause.** The nightly
runner (PR #539, 2026-10-05) pauses spawns for every swarm from 02:05 until its
lanes finish, up to 6 h, which spans the whole 02:05–08:05 gap. Observed
pause ends in November: 11-05 03:31, 11-06 03:33, 11-10 04:20, 11-11 04:23
local. October pause lengths were not recorded (nightly run logs live in
`~/.local/state/swarm-nightly` on the operator's host, not visible here), so
how much of 03:00–05:00 was the pause is **cause not established**. It cannot
explain 05:00–08:00 on its own once runs finish by about 04:30.

**F4. After the pause lifts, an unlabelled backlog still produces no work.**
Every one of this repo's 36 idle-capacity wakes since 11-01 reads `night_ok=0`
with `ready` 33–52, and on 11-06 the pause lifted with 5 free slots and
`ready=42` and no worker started until after 11:00 local. Why that coordinator
turn dispatched nothing: **cause not established** (coordinator transcript not
visible here). The prompt text is ambiguous: "Overnight: dispatch `night-ok`
issues" vs "AVAILABLE > 0 with free slots: dispatch".

**F5. `night-ok` is already the operator's curation label, and is unevenly
used.** Issues ever carrying it: fand-etl 35, fand-app 28, SAMlytics 12,
civicstrata 2, corpusminder-spring 0, llm-swarm-runner 0. `swarm-ready` (the
issue's example name) exists in no repo.

**F6. Quality data supports allowing follow-ups.** From the issue: of issues
created 10-12..22, worker follow-ups ended 147 done / 2 not-planned / 9 open
(n=158); other issues 253 / 6 / 41 (n=300). Follow-ups are not worse.

**F7. Calibration for the cap.** PRs created 00:00–08:59 per swarm per night,
11-02..11-10: corpusminder-spring median 5 / max 15; fand-etl 6 / 17; fand-app
2 / 10; SAMlytics 2 / 7; civicstrata 1 / 5. PRs overcount issues (fix rounds), so
a cap of 10 issues binds only on the two busiest swarms' peak nights.

## Decision (Step 2: curated overnight queue)

**D1. Reuse the existing `night-ok` label; don't add `swarm-ready`.**

| Option | For | Against |
|---|---|---|
| A. Reuse `night-ok` | Already in prompts and wakes (#678, #688); 77 issues labelled in 4 repos; zero migration | Name says "night", so an operator can't use it for "dispatchable any time" |
| B. New `swarm-ready` | Matches the issue's example | Second label, two code paths, relabel history |

Chosen: A.

**D2. Overnight-eligible set (the only sources).** In the night window an
issue may be dispatched only if it is open, passes `available-issues.sh`, and:

- E1. carries `night-ok`; or
- E2. carries `swarm-followup` (a `Do:` item the coordinator filed from a worker
  PR; `Decide:` items are never filed, so never eligible); or
- E3. is a child of an open issue carrying both `epic` and `night-ok`, found via
  the GitHub sub-issues API or the repos' existing `from-epic-N` / `epic-N`
  child labels (corpusminder-spring and fand-etl use labels, not the API).

Everything else is not dispatched in the night window. Nothing else changes
outside it.

**D3. No overnight issue invention.** The coordinator files nothing overnight
except the `Do:` follow-ups of PRs it has just seen (E2). The existing evening
step ("propose 5–10 issues, one batch approval, label approved ones
`night-ok`") stays: the operator's approval is the curation.

**D4. Per-swarm nightly cap, default 10, `NIGHT_ISSUE_CAP`.** Counted as
distinct issue numbers with a `worker.start` in the night window; fix rounds on
an issue already started don't count again. Follow-ups filed by a night worker
are eligible the same night (E2) but count against the same cap, which also
bounds follow-up chains.

| Option | For | Against |
|---|---|---|
| A. Cap counts issue starts | Matches "~10 new issues"; chain-proof; one cheap query | Fix-round PRs aren't limited (they're bounded by CI/round caps already) |
| B. Cap counts PRs | Closer to merge load | Penalises a PR that needs a fix round |

Chosen: A.

**D5. Night window: 00:00–08:00 local, `NIGHT_WINDOW_START/END`.** Chosen
to cover the observed gap and the nightly pause; the operator's evening
interaction ends before it and the 09:00 digest starts after.

**D6. Enforce in the scripts, not the prompt.** Per ADR-0007 (deterministic
checks first) the filter and cap are admission checks in `provision-worker.sh`,
next to the existing `dispatch_paused` / `host_load` checks, returning exit 3
with `cap.refused reason=night_not_eligible` or `reason=night_cap` so the
coordinator's existing retry/report path handles them. An operator-typed
dispatch ("start #N now") passes an explicit bypass flag and is logged
(`night.bypass`). The coordinator prompt gains no new prose.

**D7. Make the wakes truthful.** `dispatchable_issue_counts` counts only
eligible issues during the window, so idle-capacity wakes stop firing on a
backlog the gate will refuse (36 of 36 wakes since 11-01 were such).

**D8. Observability for the next gap.** `swarm-scoreboard.sh` gains a per-hour
"PRs created / worker starts / wakes delivered / wakes skipped" row so a
recurrence shows in a morning, not a month. (The `composer_dirty` count is the
canary: any night with skips > 0 and wakes delivered = 0 is the F2 pattern.)

## Consequences

- Overnight output is bounded and traceable to an operator decision (a label)
  or to a worker's own `Do:` line.
- Swarms with no `night-ok` issues (corpusminder-spring today: 0) do nothing
  overnight beyond follow-ups, which is the intended middle ground but a
  visible drop from the 44 PRs it opened 03:00–09:00 over 10-27..11-10. That
  swarm's operator labelling step becomes the throughput lever.
- Risk: E3 child detection by label convention can misclassify; a wrong
  miss only means a skipped issue, never an unlabelled dispatch.

## Follow-ups (not in this PR)

See the PR's Follow-up suggestions: gate in `provision-worker.sh` (D2, D4–D6),
wake counts (D7), scoreboard row (D8), and a prompt tweak resolving the
"overnight vs AVAILABLE > 0" ambiguity (F4).
