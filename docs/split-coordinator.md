# Split coordinator: conversation session and work runs (issue #767)

*Read this when you set `COORD_MODE=split` in `.swarm/.env`, or want to know where a work run keeps its memory. Design and measurements: [ADR 0006](adr/0006-split-coordinator-work-runs-and-conversation.md).*

## What `COORD_MODE=split` changes

| | `resident` (default, unchanged) | `split` |
|---|---|---|
| Coordinator window | one session: chat + inbox loop | the **conversation session** only; `llm-start.sh` renders `prompts/coordinator-chat.md` + `prompts/coordinator-shared.md` |
| Typed wake prompts | pasted into the session | never: `llm-start.sh` logs `coord.wake.skip reason=split_mode` and leaves the pane alone |
| Urgent inbox item | doorbell | 📥 flag on the `coordinator` window tab (set by the watcher as it writes the item) |
| Changed Needs-you list | the session rewrites it | one context line on your next message ("Needs-you changed since your last message: 1 new item(s)...") from the `UserPromptSubmit` hook; the 📥 flag clears at the same moment |
| Prompt for a work run | n/a | `scripts/render-coordinator-prompt.sh work` (`prompts/coordinator-work.md` + shared) |
| Merges | the session | work run: opt-in automerges only; explicit merges (`merge PR N`, 🔴 `merge PR N red`) are the conversation session's, in your own turn |

The launcher that starts work runs (lock, log, timeout, budget) is **not** part of this change (ADR 0006 step A2). Until it exists a split-mode swarm has nobody triaging the inbox on its own; run a work run by hand with `scripts/render-coordinator-prompt.sh work > /tmp/work.md && claude -p --append-system-prompt-file /tmp/work.md "Run once."` if you want to try one.

### Where the mode lives

`COORD_MODE` is read from one place: `<project>/.swarm/.env`. `scripts/_coord-split.sh` (`coord_mode`) reads that file directly each time a script needs the mode, so `llm-start.sh` (and with it every wake), `coordinator-claude.sh`, `coord-hook.sh` and the watcher always agree. Your shell's `COORD_MODE`, the tmux session env and `.env.example` are ignored for this one setting: `COORD_MODE=split ./llm-start.sh` does **not** work. If your shell's value disagrees with the file, `llm-start.sh` prints one `WARN:` and follows the file. Nothing kills or restarts a watcher because of the mode; a running watcher follows an edit at its next wake.

### Turning it on

Run these in order, from a shell in the project (`<project>` is its directory, `<sandbox>` is the llm-swarm-runner checkout, `llm-<project>` is the tmux session name `llm-start.sh` prints):

1. `echo 'COORD_MODE=split' >> <project>/.swarm/.env` (first: from now on a wake reads split mode and skips the resident coordinator, so nothing can relaunch it)
2. `tmux kill-window -t llm-<project>:coordinator` (ends the running resident coordinator)
3. `cd <project> && <sandbox>/llm-start.sh` (opens the conversation session with the chat prompt)

Killing the window first would leave a gap: a wake in it still reads resident mode and relaunches a resident coordinator, and step 3 would then only attach to it.

### Rolling back

1. `tmux kill-window -t llm-<project>:coordinator` (first, so a wake between the kill and the edit cannot reach the live chat session; the opposite order from turning it on, because here the edit is what lets a wake relaunch the resident coordinator)
2. `sed -i '/^COORD_MODE=/d' <project>/.swarm/.env` (no line means resident)
3. `cd <project> && <sandbox>/llm-start.sh` (opens the resident coordinator again)

That is the whole procedure: no watcher restart and no tmux variable to clear. The next wake already reads the edited file.

The new files below are inert in resident mode.

## Telling the work run something

A work run has no memory of your chat, so it only knows what is in a file:

```
scripts/operator-note.sh "dispatch #123 now"              # one-off: inbox note, starts a run
scripts/operator-note.sh --standing "hold #123"           # standing: also appended to .swarm/operator-notes.md
```

The inbox file is `<UTC ts>-operator-<pid>-<rand>.md`. The kind `operator` is not in the batching table, so it counts as urgent (unknown kinds always do, [quiet-wakes](quiet-wakes.md)). To lift a standing instruction, delete its line in `.swarm/operator-notes.md`.

## State between runs (ADR 0006 section 1)

A work run starts with no memory, so everything it needs is one of these:

| What | Where | Written by | Read by |
|---|---|---|---|
| Work queue and archive | `.swarm/coord-inbox/`, `processed/` | watcher, `operator-note.sh`; the run archives | the run |
| Your standing instructions | `.swarm/operator-notes.md` | `operator-note.sh --standing` | the run (first), the conversation session |
| Standing Needs-you list | `.swarm/needs-you.md` | the run, only when the list changes | the conversation session, the hook, you |
| Previous digest ("Moved since last run" diffs against it) | `.swarm/work-run/last-digest.md` | the run, every run | the next run |
| Run bookkeeping (start, finish, exit, tokens) | `.swarm/work-run/runs.log` | the run wrapper (ADR step A2, not built yet) | you |
| Worker briefs and outcomes | `.swarm/tasks/` | workers, watcher | the run |
| Live truth about windows and PRs | `tmux list-windows`, `gh pr list` | n/a | the run, re-queried each time |

Also local to the conversation session: `.swarm/needs-you.seen`, the copy of the list the hook last told your session about (it diffs against it to count new items).

## Surfacing changes without waking the session

- **Flag.** `coord_split_flag_urgent` (`scripts/_coord-split.sh`) is called from the watcher's inbox writer. For an urgent kind other than `operator` it sets 📥 on the `coordinator` window via `set_window_flag` (`WATCH_WINDOW_FLAGS=0` turns flags off).
- **Hook.** `scripts/coord-hook.sh UserPromptSubmit` runs when you press Enter, prints `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}` if the list changed, and clears 📥. In split mode `Stop` never rings and never asks for a waiter. `coordinator-claude.sh` installs the hook in split mode even with `COORD_HOOK_STATE=0`.
- Gemini, codex and agy have no such hook: the chat prompt tells them to read `.swarm/needs-you.md` at the start of each turn.
