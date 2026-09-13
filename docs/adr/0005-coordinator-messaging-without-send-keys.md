# ADR 0005 — Coordinator wake & messaging without tmux `send-keys`

- **Status:** Proposed — spikes S1/S2/S4/S5 run live from inside a real
  worker sandbox during this ADR's authoring (2026-09-11); S2's cross-session
  case and S3 rest on the tool's documented contract rather than a live
  two-session trial (see "Spike results" for why, and what's left before
  Option 1 ships). Becomes Accepted once the residual S2/S3 trial (see
  "Residual spike work") is run.
- **Date:** 2026-09-11.
- **Deciders:** llm-swarm-runner maintainers.
- **Issue:** [#367](https://github.com/seanoc5/llm-swarm-runner/issues/367)
- **Related:** [#366](https://github.com/seanoc5/llm-swarm-runner/issues/366)
  (tactical stall-heartbeat + composer-guard fix — disposition below),
  [`docs/tmux-as-channel.md`](../tmux-as-channel.md) (the standing file-bus-
  over-send-keys argument this ADR extends to the watcher's own injections),
  [ADR 0002](./0002-worker-communication-baseline.md) (worker outbox/status
  file-bus conventions, unchanged by this ADR).

## Context

The coordinator's terminal is currently its only input port. A human types
into its composer to drive it (`tmux send-keys` from *outside* the agent
loop — the blessed, sanctioned use), and the project's own automation reuses
that exact same keystroke-injection mechanism to wake the coordinator from
*inside* the agent loop: `llm-start.sh` pastes a re-prompt into the
coordinator's REPL on session reuse, and `coordinator-watch.sh` injects
`/compact` and wake prompts into idle panes on a timer. Both are careful,
tested, idle-gated (`coordinator_pane_busy()` / `worker_pane_busy()` regex
matches against a busy-indicator catalog) — but they are keystrokes landing
in a text box that a human might also be typing into at that exact moment,
and the box cannot tell the difference. Every incident on file is a variant
of that one ambiguity:

- **#313** — a follow-up brief's `/quit` injection raced a worker's own
  composer state.
- **#290/#292** — `/compact` injection left ghost text or replayed itself
  because the composer's autocomplete/history ate or duplicated keystrokes.
- **#296** — a stale watcher daemon fired a spurious `/compact` at 16%
  context, indistinguishable from a legitimate one without a self-check.
- **#366 part B** (the direct trigger for this ADR) — an operator was
  mid-type in the coordinator's composer when a watcher wake fired; the
  reprompt path's busy-gate only checks for *tool activity*, not *human
  drafting*, so the wake's text got appended into the operator's draft.

`docs/tmux-as-channel.md` already documents the fix for *outbound* tmux
misuse (coordinator/worker `send-keys` into each other's panes: forbidden,
use the file bus) and the fix for *worker-initiated* messaging (the
`outbox/` + watcher-doorbell pattern, issue #129). What it does not yet
answer is #366's own open design question: **should the coordinator's wake
delivery itself stop being a keystroke-injection problem, given that a
harness-native alternative might now exist that never touches a composer at
all?**

The quantified cost of the current approach, read directly from the
scripts this ADR is evaluating replacing: `coordinator-watch.sh` (5,053
lines) contains 16 `send-keys` call sites and `llm-start.sh` contains 8,
the bulk of which exist purely to make keystroke injection *safe* —
busy-pattern gates, post-injection confirmation, stale-daemon self-checks,
composer-clear pre-checks. None of that machinery would need to exist for a
channel that structurally cannot collide with human input in the first
place.

## What was actually tested (spike summary)

Every finding below is either something this session directly observed
running inside a real worker sandbox for issue #367, or an explicit citation
to a tool's own documented contract — never an assumption presented as
verified. See "Spike results" for the full evidence per S1–S5.

| # | Question | Result |
|---|---|---|
| S1 | Can a worker container reach `ListAgents`/`SendMessage`? | **Confirmed, live.** Worked from inside a real `sandbox.sh` Docker container for this exact issue. |
| S2 | Queueing semantics (busy target, idle target)? | **Partially verified.** Subagent-resume path (synchronous) directly observed; cross-session path (async enqueue) taken from the tool's own contract, not live-tested against a real second session — see residual work. |
| S3 | Durability / crash recovery vs. send-keys? | **Analysis only.** No live crash injection performed; reasoned from the unchanged file-bus-as-store-of-record constraint. |
| S4 | Does `Monitor`/`ScheduleWakeup` fit the stall-heartbeat/doorbell role? | **`Monitor`: confirmed, live, working demo. `ScheduleWakeup`: corrected** — it is not a freestanding heartbeat primitive; it is `/loop` dynamic-mode's resume mechanism specifically. |
| S5 | Availability across CLI versions/agent classes? | **Confirmed gap.** These are Claude-Code-only harness features; gemini/codex worker classes have no equivalent, ever. |

## Decision

Adopt a **staged path through the option ladder**, not a single jump to the
greenfield end:

1. **Ship Option 1 (messaging doorbell) for Claude-Code coordinators**,
   replacing `llm-start.sh`'s reprompt-paste and `coordinator-watch.sh`'s
   wake-side `send-keys` (not the `/compact`-injection or worker-brief-
   delivery flows — see disposition table). The finishing worker itself (or
   a minimal headless courier the watcher spawns, for non-agentic trigger
   points like a raw `inotifywait` hit) calls `SendMessage` to the
   coordinator's session. The file bus stays exactly as it is — inbox/
   outbox/done/status are unchanged; the doorbell just stops being a
   keystroke.
2. **Treat Option 2 (self-watching coordinator) as the next rung, gated on
   a restructuring spike**, not an incremental addition to today's
   coordinator. S4 found that `ScheduleWakeup` is `/loop` dynamic mode's own
   resume mechanism, not a tool a long-lived interactive coordinator calls
   mid-session. Getting Option 2's stall-heartbeat property means running
   the coordinator *under* `/loop` (each firing re-enters via a saved
   prompt) rather than bolting a timer onto the existing single continuous
   turn. That is a real behavioral change to how the coordinator is
   launched and needs its own spike (does `/loop` re-entry compose with a
   human interrupting it interactively mid-loop, across `--resume`?) before
   a decision, not an assumption.
3. **Keep Option 3 (headless-resume courier) as the documented fallback**
   for whichever gap Option 1 doesn't cover cleanly (e.g., a wake source
   that isn't itself an agent turn, or a coordinator CLI version where
   `SendMessage` isn't available) — not a rung to build proactively.
4. **Option 4 (SDK-daemon coordinator) is out of scope for this decision.**
   Nothing in S1–S5 shows a gap that Options 1–2 don't already close; a
   full daemon rewrite is not justified by the evidence gathered here.

This keeps every current ladder rung independently shippable (this issue's
own constraint) and never proposes retiring the guarded `send-keys` path
entirely — S5 makes that a permanent requirement, not a transitional one,
for non-Claude agent classes.

## Spike results

### S1 — Container reach: CONFIRMED

This ADR was authored from inside the actual target environment: a worker
container provisioned by `sandbox.sh` for issue #367. Direct evidence
gathered from that container:

- `/.dockerenv` present; `/` is a Docker overlay filesystem
  (`overlay on / type overlay ... upperdir=/var/lib/docker/overlay2/...`).
- `/proc/self/mountinfo` shows `/home/sean/.claude` bind-mounted read-write
  to `/home/sandbox/.claude`, and a per-swarm credentials file mounted at
  `/home/sandbox/.claude.json` from
  `/home/sean/.claude-sandbox-configs/swarm-llm-llm-swarm-runner-iss-367.claude.json`
  — exactly the mechanism `docs/tmux-as-channel.md` §1d already documents
  for transcript access, now confirmed as the same mechanism that makes
  `ListAgents` work.
- From inside that container, `ListAgents` returned **512 peer sessions**,
  addressable by name, including titles that are plainly this exact repo's
  own issue history (`"Issue #405: coordinator-watch stale-daemon
  shutdown"`, `"Issue 382: coordinator draft-as-hold convention"`,
  `"Issue #307: Coordinator BLUF report grammar"`).
- `SendMessage` to a live target succeeded and returned a synchronous reply
  (tested against an in-process subagent — see S2 for why that's a
  different code path than the cross-session case this issue cares about).

**Mechanism, now verified rather than presumed:** discovery and delivery
ride the bind-mounted `~/.claude` session/credential state, not container
networking. The container still has no route to the host's tmux socket
(`docs/tmux-as-channel.md` §2a, unchanged) — and doesn't need one for this
channel.

**Caveat found, not anticipated by the issue:** the 512 peers are a global
list — this user's account across every machine, project, and time period
— with no built-in filter for "sessions in my swarm" or "the coordinator I
report to." Discovery is by human-assigned session title, which is an
artifact of history, not a stable, structured address. A production Option
1 implementation needs a naming or tagging convention (e.g., the
coordinator's session named deterministically from `swarm-<basename>`) so a
worker can address it without grepping 500+ unrelated rows.

### S2 — Queueing semantics: PARTIALLY VERIFIED

Two distinct delivery models were found under one tool surface, and this
matters directly for the design:

1. **Subagent-resume (verified live).** `SendMessage` to an in-process
   subagent this session had spawned via the `Agent` tool resolved
   **synchronously** — the tool result *was* the subagent's reply, delivered
   inline, no ack ambiguity, no composer involved at all.
2. **Cross-session (taken from the tool's own documented contract, not
   live-tested here).** `SendMessage`'s own description states messages to
   a genuinely separate top-level session "enqueue and drain at the
   receiver's next tool round," arrive wrapped as
   `<cross-session-message from="...">`, and a `notify_when_idle` callback
   exists for "tell me when it's done" without polling. This is the actual
   coordinator↔worker shape Option 1 needs, and it is a fundamentally
   different (async, queued) model from case 1.

**Why this stopped short of a live cross-session trial:** the only real
peer sessions reachable from this container's `ListAgents` were the
operator's own historical sessions on *unrelated* projects (JPA tuning,
dashboard defaults, and similar) — not disposable test fixtures. Sending a
spike payload into one would mean injecting test traffic into someone's real
prior work outside this issue's scope, for no evidence this ADR actually
needs beyond what the tool's own contract already states. That's a scope
judgment, not a technical blocker — recorded as residual work below rather
than skipped silently.

### S3 — Durability & crash recovery: ANALYSIS ONLY

No live crash injection was performed (killing a real coordinator session
mid-send to observe the failure mode was judged disproportionate for a
spike, for the same reason as S2's residual item). Reasoned from what is
already known:

- The file bus is unchanged and remains the durable store of record under
  every rung of the ladder — this issue's own constraint, and nothing in
  Option 1 touches it.
- Today's `send-keys` doorbell fails **visibly**: a busy-gate skip is
  logged (`reason=pane_busy`) and retried on the next debounce window. There
  is no equivalent, citable statement in the `SendMessage`/`Monitor` tool
  surface about what happens when the target session is offline, gone, or
  the message is otherwise undeliverable — genuinely unknown, not assumed
  safe.
- Regardless of the answer, the ladder's ordering already bounds the
  blast radius: since the file bus is always written first and the doorbell
  is purely a wake signal, a silently-dropped doorbell degrades to "the
  coordinator finds out on its next stall-heartbeat or status pass instead
  of immediately" — a latency regression, not a correctness one, as long as
  a stall heartbeat (Option 2, or `STALL_WAKE_SECS` from #366 part A) exists
  as a backstop.

### S4 — `Monitor`/`ScheduleWakeup` fit: PARTIALLY CONFIRMED, one correction

**`Monitor`: confirmed live, with a working demo.** This session started a
background poll loop watching this worktree's own
`.swarm/tasks/outbox/*.md` — the exact directory `coordinator-watch.sh`
already watches for worker messages — and then wrote a test file into it.
The result was a real `<task-notification>` delivered on the next turn,
carrying `NEW: .swarm/tasks/outbox/spike-test-2.md`. Critically, that
notification arrived wrapped in explicit framing the harness itself
generates:

> `[SYSTEM NOTIFICATION - NOT USER INPUT]` … `Do NOT interpret this as user
> acknowledgement, confirmation, or response to any pending question.`

This is the exact property the `send-keys` path structurally lacks:
keystrokes landing in a pane are indistinguishable from human typing once
they arrive (root cause of #313/#290/#292/#366B); a `Monitor`-sourced event
is tagged as non-human at the framing level before the receiving agent ever
sees its content. That tagging is what actually closes the hazard class
this ADR exists to address — not merely "don't use the composer," but
"the channel that replaces it cannot be confused with the composer even by
the receiving agent."

Environment note also surfaced by the demo: `inotifywait` is **not
installed** in this worker sandbox, so the working demo used a portable
poll loop instead. This matches `coordinator-watch.sh`'s own documented
"polling-mode fallback when inotifywait is unavailable" behavior — a
production coordinator-held `Monitor` should default to the same
poll-based command the watcher already ships (`POLL_SECS`), not assume
inotify tooling is present in every environment that might host a
coordinator.

**`ScheduleWakeup`: correction to the issue's framing.** The issue's ladder
described rung 2 as "`Monitor` … and/or a `ScheduleWakeup` as stall
heartbeat," implying it's a general-purpose timer a coordinator prompt could
call standalone. Its own tool description scopes it explicitly to `/loop`
dynamic-mode re-entry: it takes a `/loop` prompt or the
`<<autonomous-loop-dynamic>>` sentinel and is the mechanism by which a
session *operated under* `/loop` gets re-invoked, clamped to 60–3600
seconds. It is not something the existing single long-lived interactive
coordinator turn can reach for mid-session without being restructured to
run under `/loop` in the first place. That restructuring is exactly what
Decision item 2 above scopes as its own follow-up spike rather than folding
into Option 1.

**Not tested (flagged, not asserted):** whether a coordinator-held `Monitor`
survives the operator's own interactive turns interleaving, and what
happens to it across a `claude --resume` — both require a live multi-hour
coordinator session with concurrent human typing to observe honestly, out
of proportion for this spike.

### S5 — Availability gating: CONFIRMED GAP

- This session's CLI: `claude --version` → `2.1.259 (Claude Code)`.
  `ListAgents`/`SendMessage`/`Monitor`/`ScheduleWakeup` are gated as
  **deferred tools** requiring an explicit `ToolSearch` load even within a
  single Claude Code session — availability is negotiated per session, not
  a given.
- **The gap that matters for this project specifically:** `prompts/worker.md`
  already states, for a different guardrail, that "gemini/codex workers
  have no equivalent switch at all" (lines 76, 84 as read from this
  worktree) — and the same is true here, unconditionally.
  `ListAgents`/`SendMessage`/`Monitor`/`ScheduleWakeup` are Claude-Code-only
  harness features. A gemini or codex coordinator or worker has **no**
  equivalent primitive, now or foreseeably. This makes #366's framing of
  guarded `send-keys` as "the fallback path" understate its own durability:
  for any non-Claude agent class in this project, guarded `send-keys` is
  not a fallback pending migration — it is the **permanent** channel. No
  rung of this ladder ever fully retires it project-wide.

## Disposition of current `send-keys` flows

| Flow | Disposition |
|---|---|
| **Coordinator wake** (`llm-start.sh` session-reuse reprompt; `coordinator-watch.sh` outcome/outbox wake) | **Migrate** to Option 1 (`SendMessage` doorbell) for Claude-Code coordinators. `#366` part B's composer-guard ships regardless and becomes the **keep-with-guards** fallback for non-Claude coordinators and for any window before Option 1 lands. |
| **Worker brief delivery** (`inbox/` → idle worker; `/quit` injection, issue #313) | **Keep-with-guards.** Unchanged by this ADR: S1 showed a worker can reach *out* via `SendMessage`, not that the coordinator can push *in* without symmetric wiring the sandbox doesn't currently provide, and worker classes include non-Claude agents (S5) with no alternative primitive at all. Retiring this needs a worker-addressable messaging primitive that does not exist yet — explicitly out of scope here. |
| **Auto-compact injection** (coordinator + worker panes, `AUTO_COMPACT`/`WORKER_AUTO_COMPACT`) | **Keep-with-guards, orthogonal to this ADR.** This is proactive context management, not an inter-agent communication channel — nothing on the option ladder replaces it. Counted only as evidence of the current approach's accumulated guard complexity (see Context's send-keys-site count). |
| **Cross-swarm coordinator→coordinator** (`docs/tmux-as-channel.md` §4b, "not wired up") | **Not addressed by this ADR.** S1's `ListAgents` result shows the underlying primitive *could* reach across swarms (peers are addressed by account, not by swarm-local socket) — but scoping that safely (discovery, authorization, the same collision problem S1 flagged) is a separate design question, not implied by anything decided here. |

## Rationale

- **The hazard this ADR exists to remove is specific: a channel where an
  agent-originated event and human-typed text are indistinguishable once
  they land.** S4's live demo shows `Monitor` notifications are tagged
  non-human by the harness itself, structurally — not by a busy-pattern
  heuristic that can misfire (the actual defect class behind #290/#292/#296).
  That is a categorically stronger guarantee than any amount of additional
  `send-keys` gating could provide, which is why Option 1 is worth adopting
  even though it doesn't touch the file bus at all.
- **Staging beats a single jump** because the evidence gathered is uneven
  in confidence: S1 and S4's `Monitor` half are live-verified; S2's
  cross-session case, S3, and S4's `ScheduleWakeup`/interleaving questions
  are analysis or documentation-sourced. Committing to Option 2 or beyond on
  that evidence would be asserting more than was verified — exactly what
  this issue's acceptance criteria warn against.
- **Guarded `send-keys` cannot be scheduled for full retirement** because
  S5 is not a temporary gap — it's a structural one (non-Claude agent
  classes). Any disposition claiming "retire" project-wide would be false;
  "keep-with-guards" for those flows is the honest answer, not a
  concession.

## Alternatives considered

- **Jump straight to Option 4 (SDK-daemon coordinator).** Rejected for now:
  nothing in S1–S5 identifies a gap Options 1–2 don't close, and a full
  daemon rewrite discards the working file-bus/worktree/cap model for no
  demonstrated benefit — pure speculative rebuild.
- **Skip the ladder, ship Option 2 immediately.** Rejected: S4 found
  `ScheduleWakeup` is coupled to `/loop` dynamic mode, meaning Option 2
  requires restructuring how the coordinator is launched, not just adding a
  tool call. Shipping that without its own spike would be committing to an
  operating-model change on the strength of a corrected assumption, not
  verified behavior.
- **Declare guarded `send-keys` fully deprecated once Option 1 ships.**
  Rejected: S5 shows this is false for non-Claude agent classes. Documenting
  it as permanently keep-with-guards for those flows is more honest than a
  deprecation timeline this project can't actually meet.

## Residual spike work (before Option 1 implementation)

1. **Live two-session cross-session trial** (S2/S3 gap): spin up a
   disposable second `claude` session on the coordinator's host, confirm a
   worker container's `ListAgents` surfaces it distinctly from the 500+
   unrelated historical rows, `SendMessage` it a wake payload, and observe
   (a) delivery order under a busy target, (b) behavior when the target is
   deliberately ended mid-send. This is the trial S2/S3 stopped short of to
   avoid disturbing real unrelated sessions.
2. **Coordinator session naming/tagging convention** (S1 gap): define how a
   worker addresses "the coordinator of my own swarm" without grepping a
   global, human-titled list — likely a deterministic session name derived
   from `swarm-<basename>`, set at coordinator launch.
3. **`/loop`-restructuring spike** (Decision item 2, S4 gap): before
   committing to Option 2, confirm `ScheduleWakeup`/`/loop` dynamic-mode
   re-entry composes with an operator interactively driving the same
   coordinator lineage mid-loop, and survives `--resume`.

## Out of scope

- Implementing any option on the ladder (this ADR is design + spikes only,
  per issue #367's own scope fence).
- Worker sandbox/network policy changes beyond what S1 measured.
- Replacing GitHub as the cross-swarm channel.
- A worker-addressable inbound messaging primitive (would be required to
  retire worker-brief-delivery `send-keys`; not designed here).
