# Skill: Refactor / Trim / Focus a Guidance Document

*This doc is read by an agent invoked to refactor, trim, or focus a
guidance document who needs to know when and how to do it without losing
substance.*

**Status**: Draft skeleton — needs sharpening with real examples once it's been used a few times.

## Purpose

Keep a guidance document (a worker prompt, a skill file, a CLAUDE.md, a
coordinator prompt, an onboarding doc) from drifting into bloat, contradiction,
or dilution as it accrues edits over time.

A doc rots in three distinct ways. This skill addresses each:

- **Refactor** — structure has decayed. Sections are out of order, the same
  concept is split across two places, the table-of-contents lies, the order
  of operations isn't actually the order presented.
- **Trim** — bulk has accreted. Hedge phrases, stale advice that no longer
  applies, examples that explain the obvious, repeated warnings, "see also"
  loops, copy-paste from past versions of the doc.
- **Focus** — audience or intent has drifted. The doc started as "how a
  worker behaves" and has slowly absorbed "how the coordinator monitors
  workers" — split, or pick one.

## When to invoke

- A guidance doc has crossed ~500 lines (rule of thumb — adjust per project).
- Two contributors disagree on what the doc says (sign of structural problem).
- A worker / agent reading the doc consistently misses a section that IS there.
- After a major feature lands that touched the doc — sweep the ripple effects
  before they harden.
- As scheduled hygiene: every N weeks if the project is high-velocity.

## Inputs

- **Path to the doc** (e.g. `prompts/worker.md`).
- **Audience statement** — one sentence: "this doc is read by [WHO] who needs
  to [DO WHAT]." If the user can't state this in one sentence, the doc has
  drifted and the first work is recovering the audience statement.
- **Recent issues / failures** (optional) that motivated the cleanup. These
  point at the bits most worth examining.

## Process

1. **Recover the audience statement.** Either the user provides it or you
   propose one based on the doc's current content; confirm before proceeding.
2. **Read the whole doc once.** Note three lists as you go:
   - **Confused** — places where you (a fresh reader) lost the thread.
   - **Repeated** — same idea said in two places.
   - **Stale** — advice that no longer matches the codebase / workflow.
3. **Propose cuts BEFORE rewrites.** It is much easier to evaluate "delete
   these 40 lines" than "rewrite section 3." Show the cut list first; get
   approval; then do them.
4. **Propose structural moves.** Same rule: surface the diff (move section
   2.3 under section 5; promote section 1.4 to top-level) before you rewrite.
5. **Rewrite only what's left.** By now the doc should be 60-80% of its
   former size. Rewrites are sentence-level: hedge → assertive, jargon →
   plain, passive → active.
6. **Re-check audience fit.** Read the new doc once with the audience
   statement in mind. Anything that doesn't serve the audience — flag for
   removal or relocation.
7. **Produce a CHANGES summary.** A short bulleted list at the bottom of the
   conversation (or as a commit message) explaining what was cut, what
   moved, what was rewritten. The user reviews this; not the full diff.

## Output

- The refined doc (in place — direct edits to the file).
- A CHANGES summary the user can scan in 30 seconds.
- (Optional) An entry in `docs/worker-guidance-roadmap.md` noting what was
  done and what's still deferred.

## Anti-patterns to avoid

- **"Add a section on X" without checking whether X belongs.** Most doc rot
  comes from additive edits. This skill is biased toward deletion.
- **Rewriting before cutting.** You'll waste effort polishing prose that
  should have been deleted.
- **Preserving every example.** Examples have a half-life. Two examples that
  illustrate the same point — keep the better one.
- **Smoothing over a real disagreement.** If two sections contradict each
  other, surface the contradiction to the user; don't silently pick a side.
- **Treating length as the goal.** "Shorter" is usually right but not
  always. A doc can be too short to be useful. The goal is *fit for the
  stated audience*, not minimum bytes.

## See also

- `docs/worker-guidance-roadmap.md` — running list of guidance-doc
  improvements to be picked up by future agents.
