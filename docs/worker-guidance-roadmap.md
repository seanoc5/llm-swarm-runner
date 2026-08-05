# Worker Guidance Roadmap

A living TODO list for improving the guidance documents that workers (and
the coordinator) operate from. Append to this file as you notice friction;
do not delete entries when you act on them — instead, mark them DONE with
a date and a link to the commit/PR.

**Discoverable by future agents** via `ls docs/`. **Append-friendly** —
the "Open ideas" section below is the place to add new entries.

---

## Why this file exists

Workers in this swarm currently have **no written system prompt**.
`prompts/coordinator.md` exists; `prompts/worker.md` does not. Workers run
on default Claude Code behaviour plus whatever the per-project
`.swarm-policy.md` specifies. That works for now, but it means every
project that wants worker-side conventions has to invent them in its own
policy file.

We expect this to change. As patterns emerge across projects ("workers
should always tag PR titles with the issue number," "workers must rebase
before push," etc.), they belong in a shared `prompts/worker.md` rather
than copy-pasted into each project's `.swarm-policy.md`.

This file tracks what should go into that future shared worker prompt and
what should stay in per-project policy.

---

## Open ideas

> Append to the bottom. Use a short headline + 1-3 lines of context.
> When picking one up, move it to the "Done" section with date + ref.

### Trim "grokkability fat" after the layered-handoff evaluation period
2026-07-24: worker.md's cold-reader layering (TL;DR / re-entry brief /
decisions & alternatives / review focus) deliberately spends an estimated
+20-50% on handoff surfaces to support multi-swarm context-switching.
After a few months of use, revisit which layers earn their keep and trim
toward a ~5% overhead (e.g. collapse layers on 🟡 PRs, shorten the
skeleton's prompts).

### Standardize an "audience statement" on every prompt/skill file
Every file in `prompts/` should open with one sentence: "this doc is read
by [WHO] who needs to [DO WHAT]." Forces the author to be honest about
scope; gives the refactor/trim/focus skill a fixed yardstick.

### DONE 2026-07-25 — context-first restructure of the PR-body skeleton
Review of 16 recent fand-app/fand-etl PR bodies found reviewer obligations
(decisions to make, things to verify, data hazards) consistently landing at
50–90% depth, filed under Decisions/Review-focus. Restructured the skeleton:
`## Context` (1–3 sentence advance-organizer frame, always first — context
after details does ~nothing for comprehension, per Bransford & Johnson 1972),
`## TL;DR`, `## Needs from you` (DECIDE/VERIFY/BEWARE, ≤3 bullets or
"Nothing."), new `## Findings` split out of Decisions, Re-entry brief moved
below the fold (long-form for cold agents), ~8-line budget on the top block.
Coordinator triage-quote updated to match.

Context length ruling (same day): operator leaned toward a flat 1–5
sentences + optional bullets; settled on a conditional window instead —
1–3 sentences warm territory, up to 5 cold (design proposals, new
subsystems), rationale: organizer length in the literature scales with
reader coldness (Bransford's one-line title ↔ Ausubel's ~500-word
passages), and flat windows act as targets, not caps, for LLM writers.
Bullets rejected: frames encode relations, bullets encode membership.

Provenance note, per operator request: the DECIDE/VERIFY/BEWARE tag names
and the top-block line budget were accepted as the drafting agent's
defaults — the operator explicitly skipped the suggested review of those
two knobs. They are unreviewed defaults, not considered rulings; revisit
if they chafe in practice.

---

## Done

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
