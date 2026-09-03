# Tmux as an Agent Communication Channel

This doc consolidates a question that comes up periodically: *can tmux itself be the channel agents use to talk to each other?* The substrate makes some of this trivially possible, some of it deliberately blocked, and some of it possible-but-discouraged. Material on this topic was previously scattered across [`architecture.md`](./architecture.md), [`llm-swarm-runner-overview.md`](./llm-swarm-runner-overview.md) ("Tmux as substrate"), [`security.md`](./security.md) ("Tmux Scrollback Exposure"), and [`adr/0003-capabilities-yaml.md`](./adr/0003-capabilities-yaml.md). Read this for the consolidated picture.

> **TL;DR:** The canonical inter-agent channel is the file-based bus under `.swarm/tasks/{inbox,processing,done,status,outbox}/` (briefs are `<id>.md`; structured outcome JSON lands in `done/` as `<id>.{ok,err}.json`; workers declare state in `status/` and message the coordinator mid-task via `outbox/` — `coordinator-watch.sh` wakes the coordinator when a message lands, issue #129). Tmux is the *substrate* every agent runs on, and the host-side coordinator has enough access to use it as a **read-only** side-channel for diagnosing workers — the project does this for stuck-worker detection (`scripts/check-stuck-workers.sh`), and the default `prompts/coordinator.md` now explicitly blesses read-only `capture-pane` as a diagnostic fallback. **`tmux send-keys` from one agent into another agent's pane is duct tape**, not a channel: no schema, no ack, no idempotency, and it races with whatever the receiver is doing — that principle still holds for LLM-agent-driven `send-keys`, which stays forbidden. What's changed is that the project now also ships **host-side scripted `send-keys`**, gated by heuristic busy-pattern detection rather than agent judgment: `llm-start.sh` pastes a re-prompt into the coordinator REPL on session reuse, `coordinator-watch.sh` injects `/compact` into the coordinator pane and every idle `iss-*` worker pane (`WORKER_AUTO_COMPACT`, default on, issue #226), and `coordinator-watch.sh` ends a parked-at-rest interactive worker session with `/quit` when a `requeue.sh` follow-up brief is waiting in its `inbox/` (`WORKER_AUTO_DELIVER`, default on, issue #313). These are supported, idle-gated infrastructure flows — not a license for agents to reach for `send-keys` themselves. Use the file bus to ask agents to do things. Workers cannot use tmux to talk to anyone, by design. Cross-swarm tmux messaging is not wired up and requires opting out of the sandbox if you want it.

### Guiding principle

**Read via tmux is fine. Write via tmux is duct tape.**

- `capture-pane` (read scrollback) is appropriate for observability — health classification, post-mortem debugging, surfacing context to the operator. The project uses it this way in `scripts/check-stuck-workers.sh`.
- `send-keys` (write keystrokes) is appropriate from a *human* into the coordinator. Anything else — coordinator → worker, worker → coordinator, agent → agent across swarms — is a footgun: it races with the receiver's current tool call, has no acknowledgement, and silently corrupts state when keystrokes land in the wrong buffer. **Don't add `send-keys`-based "channels" to prompts or scripts.** If you need to ask another agent to do something, write it to the file bus or `gh issue comment`.

---

## 1. What the substrate enables today (works out of the box)

### a. Coordinator reads worker panes
The coordinator runs **host-native** and has unrestricted access to the per-repo tmux socket at `/tmp/tmux-$UID/swarm-<basename-of-cwd>` (see `llm-start.sh:47` — `SWARM_SOCKET="swarm-$(basename "$PWD")"`). It can:

```bash
tmux -L swarm-<basename> capture-pane -t llm-<basename>:iss-42 -p -S -50000
```

…on any worker window. `scripts/check-stuck-workers.sh:170` already does this, classifying each worker into one of eight states: healthy (`IDLE-PARKED`, `ACTIVE`, `EXITED-IDLE`), advisory (`CONTEXT-LARGE`), or needs-attention/broken (`EXIT-CONFIRM-PENDING`, `UNKNOWN`, `DEAD-PANE`, `ORPHANED-CONTAINER`) — see the pattern catalog at `check-stuck-workers.sh:19-29`. The default `prompts/coordinator.md` prefers structured `.swarm/tasks/done/<id>.json` outcomes for routine polling, but its "Never `tmux send-keys`" section (`coordinator.md:99`) explicitly blesses read-only `capture-pane` as a diagnostic fallback, and its status-update procedure (`coordinator.md:117`, step 4) instructs checking pane scrollback when a window closed with no PR. `remain-on-exit failed` (set automatically by `llm-start.sh` on the swarm socket; also mirrored in `examples/tmux.conf.example` for manual sessions) keeps `[dead]` panes' scrollback readable for forensic reads after the agent process exits.

**`capture-pane` good; `send-keys` from the coordinator into a worker bad.** Reading scrollback is observation. Injecting keystrokes into a running worker REPL is a race against whatever tool call the worker is currently in — see §4c for why this is a footgun even though the permissions allow it. If a worker needs a recovery hint, write it to that worker's `.swarm/tasks/inbox/`; the listener will deliver it cleanly between tasks.

### b. Operator drives coordinator from outside (the blessed *human* `send-keys` flow)
From any host shell:

```bash
tmux -L swarm-<basename> send-keys -t llm-<basename>:coordinator "<your prompt>" Enter
```

This is documented in [`tmux-cheatsheet.md`](./tmux-cheatsheet.md) as the "control terminal" pattern. It's a **human → coordinator** channel — the human is the only actor outside the agent loop who has enough situational awareness to know whether the coordinator is at a prompt or mid-tool-call, and to retry if their keystrokes get eaten. Any *agent-driven* use of `send-keys` (agent → agent, script → agent that's running an LLM on the model's own initiative) lacks that situational awareness and is duct tape — see §4c.

### c. Host-side scripted `send-keys` (engineered, idle-gated — not agent-driven)

A third tier sits between (a) read-only observation and (b) human-driven writes: **host scripts** that inject keystrokes on a timer, gated by heuristic busy-pattern detection instead of an agent's own judgment call.

- **`llm-start.sh`** pastes a re-prompt into the *running* coordinator REPL via `load-buffer` + `paste-buffer` + `send-keys Enter` when it detects an idle coordinator pane on session reuse (see "Session reuse: detect-dead-coordinator" in `docs/llm-swarm-runner-overview.md`).
- **`coordinator-watch.sh`** injects a real `/compact` into the coordinator pane when `AUTO_COMPACT=1` (default) and the pane is over its token threshold, and does the same into every idle `iss-*` worker pane when `WORKER_AUTO_COMPACT=1` (default, issue #226) — followed by a short "continue your task" nudge once compaction finishes.
- **`coordinator-watch.sh`** also injects `/quit` into an idle `iss-*` worker pane when `WORKER_AUTO_DELIVER=1` (default, issue #313) and that worker has a follow-up brief genuinely waiting in its own `inbox/` — see just below for why this exists and what it does and doesn't send.

Both are gated by `coordinator_pane_busy()` / `worker_pane_busy()` — a `capture-pane` regex match against a busy-indicator pattern (spinner glyphs, `Considering…`, etc., the same catalog `check-stuck-workers.sh` uses) — and skip the injection with `reason=pane_busy` when the pane is mid-turn rather than idle. This is why it's safe as *engineered infrastructure* in a way an agent improvising the same move wouldn't be: the gating is deterministic and tested (`test-watcher-autoclose.sh` and friends), not a judgment call made fresh each time. It does not license agents to reach for `send-keys` on their own — §4c's argument against agent-initiated `send-keys` is unchanged.

**A third scripted flow (issue #313): ending a parked-at-rest interactive worker session.** `worker-listener.sh`'s interactive mode dispatches the agent as a *foreground* process — the listener's own `claim_next_task` poll loop is blocked on it and only regains control once the agent exits (`/quit` for claude). A worker that finishes its task but never runs `/quit` (the documented but manual hand-off step) is parked *inside* that still-running session: invisible to its own listener, and to anything the coordinator drops in its `inbox/` via `requeue.sh` — the incident this fixes (fand-etl swarm, 2026-08-26) left two follow-up briefs unclaimed for 2.5+ hours until a human intervened. `coordinator-watch.sh`'s `WORKER_AUTO_DELIVER` (default on) closes that gap the same idle-gated way as `/compact` injection: on its regular sweep, for any `iss-*` window that is a live agent session (not the listener's own idle bash shell — that case already self-heals, issue #43), genuinely idle (`worker_pane_busy()` false), has a real brief waiting in `inbox/`, and has nothing unsubmitted sitting in its composer (`compact_composer_clear` — guards exactly the dimmed-suggestion case observed on a parked pane during this issue's investigation), it pastes `/quit` + Enter and waits for the pane to leave the live-agent state. It does **not** paste the brief's own text — `requeue.sh` already wrote that atomically to `inbox/`; ending the session is the only step a human was doing by hand. Once the agent exits, `worker-listener.sh`'s existing claim/dispatch/outcome path runs unchanged, so `done/*.json` and `status/*.json` keep working for this class of task exactly as they do for every other follow-up. See `coordinator-watch.sh`'s `WORKER_AUTO_DELIVER` header comment for the full mechanism, backoff, and the (fail-safe, non-claude-agent) limitation of assuming `/quit` is the right exit command.

### d. Pane content is not verified truth — UI chrome is not conversation

`capture-pane -p` (plain, the flag used everywhere in this doc and in `check-stuck-workers.sh`) strips color/attribute info along with the ANSI it drops. That's normally harmless — but Claude Code's TUI renders several kinds of chrome that only a *human eye with color* can distinguish from something someone actually typed and submitted:

- **The composer's suggested-next-prompt autofill.** Claude Code sometimes prefills the empty input box with a dimmed suggestion (e.g. `❯ Loop in Radesh and John on this PR for review`). In a plain-text capture, dim and normal text render identically — the suggestion looks exactly like typed, submitted input.
- **`※ recap:` lines** — Claude Code's own recap/summary chrome, not something either party wrote as a turn.
- **Spinner/status lines** — `✻`/`✶` glyphs, `Considering…`, `Sautéed for Ns`, `Cooked for Ns`, `Baked for Ns`, `Simmered for Ns`, `Brewed for Ns`, `Crunched for Ns` (the same catalog `check-stuck-workers.sh`'s `detect_state` matches on) — transient progress chrome, not conversation.
- **Session-resume dialogs** — `❯ 1. Resume from summary…`, `Resume this session with…` — a picker UI, not a submitted message.

**The incident this section exists for** (oconeco-site swarm, 2026-08-01): a coordinator read a worker pane, saw a dimmed composer suggestion sitting below the last response, and reported it to the operator as "you've asked that worker to…" — attributing UI chrome to the human. The report was wrong; the operator had typed nothing of the sort.

**The rule:** never attribute text to the operator (or to an agent "saying" something) on the strength of a plain-text pane capture alone. Composer-region text in particular — anything sitting below the last rendered response, above wherever the prompt currently sits — is *never* confirmed input until it appears as a submitted turn in the actual session transcript.

**The verification recipe** (what actually disproved the incident above, in order of cheapness):

1. **Location.** Does the suspect line live *only* inside the composer box below the last response, or does it appear as a submitted `>` turn earlier in scrollback? Composer-only placement is a strong tell by itself.
2. **Transcript grep — the load-bearing check.** Every Claude Code session writes its turns to a JSONL transcript under `~/.claude/projects/<slug>/`, where `<slug>` is the worktree's absolute path with every `/` replaced by `-` (e.g. `/opt/work/wt-issue-219` → `-opt-work-wt-issue-219`). Because `sandbox.sh` bind-mounts `$HOME/.claude` into every worker container (`sandbox.sh:40`), the host coordinator's own `~/.claude/projects/` tree already contains every worker's transcripts — no container exec needed. Grep it:
   ```bash
   grep -l 'Loop in Radesh' ~/.claude/projects/-opt-work-wt-issue-219/*.jsonl
   ```
   No hit in any session transcript for that worktree means the text was never actually submitted — full stop. Transcripts are ground truth for what was actually sent; the rendered pane is not. `scripts/capture-worker.sh <window> --verify "<text>"` (see below) automates this step — it derives the worktree path for you via `swarm_worktree_dir`, greps, and exits 0/1 on found/not-found.
3. **Does it persist or change on its own?** Typed-but-unsubmitted text sticks around until the user acts on it. A suggestion can vanish on its own (e.g. the pane idles into a session-resume dialog and the suggestion is gone) — something a human never did. Self-changing content without operator action is corroborating evidence it was chrome, not input.

**Use `scripts/capture-worker.sh` instead of raw `capture-pane`** when the question is "did the operator/worker really say X": it tags every line matching the chrome catalog above as `[UI-CHROME]` inline, and its `--verify TEXT` mode runs check 2 for you:

```bash
scripts/capture-worker.sh iss-42                          # tagged dump, last 200 lines
scripts/capture-worker.sh iss-42 --verify "Loop in Radesh"  # FOUND / NOT FOUND against the transcript
```

Raw `capture-pane` is still fine for structural checks that don't hinge on attributing text to a person — `check-stuck-workers.sh`'s state classification (spinner present? dead pane?) never claims a human said anything, so it doesn't need this treatment.

---

## 2. What's blocked by design

### a. Worker → any tmux socket
Worker containers (`sandbox.sh`) **do not bind-mount the host tmux socket**. The container has no path to `/tmp/tmux-$UID/swarm-*` at all, so workers cannot `capture-pane`, `send-keys`, `attach`, or even `tmux ls` against the swarm. This is the asymmetric-visibility property called out in [`overview.md` §"Tmux as substrate"](./llm-swarm-runner-overview.md#tmux-as-substrate-not-just-a-ui) and [`security.md` §"Tmux Scrollback Exposure"](./security.md#tmux-scrollback-exposure). Blocking the *tmux* path doesn't leave workers mute, though — a worker that needs the coordinator's attention mid-task writes a message file to its own `.swarm/tasks/outbox/` and the watcher rings the doorbell (issue #129; see "Worker outbox" in `prompts/worker.md`).

What workers *can* reach is `/var/run/docker.sock` (DooD), so cross-container observation is possible via `docker exec` / `docker logs` — that's a separate, larger blast-radius concern, not a tmux channel.

### b. Cross-swarm anything via tmux
Each swarm gets its own per-repo socket (`swarm-<basename>`). Different basenames → different sockets → different tmux servers. There is no wiring (no mount, no shared socket dir, no naming convention) that lets a coordinator or worker in swarm A reach the tmux server of swarm B. If you remember a worker sending a message to a coordinator in another swarm, it almost certainly happened via:

- you, the human, relaying it; or
- `gh` / git (issues, PR comments, commits) — the actual cross-swarm bus; or
- `docker exec` from a worker into another container.

Not via tmux.

---

## 3. Pros and cons vs the file-based bus

The canonical channel is `.swarm/tasks/{inbox,processing,done,status,outbox}/` — task briefs (`<id>.md`) written to `inbox/` via atomic `mktemp + mv`, atomically claimed by `worker-listener.sh` (moved to `processing/`), structured outcome JSON (`<id>.{ok,err}.json`) written to `done/`, worker state declared in `status/`, and worker→coordinator messages (fyi / decision-needed / brief-draft) dropped in `outbox/` where `coordinator-watch.sh` wakes the coordinator on arrival (issue #129). Tmux-as-channel is a tempting alternative because the substrate is already there — but the project has explicitly chosen against it for verification outcomes ([ADR-0003](./adr/0003-capabilities-yaml.md)). The trade-off:

**Pros of tmux as channel:**

- Zero new infrastructure — every agent is already in a pane.
- Human-readable; the same `capture-pane` flow that operators use for debugging is what the agent would use.
- Latent capability — no schema, no protocol version, no migration.
- Free post-mortem replay (50000-line scrollback, `remain-on-exit failed`).

**Cons of tmux as channel:**

- **Fragility (ADR-0003's argument):** parsing scrollback to determine "did the verify pass?" is prompt-sensitive, brittle, and silently wrong when the underlying tool changes its output. Replaced for that use case with listener-side execution + structured JSON.
- **No schema, no ack, no idempotency.** Two `send-keys` calls landing during a tool prompt can produce arbitrary state. The file-based bus has atomic mv, exclusive claim, and explicit outcome records.
- **Scrollback truncation** (default 50000 lines) and **wrap behaviour** at narrow widths can lose or mangle data. Files don't truncate.
- **Race conditions** with the agent's own typing — `send-keys` while the REPL is mid-response interleaves badly.
- **Single-host coupling** — tmux sockets are filesystem objects on one box. The file bus generalises to NFS, syncthing, or any path you can both reach.
- **Asymmetric by design** — only the coordinator can use it, so it can't be a worker-initiated channel without breaking the security model.

For most things, **use the file bus.** Tmux as a side-channel is appropriate for exactly two patterns:

1. **Operator-driven coordinator prompting** via `send-keys` — already supported (§1b); the human is the situational-awareness sensor that makes this safe.
2. **Coordinator-side worker observability** via `capture-pane` — already partially implemented in `check-stuck-workers.sh`; pure read, no writes back into the worker.

Notably absent from that list: any agent-driven `send-keys`. If you find yourself reaching for it, you have a file-bus message you haven't written yet.

---

## 4. Escape hatch: doing it anyway

Sometimes you want to ignore best practice — for an experiment, for a one-off cross-swarm coordination, or because you've judged the trade-off for your context. Here's how:

### a. Let workers read/write tmux (sandbox opt-out)
Bind-mount the swarm socket into the worker container by adding to `EXTRA_MOUNTS` when launching a worker:

```bash
EXTRA_MOUNTS="/tmp/tmux-$UID:/tmp/tmux-$UID:rw" \
  ./sandbox.sh <project-dir> claude
```

Then inside the worker: `tmux -L swarm-<basename> ls`. This gives the worker the same tmux access the host coordinator has, and **removes the asymmetric-visibility property documented in `security.md`** — every worker can now read every other worker's secrets-in-scrollback and `send-keys` arbitrary input to any pane including the coordinator. The container sandbox no longer constrains tmux blast radius. Only do this if you trust every agent in the swarm equally and have no secrets in any pane.

### b. Cross-swarm tmux messaging (**strongly discouraged** — read the §4c argument first; everything there applies double here)
Two swarms can reach each other's tmux only if they share a socket directory and you know each other's session names. Both are deterministic in this project:

- Sockets live at `/tmp/tmux-$UID/swarm-<basename-of-cwd>` (`llm-start.sh:47`).
- Sessions are `llm-<basename-of-cwd>` (`llm-start.sh`).
- Coordinator window is `coordinator`; worker windows are `iss-<N>`.

So a host-side script (or a coordinator that's been told the other swarm's basename) can do:

```bash
tmux -L swarm-<other-basename> send-keys \
    -t llm-<other-basename>:coordinator \
    "Heads up from the <this-basename> swarm: <message>" Enter
```

Caveats:

- This only works **host-native** — a worker can't do it unless you've also done (a) above for *both* swarms' sockets, which compounds the security cost.
- No ack, no delivery confirmation, no ordering. If the other coordinator is mid-tool-call, the keys land in its prompt buffer and may be eaten by the tool or executed at an unexpected moment.
- The receiving coordinator has no protocol for "incoming cross-swarm message" — it will interpret it as user input, which can derail its current task.
- Prefer the file-based bus shared across swarms (a shared `.swarm/inbox/` on disk or in a shared repo), or `gh issue comment` as the cross-swarm channel. Both have schemas, acks, and history.

### c. Coordinator → worker `send-keys` (**strongly discouraged for the agent** — works at the substrate level, footgun at the agent level)
The permissions allow it. The substrate doesn't stop you. The default `prompts/coordinator.md` deliberately doesn't teach the *LLM* to reach for this, and you shouldn't add it to a prompt. Why:

- **Idle detection is heuristic, not reliable enough for an agent's own judgment call.** `coordinator-watch.sh`'s `worker_pane_busy()` (§1c) classifies a worker pane via `capture-pane` against a busy-indicator pattern (spinner glyphs, `Considering…`, etc.) and skips its own scripted injection when the match says "busy". That's good enough for a narrow, tested, fail-open optimization like auto-compact — it is not good enough to make agent-initiated `send-keys` a reliable messaging channel. A coordinator LLM deciding in the moment whether to nudge a "stuck" worker has no comparable safety net: most stuck-looking workers are mid-tool-call, mid-permission-prompt, or mid-LLM-stream, and keystrokes injected into any of those states corrupt the in-flight operation in ways that are hard to detect and harder to recover from.
- **No ack, no retry semantics, no ordering.** If two nudges are sent in quick succession (e.g. the coordinator's polling fires twice), there's no way to know whether the first one was accepted, eaten by a tool, or buffered for later replay.
- **Silently bad on misroute.** Sending to the wrong window name (typo, killed worker, recycled window) does nothing visible — `send-keys` returns success either way.
- **Couples coordinator prompt to receiver agent UX.** The exact keystrokes that "wake up" a stuck worker depend on which CLI (claude/codex/gemini), which version, and which interactive mode. Prompts that hard-code these decay fast.
- **The file bus already solves it cleanly.** Drop a follow-up task into `<worktree>/.swarm/tasks/inbox/` (atomic mktemp+mv); the listener delivers it to the worker between tasks, with a guaranteed clean REPL state, structured payload, and a `done/*.json` ack. That's the supported "nudge a worker" path.

If your prompt or script is reaching for `tmux send-keys -t llm-...:iss-N`, replace it with a file-bus write to that worker's inbox. There is no scenario in which the `send-keys` version is the right call.

---

## 5. Summary table

| Channel                                     | Supported? | Where documented                                          |
|---------------------------------------------|------------|-----------------------------------------------------------|
| Coordinator reads worker scrollback         | Yes        | `overview.md` §Tmux as substrate; `check-stuck-workers.sh` |
| Coordinator attributes pane text to a person| **Verify first** | Plain capture can't tell UI chrome from typed input — check the session transcript before believing it (§1d, `scripts/capture-worker.sh --verify`) |
| Operator `send-keys` to coordinator         | Yes        | `tmux-cheatsheet.md`; §1b                                  |
| Host script `send-keys` (wake re-prompt, `/compact` injection, parked-session `/quit`) | Yes, idle-gated | `llm-start.sh`, `coordinator-watch.sh` (`AUTO_COMPACT`/`WORKER_AUTO_COMPACT`/`WORKER_AUTO_DELIVER`); §1c |
| Coordinator (LLM) `send-keys` to worker     | **Discouraged** | Permitted by substrate; treat as footgun, use file bus instead (§4c) |
| Worker reads/writes any tmux                | **Blocked** | `sandbox.sh` (no socket mount); `security.md`             |
| Worker → coordinator message (outbox + watcher wake) | Yes | `prompts/worker.md` §"Worker outbox"; `coordinator-watch.sh` `WATCH_OUTBOX` (issue #129) — the file-bus channel that makes worker tmux access unnecessary |
| Cross-swarm tmux (coordinator → coordinator)| Not wired  | Possible with shared socket dir; see §4b                  |
| Cross-swarm via files / `gh`                | Yes        | Use this instead of §4b                                   |

When in doubt, use the file bus or `gh`. Reach for tmux only when the agent fundamentally needs to read a terminal or inject a keystroke into one — that's what tmux is good at, and not what files are good at.
