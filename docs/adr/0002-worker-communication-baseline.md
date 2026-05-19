# ADR 0002 — worker communication baseline (`prompts/worker-base.md`)

- **Status:** Accepted.
- **Date:** 2026-05-13.
- **Deciders:** llm-swarm-runner maintainers.

## Context

Workers were behaving inconsistently in three ways the user explicitly named (review of recent transcripts iss-156…iss-176 confirmed all three):

1. **End-of-work summaries** were present but inconsistent in format and frequency. Workers usually emitted a structured summary on PR open, but mid-task handoffs (parking on inbox, follow-up needed) often closed with nothing.
2. **Decision-point framing** was missing mid-task. Workers picked-and-proceeded silently; alternatives + recommendations only surfaced when the worker was *blocked*. The coordinator did this well; workers did not replicate it.
3. **Next-best-action hints at handoff** were minimal — workers would say "PR opened: <url>" and stop, leaving the user to remember "review, merge, close window …".

Two further gaps showed up across the same transcript set:

4. **No PR risk assessment.** Workers never volunteered "is this safe to blind-merge?" — every PR demanded full review attention even for typo fixes.
5. **No verbosity dial.** Workers ran at a single voice; the user had no way to dial down chatter for tight-loop work or dial up teaching mode for unfamiliar territory.

The existing per-project `.swarm-policy.md` mechanism was the only lever for shaping worker voice, and it had to be re-pasted into every project — drift was the default state.

## Decision

Introduce a **shared baseline** of communication conventions that injects into every worker brief regardless of project:

- New file: **`prompts/worker-base.md`** — codifies the five conventions (summary, decision framing, NBA hint, PR risk rating, verbosity dial) as binding worker rules with examples and rubrics.
- **`provision-worker.sh`** prepends `worker-base.md` to every brief, before the project's `.swarm-policy.md` (which can override). Per-project policy retains full control; the baseline just removes the per-project re-paste tax.
- **PR risk rating format:** HTML comment (`<!-- BLIND_MERGE_RISK: low|medium|high -->`) for machine scrape by the coordinator, paired with a visible body line (`**Blind-merge risk:** 🟢 low — <rationale>`) so the rating is also legible on github.com.
- **Verbosity dial:** four levels (`verbose`, `normal`, `concise`, `spartan`); default `verbose`. Resolution precedence: `provision-worker.sh -v <level>` flag > `WORKER_VERBOSITY` in `<project>/.swarm/.env` > sandbox `.env.example` > baked default `verbose`. Forwarded into the worker container env via the existing `sandbox.sh` `WORKER_*` passthrough loop, AND injected into the brief as a `## Worker verbosity` directive so a worker that misses the env still sees it in prose.
- **Coordinator (`prompts/coordinator.md`) updated** with three sections:
  - "Mode: teaching vs doing" — trigger-phrase detection (`show me / teach me / explain / walk me through / how would you / what would you do`) flips the coordinator into describe-don't-do posture.
  - "Reporting worker outcomes" — scrape `BLIND_MERGE_RISK` from PR bodies and render with green/yellow/red emoji in status reports.
  - "Decision-point conventions" — codifies the SME-to-PO pattern (decision sentence → 2-4 options → recommendation → ask) and lists the anti-patterns to avoid.

## Rationale

- **Shared baseline reduces drift.** A change to summary conventions or PR risk format updates one file in one repo and applies to every worker in every project on the next provisioning. Per-project policy still wins on conflict, so projects with stricter or different rules aren't constrained.
- **HTML-comment + visible-line risk format** is intentionally redundant: the comment is for the coordinator's grep (stable, not subject to prose drift), the visible line is for the human reading github.com without the coordinator's mediation. Cheap redundancy, no maintenance cost.
- **Verbosity as an env var (not a separate prompt)** matches the existing `WORKER_HEADLESS` / `WORKER_CMD` / `WORKER_MODEL` pattern — same passthrough loop in `sandbox.sh`, no new mechanism.
- **Teaching-mode trigger detection at the coordinator** is where it belongs: only the coordinator sees the user's natural language, workers see only briefs. Workers don't need to know the user is in learn-mode — they just respond to whatever brief they receive.
- **Self-rated PR risk is honest enough** because the rating guides rather than gates: over-rating costs trust, under-rating costs an incident. Workers know what tests they ran and what files they touched. Independent fresh-eyes review (the existing `/review` skill) remains available as an opt-in upgrade for high-stakes PRs.

## Alternatives considered

- **Document the conventions only in `examples/swarm-policy.md.example`.** Rejected: every project has to copy them; drift returns.
- **Bake conventions into the coordinator prompt only.** Rejected: workers don't see the coordinator prompt; they only see the brief. The conventions need to live where the worker reads them.
- **Build a Claude Code output-style plugin.** Rejected for now: workers run with `--dangerously-skip-permissions` (no plugin/hook harness). Prose-in-brief is the right abstraction layer for this stack.
- **Independent fresh-eyes review as the default risk-rating mechanism.** Rejected as the always-on baseline (doubles per-PR token cost, adds wall-clock latency); kept available as opt-in via the `/review` skill.

