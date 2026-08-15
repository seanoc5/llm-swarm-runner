# Terminal emulators for swarm work

The swarm runs entirely inside tmux, so the terminal emulator you attach *with* is
your choice — the swarm neither knows nor cares. But that choice does affect
several things you will notice daily: whether Shift+Enter inserts a newline in a
Claude worker, whether desktop notifications reach you, and how the UI holds up
when eight workers are all streaming output at once.

**Short version:** use **kitty** (or ghostty, wezterm, foot, alacritty) as the
outer terminal, and keep tmux for all multiplexing. Do not try to replace tmux
with kitty's own tabs and splits — the swarm depends on capabilities kitty
deliberately does not have.

## Why a modern terminal helps

| Benefit | Detail |
|---|---|
| **Shift+Enter inserts a newline** | The big one. Claude Code (and every browser-based chat client) uses Shift+Enter for newline, Enter for submit. This requires a terminal that encodes keyboard modifiers — see [Shift+Enter](#shiftenter-the-one-that-needs-configuration) below. |
| **Desktop notifications** | Claude Code fires a notification when a worker finishes or needs a permission decision. kitty and ghostty forward these to the OS notification centre with no setup, which matters when you are supervising several workers. Requires `allow-passthrough on` in tmux. |
| **OSC 52 clipboard over SSH** | Copy from a tmux pane straight into the system clipboard, including when attached from another machine. gnome-terminal only gained this in VTE 0.78+. |
| **Throughput** | GPU-accelerated rendering holds up better when many worker panes stream verbose output simultaneously. |
| **OSC 8 hyperlinks** | `gh`, Claude Code, and `ls --hyperlink` emit real links; Ctrl+click opens them. |

## Terminal compatibility

| Terminal | Shift+Enter |
|---|---|
| kitty, ghostty, wezterm, foot, iTerm2, Warp, Windows Terminal | Works |
| VS Code, Cursor, Alacritty, Zed | Works after `/terminal-setup` |
| **gnome-terminal / VTE**, JetBrains IDE terminals | **Not possible** — use Ctrl+J |

gnome-terminal implements neither the kitty keyboard protocol
([GNOME/vte#2601](https://gitlab.gnome.org/GNOME/vte/-/issues/2601), still open)
nor xterm's `modifyOtherKeys`. It transmits identical bytes for Enter and
Shift+Enter, so no tmux or Claude Code setting can recover the difference. This is
the single strongest reason to switch.

## The elephant: kitty and tmux overlap, and kitty's author says so

This should be stated plainly rather than glossed over. kitty has tabs, windows
(splits), layouts, startup sessions, and scriptable remote control via
`kitten @`. Those genuinely duplicate a large part of what tmux does, and running
one inside the other means two layers of key handling, two scrollbacks, and two
sets of keybindings competing for the same chords.

kitty's author holds this position explicitly. The
[kitty FAQ](https://sw.kovidgoyal.net/kitty/faq/) states that terminal
multiplexers *"are a bad idea, do not use them, if at all possible"*, and that
kitty *"contains features that do all of what tmux does, but better, **with the
exception of remote persistence**"*. The stance is deliberate, not an oversight:
kitty declined to implement `modifyOtherKeys` for tmux's benefit
([kovidgoyal/kitty#5508](https://github.com/kovidgoyal/kitty/issues/5508)), and a
request for remote session support was closed and locked. There is a reasoned
argument behind it — a multiplexer becomes an involuntary gatekeeper for every new
terminal feature, and it costs throughput.

**That "exception of remote persistence" is the entire foundation of this
project.** Taking the objection seriously and then weighing it:

| What the swarm needs | tmux | kitty |
|---|---|---|
| **Headless sessions** — `llm-start.sh` runs `tmux new-session -d` with no client attached at all | Yes | No. A kitty window requires a display and a live process |
| **Survives disconnect** — swarm runs span hours or days; close the terminal, sessions keep working | Yes, sessions live in a server process owned by systemd | No. Windows die with the kitty process |
| **Attach from elsewhere** — SSH in from another machine and pick up the same session | Yes | No |
| **`send-keys` as a control channel** — how briefs get dispatched into worker panes ([tmux-as-channel.md](./tmux-as-channel.md)) | Yes | `kitten @` exists but needs `allow_remote_control` and a live local instance |
| **`capture-pane` for observability** — inspect a worker without disturbing it ([tmux-cheatsheet.md](./tmux-cheatsheet.md#4-inspecting-a-worker-without-disturbing-it-capture-pane)) | Yes | No equivalent |

So the overlap is real, and the criticism about layering is fair. It just does not
change the conclusion here: **the swarm cannot run on kitty alone.** Use kitty as a
fast, capable host window and let tmux own the multiplexing.

Practically, that means: create swarm windows as **tmux** windows, not kitty tabs.
A kitty tab holding a worker looks equivalent right up until you close the laptop
lid or your SSH drops, at which point the tmux version is still running and the
kitty version is gone.

## What actually breaks when tmux runs inside kitty

Be aware of these before switching — none are blockers, but they are real:

1. **Extended keys need explicit configuration.** kitty speaks its own keyboard
   protocol; tmux only knows how to ask via `modifyOtherKeys`; neither implements
   the other's. The word "kitty" appears nowhere in
   [tmux's CHANGES](https://raw.githubusercontent.com/tmux/tmux/master/CHANGES).
   **Upgrading tmux does not fix this** — see the config below for what does.
2. **Inline images do not survive tmux.** kitty's graphics protocol requires
   multiplexer support that tmux lacks ([tmux/tmux#4902](https://github.com/tmux/tmux/issues/4902)).
   kitty's unicode-placeholder mode is a partial workaround.
3. **Throughput cost.** kitty's docs put the best case for a multiplexer at
   roughly a 2x reduction in throughput. Rarely noticeable in practice for swarm
   work, but it is not free.
4. **Notifications need passthrough.** Without `allow-passthrough on`, tmux
   swallows the escape sequences and no notification reaches your desktop.
5. **Newer niceties are hit-or-miss.** Styled underlines, variable-sized text and
   similar depend on tmux having added support.

## Configuration

Three files. All of this is optional — the swarm works without it — but this is
what makes Shift+Enter behave.

**`~/.config/kitty/kitty.conf`**

```conf
map shift+enter send_text all \x1b[13;2u
```

This is the load-bearing line. It stops relying on protocol negotiation (which
cannot succeed between kitty and tmux) and emits the CSI-u encoding
unconditionally. tmux parses it regardless of what was negotiated, because tmux
"always recognises extended keys itself" (`man tmux`). The bytes are identical to
what the kitty protocol would have sent, so applications talking to kitty
directly are unaffected.

**`~/.tmux.conf`**

```tmux
set -s extended-keys always
set -as terminal-features 'xterm*:extkeys'
set -g allow-passthrough on
```

`always` rather than `on`: `on` forwards extended keys only to panes that
requested them through tmux's own mechanism, and Claude Code asks using the kitty
protocol, which tmux does not recognise — so under `on` it never qualifies. Same
conclusion as [claude-code#26629](https://github.com/anthropics/claude-code/issues/26629).

**`~/.byobu/.tmux.conf`** — the same three lines, if you use byobu. It runs its own
tmux server via `-f /usr/share/byobu/profiles/tmuxrc`, which bypasses
`~/.tmux.conf` entirely.

### Two gotchas specific to the swarm

**`extended-keys` is a per-server option, and the swarm runs one server per
project** (`tmux -L $SWARM_SOCKET`, `llm-start.sh:55`). Newly-started swarms pick
up `~/.tmux.conf` automatically; servers already running when you edit it do not:

```bash
for sock in /tmp/tmux-1000/*; do
  s=$(basename "$sock")
  tmux -L "$s" has-session 2>/dev/null || continue
  tmux -L "$s" source-file ~/.tmux.conf
  printf "%-32s extended-keys=%s\n" "$s" \
    "$(tmux -L "$s" show-options -s extended-keys | awk '{print $2}')"
done
```

**The handshake happens per client at attach time.** A session you attached from
the old terminal keeps its old capabilities even after sourcing the config —
detach and reattach from kitty. Confirm with:

```bash
tmux display-message -p 'termname=#{client_termname} termtype=#{client_termtype}'
# want: termname=xterm-kitty  termtype=kitty(0.32.2)
```

## Verifying

Do **not** test at a bash prompt or with `cat -v`. Extended keys are opt-in per
application, and neither bash/readline nor `cat` ever opts in — a perfectly
configured terminal is *supposed* to send a plain `\r` to them. Use something
that requests the protocol:

```bash
kitten show-key -m kitty     # -m kitty makes the kitten itself request it
```

Then the real test: press Shift+Enter in a Claude worker pane.

### Side effect

Shift+Enter now emits `\x1b[13;2u` to everything, including programs that never
asked. In bash you will see stray `;2u` characters at the prompt — readline
consumes `\x1b[13` as an unrecognised partial escape, gives up, and inserts the
rest literally. Add to `~/.inputrc` to silence it:

```
"\e[13;2u": accept-line     # Shift+Enter submits, as before
```

## If you stay on gnome-terminal

Everything in the swarm works. You lose Shift+Enter (use **Ctrl+J**, or `\`
followed by Enter — both work in every terminal with zero setup), desktop
notifications, and OSC 52 clipboard on VTE < 0.78. The tmux settings above are
harmless to leave in place; they are simply inert.

## See also

- [tmux Cheatsheet](./tmux-cheatsheet.md) — the commands you will actually use
- [tmux as a channel](./tmux-as-channel.md) — why `send-keys`/`capture-pane` are load-bearing
- [Configure your terminal for Claude Code](https://code.claude.com/docs/en/terminal-config)
- [Your Terminal Can't Tell Shift+Enter from Enter](https://blog.fsck.com/agent-blog/2026/02/26/terminal-keyboard-protocol/) — background on the protocols
- [kitty FAQ](https://sw.kovidgoyal.net/kitty/faq/) — the multiplexer position, in the author's own words
