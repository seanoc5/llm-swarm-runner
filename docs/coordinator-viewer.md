# Coordinator viewer layout (`COORD_VIEWER`)

One window to read and type in: the `coordinator` tmux window shows a clean,
read-only conversation view (your messages and the coordinator's replies) in a
large pane, with the Claude session as a small typing pane. Off by default.
Issue #785.

## Turn it on

- For every start: set `COORD_VIEWER=1` in the project's `.swarm/.env` (viewer
  height: `COORD_VIEWER_PCT`, default 75). `llm-start.sh` adds the viewer, also
  on a re-run against a live session (idempotent).
- For a running session: `scripts/coordinator-layout.sh on` (from the project dir).

## Turn it off

- `scripts/coordinator-layout.sh off` closes the viewer; the session and the
  watcher are not touched. Remove `COORD_VIEWER=1` from `.swarm/.env` so the
  next start doesn't add it back. `scripts/coordinator-layout.sh status` prints on/off.
- Closing the viewer pane by hand (`prefix` `x`) is equivalent.

## Layout and the pane-0 rule

The viewer is split **below** the session, so the session keeps pane index 0
and the viewer is pane 1 (the session is on top, small; the viewer below,
large). This was chosen over "find the session pane without the index" because
`llm-start.sh`, the watcher's doorbell/compact paste paths, `capture-worker.sh`
and the busy/composer checks all target `$SESSION:coordinator.0`, and tmux
numbers panes by screen position: a viewer placed above or left would take
index 0 and receive the doorbells. Placing it after the session changes none of those targets.

Defences if the layout is disturbed (all in `scripts/_coord-layout.sh`):
the viewer pane is titled `coord-viewer`; if the session pane is closed by hand
the viewer is renumbered to 0, and then `llm-start.sh` closes it and relaunches,
`reprompt_inject` refuses to paste into it (deferred, rc 2), and the watcher
reports the coordinator as absent and never busy. The viewer also closes itself
once it is the last pane.

## Failure isolation

The viewer is its own process in its own pane, not part of the session or
watcher. If `coordinator-conversation.sh` crashes the pane restarts it after 3s;
closing or killing the pane leaves the session and the watcher running.

## What it doesn't hide

- The session pane is still the real Claude pane: its tool calls, tool output
  and doorbell text still appear there (a few lines, because it is small). The
  viewer only adds a clean copy of the conversation; it hides nothing in the session.
- The viewer reads the transcript, so it lags by up to ~2s and shows nothing
  until a message is recorded. Permission prompts and `AskUserQuestion`
  dialogs are not in the viewer; they appear only in the session pane.

## Permission prompts and AskUserQuestion in the small pane

They render in the session pane as usual. At the default 25% height of a
typical terminal (about 10-14 rows) a dialog with many options or a long
question can be clipped and need scrolling. Fix: zoom the session pane with
`prefix` `z` (full window while you answer, press again to return), or set a
smaller `COORD_VIEWER_PCT` (for example 60). The pane is never hidden
automatically.

## Other places that touch the coordinator pane (audit, #785)

All use an explicit `.0` except two that used "first listed pane", now explicit
and viewer-aware: `llm-start.sh` pane-state detection (`display-message -t
...coordinator.0`) and `coordinator_pane_state` in `coordinator-watch.sh`.
Unchanged because they already target `.0`: wake and `/compact` paste paths,
`coordinator_pane_busy`, composer checks, `capture-worker.sh`, dead-pane
cleanup. The Ctrl-Z scratch pane splits beside the active pane, so it never
displaces the session from index 0. Window flags are per window, not per pane.
