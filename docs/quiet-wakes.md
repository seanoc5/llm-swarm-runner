# Quiet wakes (issue #730)

*Read this when the coordinator wakes too often, replies at length to a wake
that changed nothing for you, or you want the old wake-per-item behaviour back.*

## What it does

Three parts, all controlled by `COORD_QUIET_WAKES` (default `1`; batching and
the "Woke for" suffix need `COORD_HOOK_STATE=1` **and** `COORD_INBOX_WAITER=1`.
Both ship `0`, so out of the box nothing here is active: as of 2026-11-05
corpusminder is the only project known to set them. Without the waiter the
watcher still types a plain doorbell per item, with no suffix, so the
quiet-reply rule never applies):

1. **Batching.** Inbox items are classified by kind (filename
   `<ts>-<kind>-<pid>-<rand>.md`). Urgent kinds wake the coordinator at once and
   flush everything queued with them. Everything else collects and wakes it at
   most once per `COORD_INBOX_BATCH_SECS` (default 900), counted from the last
   ring. Logic: `scripts/_coord-inbox-batch.sh`, used by
   `coord-inbox-wait.sh` (idle coordinator), `coord-hook.sh` (turn end) and
   `coordinator-watch.sh` (its typed fallback waits grace + batch secs only while
   everything pending is non-urgent; an urgent item keeps the plain 120 s grace).
2. **"Woke for" line.** The nudge ends `Woke for: 2 outcome, 1 idle capacity.`
   and the coordinator opens its reply with that line.
3. **Quiet replies.** `.swarm/needs-you.md` holds the standing Needs-you list.
   The coordinator rewrites it only when the list changes. A wake that leaves it
   unchanged gets one line: `Handled 3 items: 2 merged, 1 idle slot. Your list
   unchanged (2 items) — details in .swarm/needs-you.md.` Full write-up only for
   new or changed items.

## Urgent vs batched

| Urgent (wake now) | Batched (wake at most every 900 s) |
|---|---|
| deliver_stall, stranded_brief, worktree_vanished, sidelined_worker, sidelined_wake_failed, stall | idle_capacity, activity, dispatch_pause_lifted, stale_wait |
| outcome that is not `*.ok.json` | outcome `*.ok.json` |
| outbox `kind: decision-needed`, or text reporting red CI | outbox `kind: fyi` / `brief-draft` |
| any unknown kind, or an item whose body can't be read | |

Unclassifiable means urgent: an item is never delayed by a guess.

## Settings

- `COORD_QUIET_WAKES=0` — master off: every item wakes, no suffix, full digest each time.
- `COORD_INBOX_BATCH_SECS=900` — batch window; `0` also disables batching but keeps the suffix and quiet replies.

Both are read by the hook and waiter at run time and by the watcher at start;
restart the coordinator after changing them.

## Measuring

`events.log` records each ring: `coord.wake.waiter_rang items=N urgent=U batched=B`
and `coord.wake.hook_rang …`; the watcher's typed doorbell logs plain `coord.wake …`.
Count every automatic wake (comparable to the issue's 209) with
`grep -c -E 'coord.wake( |\.waiter_rang|\.hook_rang)' .swarm/events.log`.
That excludes `coord.wake.skip`, `.deferred` and the other `coord.wake.*` bookkeeping lines.
Baseline from the corpusminder coordinator (Nov 1–4): 31 operator prompts, 209
automatic wakes, 95 "nothing new" replies.

Per-day counts without grepping: `scripts/swarm-scoreboard.sh --wakes <project-dir | events.log>`
(add `--json` for machines). It prints wakes per day split by typed doorbell, waiter and
hook, plus summed `items`/`urgent`/`batched`. Quiet vs full replies cannot be derived:
no event records which reply form the coordinator chose, so `urgent` vs `batched` is the
nearest proxy. Logging the reply form would be a coordinator-side change (not done here).
