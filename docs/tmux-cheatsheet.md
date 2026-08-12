# tmux cheatsheet (for the swarm workflow)

A short reference to the tmux commands that actually come up when you're running `llm-start.sh` and managing a worker swarm. Not exhaustive — see `man tmux` for the full surface.

> **Note:** Default tmux prefix is `Ctrl-b`. If you've rebound it (e.g. `Ctrl-Space` or `Ctrl-a`), substitute your prefix below wherever you see `<prefix>`.

Conventions used below:
- `<prefix>` = your tmux **prefix key** (see note above). After pressing it (briefly) you then press the next key.
- `<session>` = your swarm session name — typically `llm-<project-basename>` (e.g. `llm-fand-app`).
- `<socket>` = the swarm's socket name — `swarm-<project-basename>` (e.g. `swarm-fand-app`).

> **Swarm sockets:** `llm-start.sh` runs each swarm on its **own tmux server**, addressed by socket name. A bare `tmux` command talks to your *default* server and won't see any swarm session — prefix the commands below with `-L <socket>` when targeting a swarm, e.g. `tmux -L swarm-fand-app attach -t llm-fand-app`. `scripts/list-swarms.sh` enumerates all swarm sockets (LIVE vs ORPHAN) with ready-to-paste attach commands.

---

## 1. Attach to / detach from a running session

| What                                                          | Command                                                                                       |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| List sessions on this host                                    | `tmux ls`                                                                                      |
| Attach (mirror — other clients stay attached)                 | `tmux attach -t <session>`                                                                     |
| Attach AND detach any other clients first (clean handoff)     | `tmux attach -d -t <session>`                                                                  |
| Detach yourself (leaves session running in background)        | Inside tmux: `<prefix> d`                                                                     |

