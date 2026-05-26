# Level-5 Agentic Coding — Roadmap

A phased plan for hardening llm-swarm-runner so it can run *Level-5* agentic workflows: the operator describes high-level intent, the swarm autonomously researches, edits, tests, and opens verifiable PRs without per-step babysitting.

The premise (from external review, 2026-05): reaching Level 5 is mostly **not** about smarter models. It is about giving the swarm a stricter substrate — structured contracts, hermetic feedback loops, dependency-aware orchestration, and per-step blast-radius limits.

This file lists the phases in execution order. Each is a single PRD-worth of work; pick one off the top and ship it before reaching for the next.

## Sequence

```
A ──► D-β ──► B ──► D-γ ──► C ──► D-ε ──► D-δ ──► D-α
  \                \                                       ^
   \                └─ judge gates require A's verify signal
    \
     └─ capabilities schema is the spine D-α / D-δ both consume
```

## Phases

### Phase 1 — A: Structured capabilities

- **Lead artifact:** `<project>/.swarm/capabilities.yml` schema + listener enforcement.
- **Lead check:** shape test asserts no PR opens when verify fails.
- **Size:** ~1 day. Prompt + listener + shape test + docs.
- **Status:** PRD drafted — see [`docs/prd/0001-structured-capabilities.md`](./prd/0001-structured-capabilities.md). ADR drafted — see [`docs/adr/0003-capabilities-yaml.md`](./adr/0003-capabilities-yaml.md).

Unlocks B (judge has structured signal to gate on), D-α (cost telemetry plugs into the same outcome-JSON spine), D-δ (sandbox profile rides in the same file).

### Phase 2 — D-β: Coordinator reasoning log

- **Lead artifact:** `<project>/.swarm/coord-log/<utc>.md`, written at the end of every coordinator wake.
- **Mechanism:** `prompts/coordinator.md` gains a closing beat — *"before exiting, write a 5-line entry to `.swarm/coord-log/` summarising what you saw, what you decided, what you deferred and why."* The next wake reads the last three entries as part of its context.
- **Lead check:** a coordinator wake against a non-trivial backlog leaves exactly one new file; the subsequent wake's scrollback shows the previous entries were loaded.
- **Size:** half a day. Prompt change + a sub-200-line helper script + shape test.
- **Why this slot:** cheapest quality win in the list; the one-shot coordinator currently forgets *why* it picked the last N issues, and a tiny disk log fixes that without any LLM-side state.

### Phase 3 — B: Judge worker

- **Lead artifact:** `scripts/judge-worker.sh` + `prompts/judge.md`. New worker class invoked by the coordinator on 🟡 / 🔴 PRs.
- **Mechanism:** separate container, reads PR diff + `verify.log` + outcome JSON, writes `.swarm/tasks/done/<id>.judge.json` with `{verdict, reasons[], confidence}`. The coordinator's merge step gates on judge verdict; a dissenting judge overrides 🟢-low self-merge.
- **Lead check:** shape test stubs `gh pr diff`, asserts the judge is invoked exactly once per medium/high PR, verdict file is present, and the coordinator's triage reads it.
- **Size:** 2–3 days. Mostly prompt design and plumbing; reuses sandbox + listener.
- **Replaces:** the adversarial self-review introduced in #116. That pass was cheap but biased (author criticising own work); a separate context window is the right architecture.

### Phase 4 — D-γ: Replay fixtures

- **Lead artifact:** `tests/fixtures/runs/<scenario>/` directories containing recorded `inbox/*.md`, `done/*.json`, plus an `expects.yml` describing the expected coordinator action.
- **Mechanism:** `tests/test-replay.sh` feeds a fixture into a coordinator wake with mocked `gh` + `tmux` and asserts the coordinator's *next action* matches expectations.
- **Lead check:** three starting scenarios — happy path (all green ⇒ expects merge), verify-fail (expects park + comment), judge-dissent (expects park + escalate).
- **Size:** 3 days. The plumbing is small; the work is curating realistic fixtures.
- **Why this slot:** needed before C ships. C is where most prompt-regression risk concentrates, and we want a regression net under us before we touch the dependency-graph protocol.

### Phase 5 — C: Multi-worker dependency graph

