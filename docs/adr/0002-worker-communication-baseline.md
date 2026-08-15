# ADR 0002 — worker communication baseline (`prompts/worker.md`)

- **Status:** Accepted.
- **Date:** 2026-05-13.
- **Deciders:** llm-swarm-runner maintainers.

> **2026-05-22 update:** the file was renamed from `prompts/worker-base.md`
> to `prompts/worker.md`, and delivery changed from "cat'd into the user
> message of every brief" to "passed as a system prompt at agent launch"
> (claude via `--append-system-prompt`, gemini via `GEMINI_SYSTEM_MD`).
> The conventions themselves — summary, decision framing, NBA hint, PR
> risk rating, refresh-from-master, tiered self-merge — are unchanged
> from this ADR's original specification. Historical references below
> still mention `worker-base.md` because that's what was decided here;
> grep current code for `worker.md` for the live path.
>
> **2026-05-22 update (later same day):** the "Alternatives considered"
> entry below — *"Independent fresh-eyes review as the default risk-
> rating mechanism"* (rejected at original ADR time) — was partially
> reversed: an adversarial self-review (`prompts/skill-self-review.md`)
> now runs on 🟡 medium and 🔴 high PRs before workers propose merge
> or include the verdict in their refusal. 🟢 low remains fast-path
> with no review (the original rejection rationale still applies at
> that tier). Gated by `WORKER_SELF_REVIEW` env var (default 1; set
> 0 to disable). Reason for the partial reversal: the new tiered
> self-merge convention (#112) gave workers the *authority* to merge
> their own PRs; the operator's "merge PR N" instruction at the
> medium tier had become the only adversarial check, but operators
> rarely read the diff before typing the magic phrase. Self-review
> fills that gap with an actually-skeptical read from a separate
> context window.

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

The rating shipped in this ADR was a signal without a trigger: workers emitted `BLIND_MERGE_RISK` and the coordinator rendered it, but nothing acted on it — the human still had to click merge every time, even for a 🟢 typo fix.

The worker-side merge policy (`examples/swarm-policy.md.example`) explicitly forbids workers from merging their own PRs, and this amendment keeps that rule intact — a worker grading its own homework and then auto-landing the grade is too tight a loop, self-review notwithstanding. Instead, the **coordinator** becomes the actor: it already renders the rating, so extending it to *act* on the rating (after its own independent read of the diff) keeps the rating-vs-merge separation this ADR established while closing the "still requires a human click" gap.

Auto-merge only fires when `SWARM_AUTOMERGE_LOW=1` is set (default off, same env precedence as every other coordinator knob) and all six gates pass: (1) the PR body carries the exact `<!-- BLIND_MERGE_RISK: low -->` marker, (2) all required CI checks are green, (3) no `CHANGES_REQUESTED` review state, (4) the PR targets the repo's default branch, (5) the PR is `OPEN` and not a draft, and (6) the coordinator's own one-glance `gh pr diff` read confirms the claimed rating actually matches the diff's scope. Any gate failure falls back to the pre-existing behavior: render the rating, hand back to the human, with a one-line reason for the no-merge. The merge command is `gh pr merge <N> --squash --delete-branch --auto` — `--auto` rather than an immediate merge so branch-protection checks (where configured) still gate the actual merge.

Three options were on the table (see the linked issue's "Decision context" for the full writeup): (A) worker self-merges on low — rejected, same self-grading concern as above; (B) coordinator auto-merges on low, **chosen**, preserves the rating/merge separation established by this ADR; (C) GitHub-native branch protection + `--auto` on every PR — useful as a complementary layer (chosen option B still uses `--auto` for exactly this reason) but doesn't distinguish risk tiers on its own and needs per-repo setup this project can't centralize.

Kept opt-in (not default-on) for two reasons: per-project risk tolerance varies enormously (a docs repo auto-merging typo fixes is fine; a repo with a production deploy on its default branch should not auto-merge anything, ever), and auto-merge is hard to walk back once the branch is deleted and the squash commit is in history — opt-in means a human consciously turned it on for this project/session and is on the hook for that choice. A project can also override back to fully-manual regardless of the env var via `.swarm-policy.md`, per the standard "project policy wins" precedence.

Explicitly out of scope for this amendment: auto-merging 🟡/🔴 (always manual), worker-side auto-merge (still forbidden), changes to the rating rubric itself, and the GitHub-Action worker class (tracked separately).

## 2026-08 amendment: verbosity dial removed (issue #279)

The four-level `WORKER_VERBOSITY` dial this ADR introduced is retired. Its `verbose` default was justified above as matching "the learning phase for the current user" — that phase ended, the dial was never turned in practice (no recorded `-v` invocation or mid-task dial brief), and current worker models don't need a four-position knob to pace their narration. The plumbing cost was real: flag parsing and a three-level resolution chain in `provision-worker.sh`, passthrough entries in `sandbox.sh` and `llm-start.sh`, per-brief injection, and a documented-but-unused requeue adjust interface.

Replacement: a single baked-in voice in `prompts/worker.md` § "Worker voice" — status at milestones, options only at genuine decision points. The structural conventions (decision framing, risk rating) were never verbosity-controlled and are unchanged. The original text above stands as history; grep for `WORKER_VERBOSITY` in it refers to the retired mechanism.

The companion change (issue #280) landed alongside: the end-of-task `## Summary` + `## Decision` + `## Next` triad this ADR specified is now a single `## Handoff` block (**What** / **Decide** when open / **Action**), emitted last in the pane. Rationale: the operator reads tmux panes bottom-up and triages on the GitHub PR page, so the pane's final lines must carry the whole lede ("bottom line at the end" — the CLI inverse of BLUF); three stacked blocks spread it across two screens, and the old Summary's Files/Tests lists duplicated what the PR body already carries. Mid-task `## Decision` and `## Note` blocks, the PR-body skeleton, and the risk rubric are untouched.
