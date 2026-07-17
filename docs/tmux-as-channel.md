# Tmux as an Agent Communication Channel

This doc consolidates a question that comes up periodically: *can tmux itself be the channel agents use to talk to each other?* The substrate makes some of this trivially possible, some of it deliberately blocked, and some of it possible-but-discouraged. Material on this topic was previously scattered across [`architecture.md`](./architecture.md), [`llm-swarm-runner-overview.md`](./llm-swarm-runner-overview.md) ("Tmux as substrate"), [`security.md`](./security.md) ("Tmux Scrollback Exposure"), and [`adr/0003-capabilities-yaml.md`](./adr/0003-capabilities-yaml.md). Read this for the consolidated picture.

> **TL;DR:** The canonical inter-agent channel is the file-based bus under `.swarm/tasks/` (inbox / claimed / done JSON). Tmux is the *substrate* every agent runs on, and the host-side coordinator has enough access to use it as a **read-only** side-channel for diagnosing workers — and the project does this for stuck-worker detection. **`tmux send-keys` from one agent into another agent's pane is duct tape**, not a channel: no schema, no ack, no idempotency, and it races with whatever the receiver is doing. Use the file bus to ask agents to do things. The only blessed `send-keys` flow is a *human operator* nudging the coordinator from a control terminal. Workers cannot use tmux to talk to anyone, by design. Cross-swarm tmux messaging is not wired up and requires opting out of the sandbox if you want it.

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

…on any worker window. `scripts/check-stuck-workers.sh:167` already does this to classify workers as `IDLE-PARKED`, `ACTIVE`, `DEAD-PANE`, or `ORPHANED-CONTAINER`. The default `prompts/coordinator.md` *doesn't* tell the LLM to do this — it polls `.swarm/tasks/done/<id>.json` outcome files instead — but the LLM has the permissions and the substrate, so a custom coordinator prompt could `capture-pane` to diagnose a stuck worker and surface findings to the operator. `remain-on-exit failed` (in `examples/tmux.conf.example`) keeps `[dead]` panes' scrollback readable for forensic reads after the agent process exits.

**`capture-pane` good; `send-keys` from the coordinator into a worker bad.** Reading scrollback is observation. Injecting keystrokes into a running worker REPL is a race against whatever tool call the worker is currently in — see §4c for why this is a footgun even though the permissions allow it. If a worker needs a recovery hint, write it to that worker's `.swarm/tasks/inbox/`; the listener will deliver it cleanly between tasks.

### b. Operator drives coordinator from outside (the *only* blessed `send-keys` flow)
From any host shell:

```bash
tmux -L swarm-<basename> send-keys -t llm-<basename>:coordinator "<your prompt>" Enter
```

This is documented in [`tmux-cheatsheet.md`](./tmux-cheatsheet.md) as the "control terminal" pattern. It's a **human → coordinator** channel — the human is the only actor outside the agent loop who has enough situational awareness to know whether the coordinator is at a prompt or mid-tool-call, and to retry if their keystrokes get eaten. Any other use of `send-keys` (agent → agent, script → agent that's running an LLM) lacks that situational awareness and is duct tape — see §4c.

---

## 2. What's blocked by design

### a. Worker → any tmux socket
Worker containers (`sandbox.sh`) **do not bind-mount the host tmux socket**. The container has no path to `/tmp/tmux-$UID/swarm-*` at all, so workers cannot `capture-pane`, `send-keys`, `attach`, or even `tmux ls` against the swarm. This is the asymmetric-visibility property called out in [`overview.md` §"Tmux as substrate"](./llm-swarm-runner-overview.md#tmux-as-substrate-not-just-a-ui) and [`security.md` §"Tmux Scrollback Exposure"](./security.md#tmux-scrollback-exposure).

What workers *can* reach is `/var/run/docker.sock` (DooD), so cross-container observation is possible via `docker exec` / `docker logs` — that's a separate, larger blast-radius concern, not a tmux channel.

### b. Cross-swarm anything via tmux
Each swarm gets its own per-repo socket (`swarm-<basename>`). Different basenames → different sockets → different tmux servers. There is no wiring (no mount, no shared socket dir, no naming convention) that lets a coordinator or worker in swarm A reach the tmux server of swarm B. If you remember a worker sending a message to a coordinator in another swarm, it almost certainly happened via:

- you, the human, relaying it; or
- `gh` / git (issues, PR comments, commits) — the actual cross-swarm bus; or
- `docker exec` from a worker into another container.

Not via tmux.

---

## 3. Pros and cons vs the file-based bus

The canonical channel is `.swarm/tasks/{inbox,claimed,done}/<id>.json` written via atomic `mktemp + mv`, claimed by `worker-listener.sh`, with structured outcome JSON. Tmux-as-channel is a tempting alternative because the substrate is already there — but the project has explicitly chosen against it for verification outcomes ([ADR-0003](./adr/0003-capabilities-yaml.md)). The trade-off:

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

### c. Coordinator → worker `send-keys` (**strongly discouraged** — works at the substrate level, footgun at the agent level)
The permissions allow it. The substrate doesn't stop you. The default `prompts/coordinator.md` deliberately doesn't teach it, and you shouldn't add it. Why:

- **No idle detection.** When the coordinator decides to "nudge a stuck worker", the worker is almost never actually idle at a clean prompt — most stuck-looking workers are mid-tool-call, mid-permission-prompt, or mid-LLM-stream. Keystrokes injected into any of those states corrupt the in-flight operation in ways that are hard to detect and harder to recover from. The coordinator has no reliable way to know the worker's REPL state from the outside.
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
| Coordinator `send-keys` to worker           | **Discouraged** | Permitted by substrate; treat as footgun, use file bus instead (§4c) |
| Operator `send-keys` to coordinator         | Yes        | `tmux-cheatsheet.md`                                      |
| Worker reads/writes any tmux                | **Blocked** | `sandbox.sh` (no socket mount); `security.md`             |
| Cross-swarm tmux (coordinator → coordinator)| Not wired  | Possible with shared socket dir; see §4b                  |
| Cross-swarm via files / `gh`                | Yes        | Use this instead of §4b                                   |

When in doubt, use the file bus or `gh`. Reach for tmux only when the agent fundamentally needs to read a terminal or inject a keystroke into one — that's what tmux is good at, and not what files are good at.