- **Lead artifact:** `scripts/provision-graph.sh`, brief schema extension `depends_on: [task_id]`, listener support for "claim only when deps satisfied."
- **Mechanism:** the coordinator drops a `.swarm/graphs/<name>.yml` describing N tasks and their edges; the provisioner spawns N workers; each worker's listener blocks on its dependencies' `done/*.ok.json` files before claiming its own brief. A trailing "stitch" task with all leaves as deps opens the meta-PR consuming the leaf branches.
- **Lead check:** replay fixture from Phase 4 covering a 3-task chain (SQL → ETL → API) — asserts order, asserts the meta-PR opens after all leaves succeed, asserts partial-failure handling.
- **Size:** 1–2 weeks. Real protocol work: partial-failure recovery, dep-cycle detection, timeout semantics, stitch-task auth model.
- **Depends on:** A (verify signal in done JSON) + D-γ (regression coverage).

### Phase 6 — D-ε: Issue-quality gate

- **Lead artifact:** `prompts/triage-worker.md`. The coordinator runs it before `provision-worker.sh` on any issue lacking explicit acceptance criteria.
- **Mechanism:** the triage worker reads the issue body and the repo context, rewrites the issue (`gh issue edit`) with acceptance criteria, risk tags, and an estimated `capabilities.yml` impact, then the regular worker picks it up.
- **Lead check:** an issue containing only a one-line title gets rewritten with structured sections before any `iss-*` window spawns.
- **Size:** 1 week.
- **Order rationale:** lifts the success rate of every downstream phase; placed here because C made the cost of dispatching vague issues compound.

### Phase 7 — D-δ: Per-worker sandbox profile

- **Lead artifact:** `.swarm/capabilities.yml` gains a `sandbox_profile` enum; `sandbox.sh` honours `--profile {default,no-dood,no-net}`.
- **Mechanism:** the low-trust profile drops the `/var/run/docker.sock` mount and switches off `--network host` (bridge networking only). The coordinator selects a profile per issue (e.g., issues touching auth / secrets / CI get `no-dood`).
- **Lead check:** shape test asserts profile selection from a labelled issue propagates to the `docker run` argv.
- **Size:** 1 week. Design-heavy — needs an answer for "what breaks under no-net" (Testcontainers, package installs, etc.).

### Phase 8 — D-α: Cost + telemetry per outcome

- **Lead artifact:** outcome JSON gains `cost.{tokens_in, tokens_out, dollars_estimated, model, provider}`.
- **Mechanism:** claude-code and gemini-cli both emit cost telemetry; the listener parses and folds it into outcome JSON. The coordinator surfaces session totals on every wake.
- **Lead check:** shape test asserts a successful task produces a non-null cost block.
- **Size:** 3–4 days. Mostly CLI-output parsing per agent backend.
- **Why last:** valuable, but every other phase improves correctness; this one improves *visibility*. Worth the wait.

## Cross-cutting design notes

- **Schema spine.** Phases A, D-δ, and D-α all extend the same two files: `.swarm/capabilities.yml` and the outcome JSON. Treat the schema as load-bearing — additions are append-only; removals require a deprecation window.
- **Back-compat default.** Every phase ships behind an opt-in env var first (`SWARM_CAPABILITIES=1`, `SWARM_JUDGE=1`, etc.), dogfoods on this repo, then flips to on. Projects without the new config see no behaviour change.
- **Shape tests over LLM tests.** Each phase ships its own `test-shape-*.sh` covering listener / coordinator state transitions deterministically. LLM-in-the-loop tests stay on the side (`test-e2e-swarm.sh`) and are not required for landing a phase.
- **The roadmap is a queue, not a Gantt.** Phases interleave only where the dependency arrows allow. If a phase is blocked on real-world feedback (Phase 7's "what breaks under no-net"), park it and move on; do not start two non-adjacent phases in parallel.

## Out of scope (for now)

- Replacing tmux as the substrate. The asymmetric-visibility property (host sees workers, workers don't see host) and the post-mortem scrollback are load-bearing — see [overview → "Tmux as substrate"](./llm-swarm-runner-overview.md#tmux-as-substrate-not-just-a-ui).
- Replacing `gh` with a richer API client. `gh` is the lingua franca; everything in this roadmap can be expressed through it.
- A web UI. The `.swarm/events.log` + `tmux a` combination is the UI.