**Multi-attach / sizing**: tmux fits the session to the **smallest** attached client by default. If your laptop terminal is 120×40 and your desk monitor is 200×60, attaching from the laptop without `-d` will shrink the session to 120×40 in both terminals. Use `tmux attach -d -t …` to claim exclusive control, or use a session group (#10 below) for truly independent views.

## 2. Session lifecycle

| What                                                          | Command                                                                                       |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| Kill one session                                              | `tmux kill-session -t <session>`                                                               |
| Kill the tmux server entirely (all sessions)                  | `tmux kill-server`                                                                            |
| Rename current session                                        | Inside tmux: `<prefix> $`                                                                      |
| Check whether a session exists (scriptable)                   | `tmux has-session -t <session>` (exit 0 = exists)                                              |

## 3. Window navigation (each `iss-N` worker is a window)

| What                                                          | Command                                                                                       |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| Next / previous window                                        | `<prefix> n` / `<prefix> p`                                                                   |
| Jump to window by number                                      | `<prefix> 0` … `<prefix> 9`                                                                   |
| Pick window from a list (with previews)                       | `<prefix> w`                                                                                  |
| Find window by name (substring search)                        | `<prefix> f` then type `iss-215`                                                               |
| Show window number of currently-focused window                 | `<prefix> q`                                                                                   |

## 4. Inspecting a worker without disturbing it (capture-pane)

This is the key trick for diagnosing dead/stuck workers without scrolling around:

```bash
# Last 200 lines of a window's pane to your shell
tmux capture-pane -t <session>:<window> -p -S -200

# Last 50 lines, into less
tmux capture-pane -t llm-fand-app:iss-215 -p -S -50 | less

# Full scrollback (huge — pipe to a file)
tmux capture-pane -t <session>:<window> -p -S - > /tmp/iss-215-full.log
```

`-p` = print to stdout; `-S -N` = start N lines back in the scrollback buffer; omit `-S` for current pane only.

> **Careful attributing what you read.** Plain `capture-pane -p` strips color, so a dimmed composer suggestion, a `※ recap:` line, or a spinner can look exactly like something the operator actually typed. Never report "the user/worker said X" from a raw capture without checking the session transcript first — see [`docs/tmux-as-channel.md`](./tmux-as-channel.md) §1d. `scripts/capture-worker.sh <window>` tags known chrome inline; `scripts/capture-worker.sh <window> --verify "<text>"` checks the transcript for you.

## 5. Scrollback / search inside a window (interactive)

| What                                                          | Command                                                                                       |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| Enter copy/scrollback mode                                    | `<prefix> [`                                                                                  |
| Scroll up / down (in copy mode)                                | `PgUp` / `PgDn`, or arrow keys                                                                 |
| Search backward                                                | `Ctrl-r` then type term, `Enter` (default emacs mode); `?` then type term, `Enter` (vi mode)   |
| Search forward                                                 | `Ctrl-s` (default emacs mode); `/` then type term, `Enter` (vi mode)                           |
| Exit copy mode                                                 | `q`                                                                                            |

> The example config at [`examples/tmux.conf.example`](../examples/tmux.conf.example) sets `setw -g mode-keys vi` — if you've installed it (or otherwise set vi copy-mode keys), use the `?` / `/` forms above instead of `Ctrl-r` / `Ctrl-s`.

## 6. Killing a single window (worker)

```bash
tmux kill-window -t <session>:<window>     # specific window
tmux kill-window -t llm-fand-app:iss-215   # the iss-215 worker
```

For bulk worker cleanup, use [`scripts/kill-finished-workers.sh`](../scripts/kill-finished-workers.sh) — it handles parked-only filtering, PR-safety, and confirmation prompts.

## 7. Send a command into a window from outside

Useful for waking the coordinator without attaching:

```bash
# Type a command + press Enter into a specific window's pane
tmux send-keys -t llm-fand-app:coordinator "claude --resume <id>" Enter
```

`Enter` (or `C-m`) is what actually runs the command. Without it, the text just sits at the prompt.

## 8. List windows / panes (scriptable inspection)

```bash
# All windows in a session, with names
tmux list-windows -t <session> -F '#{window_index} #{window_name} #{pane_current_command}'

# Every pane across every session, with state flags
tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} dead=#{pane_dead}'

# Idle time in seconds for each window (uses last-activity timestamp)
tmux list-windows -t <session> -F '#{window_name} idle=#{e|-:#{t:#{window_activity}},#{t:now}}s'
```

The `dead=1` flag is what we look for when a watcher pane crashes and shows "Pane is dead (status N)".

## 9. Resurrect a dead pane (rerun the command in-place)

When you see `Pane is dead (status 1, ...)`:

```bash
# Just close it and re-spawn the window
tmux kill-window -t llm-fand-app:watch
tmux new-window -t llm-fand-app -n watch \
    "/opt/work/llm-swarm-runner/scripts/coordinator-watch.sh /opt/work/oconeco/fand-app"

# OR with the alternative respawn-pane (preserves window number, scrollback gone):
tmux respawn-pane -k -t llm-fand-app:watch \
    "/opt/work/llm-swarm-runner/scripts/coordinator-watch.sh /opt/work/oconeco/fand-app"
```

`respawn-pane -k` kills any process in the pane first; without `-k` it errors if the pane already has a live process.

## 10. Session groups (independent views across attached clients)

If you genuinely need two terminals viewing different windows of the same session simultaneously (e.g., laptop watching `iss-215` while desk shows `coordinator`):

```bash
# Create a "linked" session that shares windows but allows independent focus
tmux new-session -t llm-fand-app -s llm-fand-app-2

# Then on the second terminal:
tmux attach -t llm-fand-app-2

# Both sessions see the same windows. Each terminal can be on a different
# window. Killing a window kills it in both. Killing one session leaves
# the other intact.
```

Useful for the laptop+desk scenario where you don't want size-fighting AND don't want to mirror.

---

## Common scenarios in this project

| Scenario                                                                       | Command                                                                                                            |
|--------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| SSH'd in from a different machine, want to take over from the local terminal   | `tmux attach -d -t llm-<project>`                                                                                  |
| Watch a worker's progress without leaving your current shell                    | `tmux capture-pane -t llm-<project>:iss-215 -p -S -50`                                                              |
| Worker pane shows "Pane is dead" — what was the last output?                    | `tmux capture-pane -t llm-<project>:<window> -p -S -200`                                                            |
| All 5 workers finished; want to clean up                                        | `kill-finished-workers.sh --dry-run` then `kill-finished-workers.sh`                                                |
| Forgot to detach before closing terminal — session still running?               | `tmux ls` (it survived; just `tmux attach`)                                                                        |
| Need to nuke EVERYTHING and start over                                          | `tmux kill-session -t llm-<project>` (or `tmux kill-server` for all sessions on the host)                          |
| Want a separate "control" terminal that drives the coordinator from outside    | `tmux send-keys -t llm-<project>:coordinator "<your prompt>" Enter`                                                |
| Need a shell inside a worker container without disturbing claude               | `Ctrl-z` in any `iss-*` window — splits a sibling bash pane that `docker exec`s into the same container, claude in the original pane is untouched ([details](./advanced-usage.md#worker-escape-hatch-ctrl-z-opens-a-sibling-bash-pane)) |

## Customizing tmux for this workflow

A starter config tuned for the swarm — bigger scrollback (50000 lines, so `capture-pane -S -50000` actually has history to capture), 1-indexed windows, mouse mode, vi-style copy bindings, a Ctrl-a prefix rebind, and the [Ctrl-Z worker escape hatch](./advanced-usage.md#worker-escape-hatch-ctrl-z-opens-a-sibling-bash-pane) — lives at [`examples/tmux.conf.example`](../examples/tmux.conf.example). Each block is independent; copy what you want:

```bash
cp examples/tmux.conf.example ~/.tmux.conf
tmux source-file ~/.tmux.conf      # reload in a running session
```

If you only want the prefix rebind and nothing else, the minimum is three lines:

```tmux
unbind C-b
set -g prefix C-a
bind C-a send-prefix
```

(One last press of the old prefix before the rebind takes effect for the current session.)
