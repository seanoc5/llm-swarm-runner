# Recording the llm-swarm-runner Demo

End-to-end recipe for capturing a clean ~75-second demo of the swarm runner using **SimpleScreenRecorder** (SSR) on Linux and post-processing with the in-tree `scripts/edit-demo.sh`.

This doc replaces the chat-relayed steps. If you've recorded a demo before and just want the cheatsheet, jump to [TL;DR](#tldr).

## TL;DR

```bash
# One-time (or after an SSR upgrade that resets settings):
./scripts/demo-record-setup.sh

# Each take:
simplescreenrecorder &                              # in a new terminal, no tmux
cd /opt/work/llm-swarm-runner                       # in ANOTHER new terminal, also no tmux
DRY_RUN=1 ./scripts/demo-driver.sh                  # pre-flight (optional)
# … hit Start Record in SSR …
./scripts/demo-driver.sh                            # the swarm side runs
# … hit Stop Record in SSR …
./scripts/edit-demo.sh                              # consumes ~/Videos/demo-raw.mkv
# Final: ~/Videos/demo-final.mp4
```

## Why a separate setup script?

SSR persists settings between runs in `~/.ssr/settings.conf`, but the values that matter for *this* demo aren't its installer defaults — different capture rect, different output path, no timestamp suffix. `scripts/demo-record-setup.sh` patches the file in-place, touching only the keys we care about and leaving your hotkeys / screen / audio prefs alone. It's idempotent: re-running is a no-op once the file is tuned.

Run it once per machine. Re-run after any SSR upgrade that resets settings (rare).

## Capture rect: terminal-only, 1920×1080

The full-screen default wastes pixels on desktop chrome that the final downscale to 1280×720 then squashes — terminal text ends up soft. The tuned setup uses a **fixed 1920×1080 rectangle anchored at (0, 0)**, which:

