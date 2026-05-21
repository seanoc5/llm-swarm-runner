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

### Bootstrap a default `prompts/worker.md`
Workers currently have no shared system prompt. Spend one focused session
extracting the "how a worker should behave" expectations that are implicit
in `prompts/coordinator.md` (rebase before push, tiered self-merge per
risk rating, PR title conventions, etc.) into a sibling `prompts/worker.md`.
Wire `provision-worker.sh` to surface it.

### Decide what belongs in worker prompt vs `.swarm-policy.md`
Once the worker prompt exists, draft a one-page rule for the split. Rough
intuition: behaviours that should hold *across all projects in the swarm*
go in `prompts/worker.md`; project-specific guardrails (Flyway untouchable,
no Dockerfile edits, etc.) stay in `.swarm-policy.md`. Codify as an ADR.

### Apply `prompts/skill-refactor-trim-focus.md` to `prompts/coordinator.md`
The coordinator prompt is ~13KB and growing. Worth running the
refactor/trim/focus skill on it before it crosses the "two contributors
disagree about what it says" threshold.

### Standardize an "audience statement" on every prompt/skill file
Every file in `prompts/` should open with one sentence: "this doc is read
by [WHO] who needs to [DO WHAT]." Forces the author to be honest about
scope; gives the refactor/trim/focus skill a fixed yardstick.

---

## Done

> Move entries here as they're addressed. Format:
> `- (YYYY-MM-DD) <headline> — <commit-or-PR-ref>`

- (2026-05-13) **Surface this roadmap to the coordinator** — added step 2 to `prompts/coordinator.md` startup checklist (counts "Open ideas" entries each wake-up, surfaces to user, does NOT auto-file as issues).

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
