# Split coordinator: conversation session and work runs (issue #767)

*Read this when you set `COORD_MODE=split`, or want to know where a work run keeps its memory. Design and measurements: [ADR 0006](adr/0006-split-coordinator-work-runs-and-conversation.md).*

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

### Turning it on

Run these in order, from a shell in the project (`<project>` is its directory, `<sandbox>` is the llm-swarm-runner checkout, `llm-<project>` is the tmux session name `llm-start.sh` prints):

1. `echo 'COORD_MODE=split' >> <project>/.swarm/.env`
2. `tmux kill-window -t llm-<project>:coordinator` (ends the running resident coordinator; `llm-start.sh` only relaunches a pane that is gone or idle)
3. `cd <project> && <sandbox>/llm-start.sh` (opens the conversation session, sets the tmux session's `COORD_MODE` to split, and restarts the watcher if it is still resident: it prints `runs COORD_MODE=resident but the resolved mode is split; restarting it.`)

### Rolling back

1. `sed -i '/^COORD_MODE=/d' <project>/.swarm/.env` (unset means resident)
2. `tmux kill-window -t llm-<project>:coordinator`
3. `cd <project> && <sandbox>/llm-start.sh` (works from the `util` pane too: it ignores a `COORD_MODE` that the pane merely inherited from the session, says so, clears the session's value, and restarts a split watcher as resident)

With `WATCH=0` the script leaves a running watcher alone but prints a `WARN:` with the exact `tmux kill-pane ...` command if its mode is wrong; run it, then `WATCH=1 <sandbox>/llm-start.sh`. If `llm-start.sh` cannot stop a stale watcher it exits 1 and prints that command too.

To force a mode on purpose, pass `COORD_MODE=<mode>` to the run and make it differ from the session's value, or clear the session's first: `tmux set-environment -t llm-<project> -u COORD_MODE`.

After step 3 the session env, the coordinator and the watcher all follow `.swarm/.env`. What `llm-start.sh` cannot see keeps its old mode: a shell with `COORD_MODE` exported by hand, and a watcher started by hand outside the `util` window. Restart those yourself.

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
