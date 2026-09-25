# Worker Guidance Roadmap

A living TODO list for improving the guidance documents that workers (and
the coordinator) operate from. Append to this file as you notice friction;
do not delete entries when you act on them — instead, mark them DONE with
a date and a link to the commit/PR.

**Discoverable by future agents** via `ls docs/`. **Append-friendly** —
the "Open ideas" section below is the place to add new entries.

---

## Why this file exists

Workers in this swarm originally had **no written system prompt** —
`prompts/coordinator.md` existed; `prompts/worker.md` did not. That meant
every project that wanted worker-side conventions had to invent them in
its own `.swarm-policy.md`.

That gap is closed: `prompts/worker.md` now exists and is delivered as a
real system prompt at agent launch — `scripts/worker-listener.sh:564`
passes `--append-system-prompt "$(cat worker.md)"` for claude, and
`:565` sets `GEMINI_SYSTEM_MD=$WORKER_MD` for gemini (see the Done entry
below, 2026-05-22, PRs #111/#112).

This file now tracks ongoing refinement of that shared prompt — patterns
that should move from a project's `.swarm-policy.md` into `prompts/worker.md`
once they prove out across projects, and vice versa.

---

## Guidance hygiene: reviewing against the current model generation

Guidance in `prompts/` accumulates fastest right after a model transition —
each new failure mode earns a new rule, few old rules get re-examined, and
a few months in, prose calibrated for one model generation actively hurts
the next: over-prescriptive scaffolding produces rigid literal-following
and dilutes the rules that actually matter (2026-08 corpusminder-spring
audit finding; issue #320 applied it here to `prompts/coordinator.md` and
`prompts/worker.md`; issue #463 went further on the same two files, see
the Done entries below).

**Trigger:** operator-initiated, typically on a major model transition —
not a recurring calendar job.

**When adding a new rule to either prompt file, state two things inline so
a future audit can classify it cheaply without archaeology:**

1. **Incident of origin** — the issue number, PR, or dated incident that
   motivated the rule. A rule with no traceable origin is hard to judge
   later: real recurring failure, or a one-off overcorrection?
2. **Category** (framework from issue #320):
   - **Infrastructure contract** — caps, file-bus protocols, atomic-write
     patterns, sandbox facts, exit-code semantics. Encodes the
     environment, not the model. Compress prose freely; never trim substance.
   - **Fact the agent can't discover** — script paths, env-var names,
     marker strings, repair flows. Keep, compress.
   - **Incident-born operator preference** — merge gates, consent verbs,
     risk-rating rendering. Keep the rule; cut rationale essays to a
     one-line citation (or move to `docs/` with a pointer).
   - **Model-era scaffolding** — step-by-step choreography of things a
     current model already does unprompted, repeated emphasis of the same
     rule, defensive over-specification. Prime removal target next audit.
   - **Stale** — references a file/flag/flow that no longer exists.
     Verify, then delete.

A one-line imperative with a bare issue number already satisfies this —
the goal is traceability, not ceremony.

**Audit history:** 2026-09-20, issue #320 — first pass, ~20% trim, both
files kept in a verbose incident-narrative style. 2026-09-24, issue #463
— second pass on the same two files, ~65-70% trim (worker.md 52KB→17KB,
coordinator.md 58KB→23KB): collapsed overlapping format sections into one
debrief schema + one worked example, merged repeated recovery-sweep
prose, cut incident narratives to one clause. #463 is the current
baseline; treat its structure (not #320's) as the pattern for future
additions.

---

## Open ideas

> Append to the bottom. Use a short headline + 1-3 lines of context.
> When picking one up, move it to the "Done" section with date + ref.

### DONE 2026-08-06 — trimmed via two-tier screen + folded-appendix rebuild (issue #230)
2026-07-24: worker.md's cold-reader layering (TL;DR / re-entry brief /
decisions & alternatives / review focus) deliberately spends an estimated
+20-50% on handoff surfaces to support multi-swarm context-switching.
After a few months of use, revisit which layers earn their keep and trim
toward a ~5% overhead (e.g. collapse layers on 🟡 PRs, shorten the
skeleton's prompts).

Resolution (2026-08-06, trial): rather than trimming line-by-line, rebuilt
the skeleton around a two-tier structure — a BLUF screen (`**What this
is:**` / `**What I need from you:**`, plus a `#### Decide` table only when
an open decision exists) over a folded `<details>` appendix holding
Background/What changed/Findings/Decisions made/Test plan/Review focus.
`## Context` and `## Re-entry brief` merged into one `## Background`. The
fold, not a line-count budget, is now the enforcement mechanism. Status:
trial — Sean judges from real PR specimens before this is considered
settled. Issues got a separate brief-shaped template (`## Goal` /
`## Constraints` / `## Acceptance criteria` / `## Pointers` /
`## Out of scope`) since ~90% of issues are read only by LLMs, not the cold
human reader the old layering targeted.

**Settled 2026-09-15 via issue #416** ("recast summary surfaces for a
manager/decision-maker reader, Debrief schema v1"): the two-tier
screen-over-folded-appendix *structure* from this trial is ratified as-is —
no further structural changes pending. What #416 changed was the *voice*
inside that structure: the screen's fields (`**What this is:**` / `**What I
need from you:**`) were reworded to `**Bottom line:**` / `**Your move:**`
plus a new `**What surprised me:**` line, per Debrief schema v1
(`prompts/worker.md` § "Debrief schema v1"). Same fold, same fields'
purpose, manager-audience wording.

---

## Done

- (2026-09-24) **Deeper 5.x trim of `prompts/coordinator.md` and
  `prompts/worker.md`, superseding the 2026-09-20 pass** — issue #463.
  Where #320 kept each file's existing section structure and compressed
  prose within it (landing ~20%), #463 restructured: one debrief schema
  plus one worked, lint-verified PR example replaced six overlapping
  format sections in `worker.md`; four separate recovery sweeps in
  `coordinator.md` merged into one wake sweep; incident narratives cut to
  a single clause each. Net: `worker.md` 52KB→17KB, `coordinator.md`
  58KB→23KB. Every machine contract preserved verbatim (markers,
  status/outbox schema, section titles other files cite,
  `{{LLM_SWARM_DIR}}` placeholders, auto-merge gates 0-7, doorbell text).
  Also added `tests/test-shape-prompt-budget.sh` to catch future regrowth.
  #320's own word-count deltas (7836→6203, 7634→6250) are superseded by
  this pass and no longer describe the current files — see "Guidance
  hygiene" above for both audits' history.

- (2026-09-20) **5.x-era guidance audit of `prompts/coordinator.md` and
  `prompts/worker.md`** — issue #320. Applied the classification framework
  above (contract / undiscoverable fact / incident-born preference /
  model-era scaffolding / stale) section-by-section to both files.
  Category-1/2 substance (env vars, script paths, JSON schemas, exact
  bash, PR-body/handoff templates, marker strings, the auto-merge gate
  list, the self-merge risk table) kept verbatim or compressed-only.
  Landed a ~20% trim (worker.md 7836→6203 words, coordinator.md
  7634→6250) — short of the ≥30-40% guideline because a section-by-section
  compress-in-place pass couldn't cut as deep as #463's later restructure
  (see the 2026-09-24 entry above, which superseded this pass's actual
  file contents four days later). This entry's lasting contribution is
  the "Guidance hygiene" framework above, not the specific word counts.

- (2026-09-19) **One blanket register rule: consequence before coordinates**
  — issue #429. Added `prompts/worker.md` § "Register: consequence before
  coordinates": every sentence in human-facing text (the PR-body screen,
  `## Handoff` block, follow-up-suggestions items, coordinator
  reports/wake digest) now leads with plain-English impact — what
  happened, who's affected, what it costs — before file paths, routes, or
  method names, which are demoted to a trailing clause/parenthetical
  instead of deleted. Carve-out: agent-consumed payloads (briefs, outcome
  JSONs, a Do:/Decide: clause's own target) stay precise-first, since
  those are read by LLM workers who need exact coordinates to act.
  Composes with, rather than replaces, the existing layout rules (Debrief
  schema v1, `prompts/coordinator.md` § "Report grammar") — BLUF picks
  which sentence leads a report, register picks what that sentence leads
  with. Prompted by an operator-graded incident on a sibling swarm
  (civicstrata PR #381, 2026-09-15): a coordinates-first follow-up item
  rated ~4/10 grokkable for the operator despite following the
  then-current template faithfully — a template gap, not guidance
  ignored. Follow-up-suggestions item template reordered to a
  plain-English label first; `skill-self-review.md` gained a cheap
  (~10s) register check (`APPROVE_WITH_CAVEATS` only, never `BLOCK`);
  coordinator's follow-up-suggestions triage now paraphrases pre-rule,
  coordinates-first PR bodies into register before quoting them in a
  digest, flagging the paraphrase as such.

- (2026-09-15) **Standardize an "audience statement" on every prompt/skill
  file** — issue #416. Every file in `prompts/` (`worker.md`,
  `coordinator.md`, `refs.md`, `skill-self-review.md`,
  `skill-refactor-trim-focus.md`, `README.md`) now opens with one sentence:
  "this doc is read by [WHO] who needs to [DO WHAT]." Landed as part of the
  same PR that recast the PR-body screen, `## Handoff` block, and
  coordinator report grammar/wake digest around Debrief schema v1.

- (2026-07-25) **Context-first restructure of the PR-body skeleton** — review of 16 recent fand-app/fand-etl PR bodies found reviewer obligations (decisions to make, things to verify, data hazards) consistently landing at 50–90% depth, filed under Decisions/Review-focus. Restructured the skeleton: `## Context` (1–3 sentence advance-organizer frame, always first — context after details does ~nothing for comprehension, per Bransford & Johnson 1972), `## TL;DR`, `## Needs from you` (DECIDE/VERIFY/BEWARE, ≤3 bullets or "Nothing."), new `## Findings` split out of Decisions, Re-entry brief moved below the fold (long-form for cold agents), ~8-line budget on the top block. Coordinator triage-quote updated to match.

  Context length ruling (same day): operator leaned toward a flat 1–5 sentences + optional bullets; settled on a conditional window instead — 1–3 sentences warm territory, up to 5 cold (design proposals, new subsystems), rationale: organizer length in the literature scales with reader coldness (Bransford's one-line title ↔ Ausubel's ~500-word passages), and flat windows act as targets, not caps, for LLM writers. Bullets rejected: frames encode relations, bullets encode membership.

  Provenance note, per operator request: the DECIDE/VERIFY/BEWARE tag names and the top-block line budget were accepted as the drafting agent's defaults — the operator explicitly skipped the suggested review of those two knobs. They are unreviewed defaults, not considered rulings; revisit if they chafe in practice.

- (2026-07-23) **Apply refactor/trim/focus to `prompts/coordinator.md` (and `worker.md`, `refs.md`)** — coordinator.md had grown to 23KB; trimmed to ~half by extracting the AVAILABLE gh-filter into `scripts/available-issues.sh`, dropping the teaching-mode and decision-point-conventions sections (native behavior on Fable-5-class coordinators), and deduplicating the parallelism routing table with worker.md. worker.md trimmed ~40% (constraints kept verbatim, why-essays compressed); at-rest glyph default unified to `∎`.

> Move entries here as they're addressed. Format:
> `- (YYYY-MM-DD) <headline> — <commit-or-PR-ref>`

- (2026-05-13) **Surface this roadmap to the coordinator** — added step 2 to `prompts/coordinator.md` startup checklist (counts "Open ideas" entries each wake-up, surfaces to user, does NOT auto-file as issues).
- (2026-05-22) **Bootstrap a default `prompts/worker.md`** — closed across PRs #111 (refresh-from-master), #112 (tiered self-merge), and the rename + system-prompt delivery (this PR). File `prompts/worker-base.md` was renamed to `prompts/worker.md`; `scripts/worker-listener.sh` now passes it as a system prompt at agent launch (`claude --append-system-prompt`, `gemini GEMINI_SYSTEM_MD`) instead of cat'ing into the user message. The original ambiguity ("workers have no shared system prompt") is now literally false.
- (2026-05-22) **Decide what belongs in worker prompt vs `.swarm-policy.md`** — captured in the system-prompt-migration PR description: universal worker behaviors in `prompts/worker.md` (system), per-project guardrails in `<project>/.swarm-policy.md` (brief, may override). Reference-doc index `prompts/refs.md` stays in brief because it's contextual rather than a behavior rule and may be extended by projects via `.swarm-policy.md`.

---

## How to use this file

**Adding an idea**: append a new entry under "Open ideas" with a 1-3 line
explanation. No format ceremony beyond a clear headline.

**Acting on an idea**: do the work, then move the entry to "Done" with
date and a commit/PR reference. Do not just delete the entry — the
historical list of "what we noticed and did" is useful context for
future grills.

**Refactoring this file itself**: if the "Open ideas" section grows
beyond ~30 entries or starts to overlap, run
`prompts/skill-refactor-trim-focus.md` on it.