- a. Downscales cleanly (1.5×) to the 1280×720 final size — sharp text, no fractional-pixel blur.
- b. Comfortably fits a tmux session at a readable font.
- c. Excludes panel / clock / notification icons / unrelated windows.
- d. Doesn't depend on SSR's "follow window" mode (which doesn't actually follow — it snapshots window coords at click-time).

**Before each take**, size and position your terminal to occupy that exact 1920×1080 rect:

```bash
# focus the terminal, then:
wmctrl -r :ACTIVE: -e 0,0,0,1920,1080
```

(Or maximise / drag to fill the top-left 1920×1080 of your screen. The rect is fixed; the recording will catch whatever's inside it.)

If your terminal font is too small at 1920×1080 to comfortably read in the final 1280×720, drop the rect by editing `~/.ssr/settings.conf` to `video_w=1600 video_h=900` instead — still a clean 1.25× downscale, bigger text.

## Pre-flight

`demo-driver.sh` scopes the swarm to issues labelled `demo` (open). It will fail hard on an empty pool and warn if `< MIN_DEMO_BACKLOG=3`.

```bash
gh issue list --label demo --state open
# top up if low:
gh issue create --label demo --title "..." --body "..."
```

The pool is self-healing: merged PRs auto-close their linked issues, dropping them from the next run. No hard-coded issue numbers to maintain between retakes.

`DRY_RUN=1 ./scripts/demo-driver.sh` runs all the pre-flight checks (label exists, backlog count, tmux session reset) without actually spawning anything.

## Recording, step-by-step

Each step is small on purpose — you want a deterministic take, not a "see what happens" run.

i. **Open a fresh terminal** (NOT inside a tmux session — `demo-driver.sh` creates its own).
ii. **Position it** at the 1920×1080 rect (the `wmctrl` line above, or by hand).
iii. **In a second terminal** (also not in tmux), launch SSR: `simplescreenrecorder &`. SSR loads `~/.ssr/settings.conf` automatically.
iv. **Verify the rect** in SSR's preview window matches the first terminal.
v. **Hit Start Record** in SSR's GUI (or its hotkey — Super+Ctrl by default; check `~/.ssr/settings.conf` `[record]` section).
vi. **Wait ~1 second** so the first frame isn't the SSR window itself.
vii. **Switch focus to the first terminal** and run `./scripts/demo-driver.sh`.
viii. **Watch and answer prompts** — when workers propose a 🟢-low self-merge, type `y` / `yes` / `ship` / `go` in the worker pane. `demo-driver.sh` dwells on each worker pane for `MERGE_CONFIRM_DWELL_SECS` (default 30s) to catch this.
ix. **Hit Stop Record** in SSR when the script exits and the final `gh pr list` dwell completes.

The recording lands at `~/Videos/demo-raw.mkv` (overwriting any previous take — that's intentional, retakes are cheap).

## Post-processing

```bash
./scripts/edit-demo.sh
# or, with explicit paths:
./scripts/edit-demo.sh ~/Videos/demo-raw.mkv ~/Videos/demo-final.mp4
```

`edit-demo.sh` reads the `SEGMENTS=(...)` array near the top of its source and stitches the segments together with per-segment speed multipliers. **After your first take, you'll need to update those timestamps** to match the actual beats. Two ways to do it:

a. **Interactive picker** (recommended for a fresh take):

   ```bash
   ./scripts/demo-segments-pick.sh > /tmp/segments.txt
   # in mpv: press `c` at the start AND end of each beat, `q` to quit.
   # then answer SPEED/LABEL prompts for each pair.
   ```

   Paste the resulting `SEGMENTS=(...)` block over the one in `edit-demo.sh`.

b. **Manual scrub**: open the raw in mpv/ffprobe, eyeball the times, hand-edit the `SEGMENTS=(...)` array.

Each row is:

```
"START_TIME END_TIME SPEED LABEL"
```

`SPEED=8.0` fast-forwards a long boring stretch (worker doing work). `SPEED=1.0` keeps real-time on the money beats (coordinator dispatching, worker proposing merge, you typing `yes`).

Iteration is cheap: edit a timestamp, re-run, ffmpeg re-encodes only that segment.

Final output knobs (also at the top of `edit-demo.sh`):

| Knob | Default | Notes |
|---|---|---|
| `RES` | `1280:720` | Final resolution. 720p is Reddit-friendly. |
| `CRF` | `26` | 23 = high quality / bigger file; 28 = scrappy / smaller. |
| `FPS` | `30` | Matches the source. |
| `END_CARD_SECS` | `3` | Length of the black "github.com/seanoc5/llm-swarm-runner · MIT" end card. |

## Troubleshooting

### "no open issues labeled 'demo'"
Pre-flight aborted on an empty pool. Top up with `gh issue create --label demo --title "..." --body "..."`, then re-run.

### SSR records but the terminal text looks soft in `demo-final.mp4`
You're probably still on full-screen capture. Run `./scripts/demo-record-setup.sh` (without `--dry-run`) — it'll tell you exactly which keys are off and patch them. Verify the SSR preview shows just the 1920×1080 rect, not the whole screen.

### Recording overwrites every time — I want to keep takes
That's the default for fast iteration. If you want to archive a take, copy it before the next recording: `cp ~/Videos/demo-raw.mkv ~/Videos/demo-raw-take1.mkv`. Or temporarily flip `add_timestamp=true` in `~/.ssr/settings.conf` for the session.

### `edit-demo.sh` says "input file doesn't exist"
Default path is `~/Videos/demo-raw.mkv`. Either SSR wrote somewhere else (check `~/.ssr/settings.conf` `[output]` `file=`), or the recording produced a `.mkv.part` file because SSR was interrupted. Pass the actual path explicitly: `./scripts/edit-demo.sh /actual/path.mkv`.

### Worker doesn't propose a merge during the recording
`MERGE_PROPOSAL_TIMEOUT_SECS` (default 180s) controls how long `demo-driver.sh` waits for the worker to surface a 🟢-low self-merge before falling back to a plain pane-dwell. Issues labelled `demo` should be small enough that workers finish well inside that — if they're not, either trim the issue scope or raise the timeout for this take: `MERGE_PROPOSAL_TIMEOUT_SECS=300 ./scripts/demo-driver.sh`.

### I want a different rect than 1920×1080
Edit `~/.ssr/settings.conf` `[input]` `video_w` / `video_h` after running the setup script. The setup script writes the demo defaults but doesn't lock them — your edit stands until you re-run the setup script. (Or edit the targets in `scripts/demo-record-setup.sh` itself if you want the new size to be the persistent default.)

### I forgot to set the capture rect and the raw includes too much desktop
`edit-demo.sh` accepts a `CROP` env var that trims pixels before the scale/fps pass — no re-record needed. Either give it explicit coords:

```bash
CROP="1920:1080:0:0" ./scripts/edit-demo.sh        # top-left 1080p of a larger capture
```

…or let it sniff the terminal rect itself:

```bash
CROP=auto ./scripts/edit-demo.sh                   # cropdetect on a negated sample
```

`CROP=auto` inverts a sample frame (~25% into the raw) so the bright desktop becomes the "border" ffmpeg's `cropdetect` knows how to trim. Works when the terminal background is consistently dark and the desktop isn't (panels, light wallpaper, etc.). If the desktop is mostly black too, fall back to the explicit `W:H:x:y` form.

## Related

- [`scripts/demo-driver.sh`](../scripts/demo-driver.sh) — coordinates the swarm side of the demo. Self-documents its env vars at the top.
- [`scripts/edit-demo.sh`](../scripts/edit-demo.sh) — post-processing. The `SEGMENTS` array is the only thing you'll routinely edit.
- [`scripts/demo-record-setup.sh`](../scripts/demo-record-setup.sh) — SSR config patcher. Idempotent.
- [README → Show me first](../README.md#show-me-first) — short pointer to the demo for new readers.
