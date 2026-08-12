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

### Standardize an "audience statement" on every prompt/skill file
Every file in `prompts/` should open with one sentence: "this doc is read
by [WHO] who needs to [DO WHAT]." Forces the author to be honest about
scope; gives the refactor/trim/focus skill a fixed yardstick.

---

## Done

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
