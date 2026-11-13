# Coordinator session recycling (issue #717, part A2)

*Read this when a coordinator has run for hours or days, has been compacted
several times, and its digests start to drift from what `gh` and `tmux` say.*

## What it does

A long coordinator session pays for its whole conversation on every wake, and
its working picture comes from its own narrative, not from queries. With
`COORD_RECYCLE=1` the watcher (`scripts/coordinator-watch.sh`) types `/clear`
into the idle coordinator pane, then sends the normal startup-checklist prompt
through `llm-start.sh` (the same injection path every wake uses). The
coordinator rebuilds its picture from `gh`, `git` and `tmux`. State that must
survive lives outside the conversation: `.swarm/needs-you.md`, the inbox,
GitHub. The first digest after a recycle says "first of a session" (see
`prompts/coordinator.md`).

Off by default. It does nothing in `COORD_MODE=split` (nothing types into that
pane; each work run is already a fresh session).

## Triggers (documented, two)

- **after_compact:** `.swarm/events.log` holds a `coord.compact.done` line
  newer than the last recycle. A compaction summary is lossy; starting clean is
  better than carrying it. Only watcher-injected compactions are logged; the
  CLI's own built-in auto-compact is not seen.
- **age:** the coordinator's CLI process is older than `COORD_RECYCLE_HOURS`
  (default 12) and no recycle happened in that many hours. `/clear` does not
  restart the process, so the last-recycle time is kept in
  `.swarm/coord-recycle-at` (epoch seconds).

At most one recycle per `COORD_RECYCLE_MIN_GAP_SECS` (default 3600), so a
compaction right after a recycle cannot cause a loop.

## Gates (a due recycle waits, logged as `coord.recycle.skip reason=...`)

`not_cli` (no live session), `pane_busy`, `composer_dirty` (an unsent draft),
`human_present` (operator typed within `COORD_HUMAN_IDLE_SECS`),
`pending_approval` (the last reply is an unanswered "Pending your approval:"),
`locked` (a compaction is being injected), `clear_not_submitted` (the `/clear`
did not take; the checklist is then not sent).

## Knobs

`COORD_RECYCLE` (0), `COORD_RECYCLE_HOURS` (12), `COORD_RECYCLE_MIN_GAP_SECS`
(3600), `COORD_RECYCLE_TICK_SECS` (300; 0 disables the loop),
`COORD_RECYCLE_PROMPT` (`Execute the Initial Startup Checklist.`; the default
wording is already hidden by `coordinator-conversation.sh`).

Set them in `<project>/.swarm/.env` and respawn the watcher.

## Manual recycle

Type `/clear` in the coordinator pane, then `Execute the Initial Startup
Checklist.` That is all the watcher does.

## Observing

`grep -E 'coord\.recycle' .swarm/events.log`