## Consequences

- Every worker brief grows by ~150 lines (the baseline content). Trivial cost; the brief is read once at the start of a task.
- Older `.swarm-policy.md` files that documented the same conventions now duplicate the baseline. Harmless (project policy comes second; redundant rules just say the same thing twice). No cleanup gating.
- Workers without `WORKER_VERBOSITY` set in their environment fall through to `verbose` — matches the most common case for the current user during the learning phase.
- The coordinator prompt is now ~80 lines longer. Affects coordinator startup token budget marginally; no functional concern.
- A future "verbosity adjustment via requeue" can ship without changes to the baseline — the brief format is already documented as the dial-adjust interface.

## Out of scope

- **`requeue.sh --verbosity` flag.** Mid-stream verbosity adjustment uses a hand-written dial brief documented in the worker baseline; no script change.
- **Per-PR-author risk-rating calibration** (track historical accuracy of low/med/high ratings vs actual merge incidents). Possible future work; needs data collection first.
- **Migration of older project `.swarm-policy.md` files** to remove duplicated conventions. Cosmetic; no behavior change required.

## 2026-05 amendment: coordinator-side auto-merge for low-risk PRs (opt-in via `SWARM_AUTOMERGE_LOW`)

The original decision shipped the risk rating as a *signal* only — it rendered in coordinator status reports with traffic-light emoji, but never triggered an action. After a few weeks of use, the gap was clear: 🟢-rated PRs (typo fixes, docs-only changes, dependency bumps with green CI) still required a human click, defeating most of the throughput the rating was supposed to unlock.

This amendment extends — does not supersede — the original decision:

- **Workers still do not merge.** The `.swarm-policy.md.example` rule forbidding worker-side merges stands; rating-and-merge stay separated. Workers grading their own homework AND auto-landing it is too tight a loop and was rejected during the original decision.
- **Coordinator MAY auto-merge** when `SWARM_AUTOMERGE_LOW=1` is set in the environment (default off — explicit opt-in per session / per project). This preserves the principle that the merge actor is independent of the rating actor: the worker rates, the coordinator (after its own read of the diff) acts.
- **Six gates** must all hold before auto-merge fires: `<!-- BLIND_MERGE_RISK: low -->` marker present; required CI checks green; no `CHANGES_REQUESTED` reviews; base branch is the repo default; PR is open and non-draft; coordinator's own one-glance diff read confirms the worker's rationale matches reality.
- **Exact command:** `gh pr merge <N> --squash --delete-branch --auto`. The `--auto` flag lets GitHub gate on branch-protection checks if the repo has them; if not, it merges immediately. Either path leaves a clean audit trail in the PR timeline.
- **Fallback on any gate failure** is the unchanged pre-amendment behavior: surface the PR to the human with the rating rendered, plus a one-line "held off auto-merge: <reason>" so the human knows why.

### Why opt-in rather than on-by-default

- **Per-project autonomy varies.** A docs repo can absorb an auto-merged typo fix. A repo with a production deploy on `master` should not auto-merge anything ever. Env-knob lets each project decide without forking the coordinator prompt.
- **Auto-merge is hard to take back.** Squash + delete-branch destroys the recoverable state; the merge commit is in history. Opt-in means the human consciously enabled it and is on the hook.
- **Recoverable mistakes only.** Even when enabled, the gates above conservatively scope what auto-merges — anything touching auth, schema, or multi-file source code falls outside the 🟢 rubric and remains manual.

### Why not on the worker side

Option A in the original decision (worker auto-merges on `low`) was rejected and stays rejected for the same reasons: the worker rated its own work and merging on that rating is a one-actor loop with no second pair of eyes. The coordinator's separate read of the diff — even a one-glance read — is a cheap second pair of eyes that catches the worst miscalibrations (rating says "docs-only" but diff touches `src/`).

### Why not GitHub-native branch protection alone

GitHub-native branch protection + `--auto` on every PR is the right complementary layer (and is exactly why the gate above uses `--auto`). But it doesn't distinguish low/medium/high on its own — it would either auto-merge everything that passes CI or nothing. The rating-based gate adds the missing dimension; branch protection (where configured) adds defense in depth.

### Consequences

- The coordinator prompt grows by ~40 lines (the new subsection). Trivial budget impact.
- Projects that already set `SWARM_AUTOMERGE_LOW=1` need no other action; existing 🟢 PRs from already-merged workers are not retroactively re-evaluated (the gate runs at coordinator wake time on currently-open PRs).
- The amendment is reversible: unsetting `SWARM_AUTOMERGE_LOW` restores the pre-amendment "render-only" behavior with zero code change. No migration burden if a project changes its mind.
