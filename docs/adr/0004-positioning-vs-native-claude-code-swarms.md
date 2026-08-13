# ADR 0004: Positioning vs. Claude Code's native swarm capabilities

**Status:** Proposed — drafted by the coordinator 2026-08-13, awaiting Sean's
red-pen. Claims marked `[verify]` are the author's best reconstruction and
need operator confirmation before this ADR is Accepted or quoted publicly.

## Context

Claude Code now ships substantial multi-agent capability natively: subagents
(per-agent model selection, background execution, isolated worktrees), a
deterministic workflow orchestrator (pipelines, fan-out, token budgets,
structured outputs), remote/cloud agents, and scheduled routines. A fair
question — one every demo viewer will ask in the first minute — is: **why run
llm-swarm-runner at all?**

An evaluation session earlier this week (w/o 2026-08-04) concluded the
approach "still has novel value" but left no written artifact. This ADR
reconstructs that evaluation honestly, including the claims that did NOT
survive scrutiny.

## Claims that do NOT survive scrutiny

Dropped from our positioning; do not use them in demos or posts:

- **"Better model selection."** Native subagents and workflows both support
  per-agent model choice. What survives is narrower and different: *cross-
  vendor* heterogeneity (Claude Code, Gemini CLI, Codex CLI workers under one
  coordinator) — see below.
- **"Cheaper by construction."** Both native swarms and swarm-runner workers
  run on the same subscription/API economics. The real economic lever is
  worker-class *routing* (send trivial issues to CI-verified `claude-code-
  action`, keep heavy ones local) and the ability to spread work across
  days of a subscription rather than one sitting. `[verify: this matches
  the lost session's conclusion]`

## Claims that survive

1. **Durable, external queue.** GitHub issues *are* the backlog and PRs
   *are* the output channel. Every part of the system — coordinator, watcher,
   workers — can die, reboot, or be upgraded mid-flight and the state
   survives, because the state was never in anyone's context window. Native
   workflows are superb *within* a session; they end with it. Exhibit A: the
   2026-08-12 auto-compact incident was diagnosed from `.swarm/events.log`
   and GitHub artifacts three sessions after the code that caused it ran.
2. **N independent full sessions.** Each worker is a complete Claude Code
   session: own context window, own compaction, own multi-hour lifetime,
   attachable mid-task. Subagents are bounded by their parent session.
3. **Human-gated integration as a first-class protocol.** Risk-rated PR
   bodies (🟢/🟡/🔴), mandatory fresh-context self-review, find≠fix reviewer
   separation, explicit merge verbs. Native swarm output lands in a working
   tree; the gating discipline is left to the user.
4. **Multi-project operation.** Six concurrent project swarms ran on this
   host the week of 2026-08-10, one subscription, one process layer.
5. **Cross-vendor workers.** A Codex or Gemini worker under a Claude
   coordinator (or vice versa) — native swarms are single-vendor.
6. **Tunable agent behavior at the prompt layer.** `prompts/worker.md`,
   `.swarm-policy.md`, per-project briefs: PR-body skeletons, verbosity
   tiers, list-labeling standards, merge etiquette are all operator-editable
   text, versioned in git, refined by the swarm itself via its own issue
   queue.

## What native does strictly better

Say these out loud in the demo; credibility depends on it:

- **Zero infrastructure.** No tmux, Docker, watchers, or TUI scraping.
  For a single-repo burst of parallel work, native is simpler and better.
- **Robustness.** Swarm-runner's pane-scraping breaks when the CLI's TUI
  changes — Claude Code 2.1.x removing "(esc to interrupt)" silently broke
  busy detection for every swarm on this host (#266). Native capabilities
  are API-level and don't have this failure class.
- **Deterministic orchestration.** Workflow scripts with barriers, budgets,
  and typed outputs beat prompt-mediated coordination for bounded tasks.
- **Maintenance cost.** This repo exists and must be maintained; native
  capability arrives with the CLI.

## Decision

Position llm-swarm-runner as the **process layer above sessions**, not a
competitor to in-session swarms: durable backlog execution over days,
multiple projects, human merge gates, heterogeneous workers. Inside any
one session, use native capabilities freely (the coordinator itself may
fan out subagents). Lead public messaging with the durable-queue and
human-gate story, demonstrated by the self-healing incident; never lead
with model selection or cost.

## Consequences

- README gains a "Why this instead of Claude Code's built-in swarms?"
  section sourced from this ADR.
- Demo and announcement copy must include the honest cons (brittleness,
  maintenance) — the feedback we're soliciting is worthless if the framing
  is promotional.
- Revisit this ADR when native capabilities gain durable cross-session
  queues or PR-gated integration; those would erode differentiators 1 and 3.
