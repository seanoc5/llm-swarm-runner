# Coordinator viewer layout (`COORD_VIEWER`)

One window to read and type in: the `coordinator` tmux window shows a clean,
read-only conversation view (your messages and the coordinator's replies) in a
large pane, with the Claude session as a small typing pane. Off by default.
Issue #785.

## Turn it on

- For every start: set `COORD_VIEWER=1` in the project's `.swarm/.env` (viewer
  height: `COORD_VIEWER_PCT`, default 75; see "Small windows" below for its floor). `llm-start.sh` adds the viewer, also
  on a re-run against a live session (idempotent).
- For a running session: `scripts/coordinator-layout.sh on` (from the project dir).

## Turn it off

- `scripts/coordinator-layout.sh off` closes the viewer; the session and the
  watcher are not touched. Remove `COORD_VIEWER=1` from `.swarm/.env` so the
  next start doesn't add it back. `scripts/coordinator-layout.sh status` prints on/off.
- While `COORD_VIEWER=1` is still set, every `llm-start.sh` run (including each
  doorbell wake) re-adds a viewer you closed, by `off` or by hand
  (`prefix` `x`), and that shrinks the session pane again. To keep it closed,
  remove the setting first.

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

## Small windows: limits

The busy and composer checks read the session pane's screen. A short pane can
push the "esc to interrupt" line (above a long todo list) off the visible rows,
and a doorbell or `/compact` would then land mid-turn. Two guards:

- **Floor.** The viewer never takes the session pane below
  `COORD_VIEWER_MIN_SESSION_ROWS` rows (default 12; one more row is the border).
  `COORD_VIEWER_PCT=90` on a 24-row window therefore gives the session 12 rows,
  not 2. A window too short for the floor plus a 3-row viewer (under 16 rows by
  default) gets no viewer at all; `coordinator-layout.sh on` says so and exits 1.
  The floor applies when the viewer is added. If you shrink the terminal or drag
  the border afterwards, nothing re-enforces it.
- **Scrollback.** For any pane shorter than `COORD_BUSY_FULL_ROWS` (24), if the
  visible rows show no busy marker, the last `COORD_BUSY_SCROLLBACK_LINES` (60)
  lines of scrollback are searched too (`coord_pane_busy_match` in
  `scripts/_coord-layout.sh`; used by the watcher's busy check, the compact
  confirm/retract checks and `llm-start.sh`'s composer checks).

Limits of the scrollback guard:

- A marker left in scrollback by a finished turn reads busy until the pane text
  has been unchanged for `COORD_BUSY_SCROLLBACK_MAX_SECS` (default 90), then
  idle; any new pane text re-arms it. So a stale marker costs at most about
  90s of deferred doorbells or auto-compact. State: a small file under
  `$TMPDIR` (`COORD_BUSY_STATE_FILE` to move it).
- The reverse also holds: a turn that is genuinely running but prints nothing
  for 90s and has its marker only above the visible rows reads idle after 90s.
  This is the same blind spot the visible-only check had, narrowed to that case.
  The wake path prefers the hook state file when it has one, so it is less exposed.
- Only the marker search is widened. "Is the composer empty" still looks at the
  bottom non-blank line, which is visible at any height.
- Not verified against a live Claude Code pane: how its TUI leaves old frames in
  scrollback when its live area is taller than the pane. The tests use a fake
  session with the marker scrolled above the visible rows.

## Other places that touch the coordinator pane (audit, #785)

All use an explicit `.0` except two that used "first listed pane", now explicit
and viewer-aware: `llm-start.sh` pane-state detection (`display-message -t
...coordinator.0`) and `coordinator_pane_state` in `coordinator-watch.sh`.
Unchanged because they already target `.0`: wake and `/compact` paste paths,
`capture-worker.sh`, dead-pane cleanup. Changed in the small-window review:
every busy-marker read of a Claude pane (`coordinator_pane_busy`,
`compact_confirm_submitted`, `compact_retract_queued`, `reprompt_composer_dirty`,
`reprompt_confirm_submitted`) now goes through `coord_pane_busy_match`, which
adds scrollback in short panes. The "last composer line" readers stay
visible-only on purpose. The Ctrl-Z scratch pane splits beside the active pane, so it never
displaces the session from index 0. Window flags are per window, not per pane.
