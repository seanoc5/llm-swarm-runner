# Reports for a returning decision-maker

Review and proposal, 2026-10-07. The examples below are drafts for Sean to
judge; they are not approved preferences or changes to running agents.

## Recommendation

Resume the existing reporting epic with a small set of approved examples
and a coordinator-reply pilot. Judge whether Sean can understand the
situation and make the relevant call after losing context. Reduce the
prompt stack in a separate experiment once that standard is concrete.

Suggested audience name: **returning decision-maker**. This describes a
technically literate person who has lost recent context and owns direction,
architecture, product quality, and consequential tradeoffs. Technical
ability, recent context, and decision authority are separate dimensions.

The writing should supply enough context to support judgment. Sometimes
that needs another explanatory sentence. Brevity, absence of code names,
and compliance with a template cannot establish comprehension.

## What happened to the earlier attempts

These are separate, completed changes recorded in the repo and GitHub:

| Attempt | Delivered | Remaining limitation |
|---|---|---|
| [#209](https://github.com/seanoc5/llm-swarm-runner/issues/209), context-first PRs | Background and reviewer obligations moved earlier | Later formats changed the arrangement again |
| [#211](https://github.com/seanoc5/llm-swarm-runner/issues/211), answer first | Pane-response guidance | An answer can still assume forgotten context |
| [#230](https://github.com/seanoc5/llm-swarm-runner/issues/230), PR screen and folded details | Two layers for different reading needs | The screen still needs the right content |
| [#307](https://github.com/seanoc5/llm-swarm-runner/issues/307), coordinator report grammar | Outcome and operator ask first | Metrics and implementation vocabulary can dominate the outcome |
| [#416](https://github.com/seanoc5/llm-swarm-runner/issues/416), manager debrief | Bottom line, Your move, What surprised me | Debugging surprises and routine technical calls still reach the manager |
| [#429](https://github.com/seanoc5/llm-swarm-runner/issues/429), consequence before coordinates | Shared register rule | Reordering a sentence does not choose the right facts |
| [PR #435](https://github.com/seanoc5/llm-swarm-runner/pull/435), PR screen lint | Length, code-span, and table checks | Those checks cannot establish comprehension or useful escalation |
| [PR #481](https://github.com/seanoc5/llm-swarm-runner/pull/481), runtime/evaluation work | More truthful result notices and evaluation fixtures | The fixtures are not a measured improvement in real reader comprehension |

The pattern is delivery of guidance and checks without a completed,
recorded evaluation of the reader experience. Several implementations
finished; the quality feedback loop remains open.

Existing work to reuse:

| Work | Observed state on 2026-10-07 | Proposed use |
|---|---|---|
| [#488](https://github.com/seanoc5/llm-swarm-runner/issues/488), reporting epic | Open; records two real incidents | Keep as the umbrella; add example calibration and a pilot |
| [#533](https://github.com/seanoc5/llm-swarm-runner/issues/533), self-contained follow-up replies | Open; narrow prompt change specified | Include its behavior in the coordinator pilot; rule presence alone does not close the epic |
| [#509](https://github.com/seanoc5/llm-swarm-runner/issues/509), prompt regrowth | Open; mechanism undecided | Own prevention of future regrowth |
| [#510](https://github.com/seanoc5/llm-swarm-runner/issues/510), bare worker trial | Selector and prompt delivered; baseline posted; no completed adoption evaluation found | Finish or explicitly supersede the experiment; avoid another unmeasured trim |
| [#283](https://github.com/seanoc5/llm-swarm-runner/issues/283), transcript feedback mining | Open; broad automation proposal | Defer automation until a small manually judged sample proves useful |

## Why the current guidance can still produce hard reports

These are findings from the inspected instructions and examples, with
causal explanations treated as hypotheses to test.

- **Cold-reader guidance misses ordinary conversation.** In
  [worker.md](../prompts/worker.md), the detailed re-entry guidance is
  scoped to PR appendices and no-PR handoffs. The coordinator's report
  grammar does not explicitly cover forgotten context in follow-up
  questions. #533 identifies this same gap.
- **Some examples teach the unwanted voice.** The coordinator's follow-up
  example lists internal dataset names and database abbreviations. Its
  opening report example packs several unexplained measurements into one
  sentence. The consequence-first worker example still includes access-role
  jargon, method names, and routes in the proposed improved version.
- **The coordinator forwards prose too literally.** It is told to quote
  the worker's summary, ask, and decision table verbatim. That carries a
  worker's framing into the manager's report. A synthesis step should
  select and explain the consequential facts, while retaining traceable
  evidence and exact wording where it matters.
- **The templates reward debugging stories.** A required surprise field
  invites a recap of discoveries even when they change no decision. Put a
  surprise in the manager report when it changes scope, confidence, cost,
  risk, or the recommendation. Keep other discoveries in technical notes.
- **Numbers can displace meaning.** Test counts can support a claim, but
  they rarely explain the user-visible improvement. Quantified confidence
  should not be invented from a count of passing tests.
- **Audience rules conflict.** One section says to retain technical
  coordinates in human-facing sentences; the PR screen rules prohibit
  them there. The repo's GitHub PR template also has a simpler Summary /
  Test plan structure than the worker's example. The bare and standard
  prompts maintain separate versions of the same conventions.
- **Issue authoring gives the human little entry context.** The worker
  prompt optimizes most issue bodies for agents. Keep exact acceptance
  criteria and pointers, but add a short human-readable explanation when
  an issue is presented for prioritization or scope judgment.

A small current sample supports examining content selection. On 2026-10-07,
the existing linter returned clean for PRs
[#567](https://github.com/seanoc5/llm-swarm-runner/pull/567),
[#569](https://github.com/seanoc5/llm-swarm-runner/pull/569), and
[#575](https://github.com/seanoc5/llm-swarm-runner/pull/575).
Their openings are often useful, but their surprise fields discuss version
comparison, watcher internals, or a superseded diagnosis. #567 also asks
whether to merge based on fixture tests or wait for a live incident: a
technical validation question that agents should normally resolve within
their authority, then explain any remaining material uncertainty.
This is an editorial assessment of three specimens, not Sean's rating or
a representative quality measurement.

## Where Sean's attention belongs

Epic is a scope of outcome, not a synonym for green-field development.
An existing product can need an epic when several changes must combine to
produce one useful experience.

| Level | Sean's useful contribution | Agent responsibility | Useful review artifact |
|---|---|---|---|
| Epic | Direction, architecture boundaries, desired experience, major tradeoffs, definition of success | Explore options, identify uncertainties, propose milestones and dependencies | Plain-language outcome, recommendation, alternatives, first demonstration |
| Issue | Confirm behavior, scope, important edge cases, what must be tested | Choose implementation, fill in technical cases, implement and verify within scope | Concrete before/after example and observable acceptance criteria |
| PR | Judge a meaningful UX change, consequential tradeoff, or remaining uncertainty; apply the agreed merge gate | Resolve technical review findings and supply current evidence | Demonstration or screenshot when relevant, behavior changed, evidence and limits, recommendation |

For this work, use #488 as the epic, one coordinator pilot as the first
issue, and a small prompt/example change as its PR. Sean need not review
every wording correction or test command. His attention is most valuable
in approving examples and judging resulting reports.

Autonomy and authority are distinct: proceed with authorized reversible
work; resolve routine implementation questions; escalate changes to goals,
material tradeoffs, or missing authority. Keep existing merge and deletion
permissions until they are explicitly changed. A readability pilot does
not silently change those policies.

## Draft examples to calibrate taste

These are constructed examples using development-case facts from
[the existing fixture set](../tests/fixtures/grokkability/cases.json).
They are not reports of actions taken in this review. Labels identify
examples for discussion; they are not prescribed headings for responses.

For actual exchanges, see [Historical reports: before and after](manager-communication-history.md).
That companion preserves original excerpts and Sean's feedback alongside
new draft rewrites; those rewrites still await his judgment.

### A. Routine progress

Facts: an installation-command typo was corrected; the corrected command
was checked; a documentation PR awaits review and has not merged.

> The installation instructions had a typo that could prevent setup.
> The documentation fix is ready for review, and the corrected command has
> been checked. It has not merged yet.

Why this helps: the reader gets purpose, actual state, and the extent of
verification. There is no invented architecture decision or shipping claim.
Attach the real PR link in an actual report.

### B. Follow-up after context has been lost

Facts: a proposed access-policy change would expose private attachments to
people who are not signed in; it has not been applied; authorized users
must retain access.

> We were reviewing who can open private attachments. The proposed change
> would also let people who are not signed in read them, so I recommend
> keeping access restricted. The change has not been applied. Any fix needs
> to check both that unauthorized access is denied and that authorized
> users can still open their files.

Why this helps: the reply reconstructs the topic and explains the
consequence without requiring the previous message. It distinguishes a
risky proposal from a confirmed exposure.

### C. A technical failure the agents should own

Facts: a retry fix has an open PR; its timeout acceptance check failed;
the worker process exited successfully; independent review has not run.

> The retry fix is proposed, but it failed the check for timeouts. I
> recommend investigating and fixing that failure before recommending a
> merge. Independent review has not run yet.

Why this helps: a successful process exit does not become a success claim.
The technical failure has a technical next step. In an actual coordinator
reply, say who is handling it and what will happen next after checking the
current assignment and authority.

### D. A real decision for Sean

Facts: work is blocked on permission to delete existing customer records;
there is an open PR; no acceptance check ran.

> This change is blocked on whether existing customer records may be
> deleted. I recommend preserving them unless you explicitly authorize
> deletion. The PR is open, but it has not passed an acceptance check.
> May these records be deleted? Until you decide, the deletion work stays
> blocked.

Why this helps: the ask concerns authority and consequences, with a clear
recommendation and default. It does not hide the lack of verification.

### E. An epic or architecture proposal

Facts: worker-result notifications can be lost across coordinator restarts;
a durable inbox is proposed; the first milestone is a one-worker restart
test; model selection is outside scope; nothing has shipped.

> Worker results can get lost when the coordinator restarts. I recommend
> saving each notification before trying to deliver it, so it remains
> available after a restart. Start with one demonstration: a worker
> finishes while the coordinator is offline, and its result is recovered
> when the coordinator returns. This is a proposal; it has not shipped.

Why this helps: it explains an architectural mechanism only as far as
needed to judge the benefit and first proof of success.

### F. A completion that needs no decision

Facts: all authorized work is finished; no further useful work was found
within the objective; unused budget does not need to be spent.

> The current objective is complete, and I found no further useful work
> within its scope. I’m stopping here. Nothing needs your action.

Why this helps: it closes the loop without manufacturing a new decision
or backlog merely to keep the agents occupied.

## Candidate shared guidance

This is a proposed replacement for overlapping writing advice after
example calibration, not another paragraph to append everywhere:

> Write for a returning decision-maker who knows software but has forgotten
> this task. Name the problem or capability in plain words, explain what
> changed or what you recommend, and make the current state clear. Include
> the evidence and limitations that affect judgment. Handle routine
> technical work within your authority. Ask the user only for a consequential
> choice or missing authority, with your recommendation and the default.
> Each reply stands alone, including follow-ups. Put implementation detail
> where it supports the reader's decision or in linked technical notes.
> Use the approved examples to choose the amount of context; adapt the
> format to the situation.

Architecture questions can warrant mechanisms, diagrams, or tradeoff
tables. UX questions often warrant screenshots or a working demonstration.
The audience preference should improve those answers, not erase their
substance or force every response into a tiny status template.

## How the prompt stack operates

The inspected flow is:

```text
Backend instructions and global/project guidance
                  +
Coordinator instructions + project policy + current state/request
                  |
                  v
Issue -> brief with policy and reference index -> worker instructions
                  |
                  v
Implementation -> checks / independent review -> PR and task records
                  |
                  v
Watcher notification -> coordinator synthesis -> Sean's next judgment
```

The runner directly controls the role prompts, brief construction, scripts,
templates, and reporting procedures. Backend/global/project guidance is an
additional layer whose effective content must be recorded during a trial.

In this checkout, `llm-start.sh` selects and renders coordinator.md;
`provision-worker.sh` builds briefs with project policy and refs.md;
`worker-listener.sh` selects the standard or configured worker prompt.
Delivery differs by CLI: Claude receives appended instructions, Gemini a
system-instruction file, and Codex a prefix in the task input. Editing a
source file is not proof that a running session has received it.

The coordinator is the main place to turn technical evidence into a report
suited to Sean. It should preserve the facts and uncertainty while deciding
which details matter for direction, taste, or a genuine gate.

## Reducing the prompting

The [October 1 audit](prompt-audit-2026-10-01.md) already proposes much of
the needed split. Finish that work rather than commissioning another broad
audit with no adoption decision.

At inspected commit `02cd499`, measured with `wc -wc`:

| File | Words | Bytes |
|---|---:|---:|
| coordinator.md | 3,802 | 25,933 |
| worker.md | 3,628 | 23,607 |
| worker-bare.md | 1,639 | 10,992 |
| skill-self-review.md | 942 | 5,844 |

The bare worker is about **53% smaller in bytes** than the standard worker
today. It demonstrates that a large instruction reduction is feasible;
it does not demonstrate equal task quality or a 53% reduction in total
context, cost, or latency. The audit found that tool output and repeated
investigation were larger context consumers than the fixed prompts in its
sampled runs.

Recommended responsibilities for the simplified stack:

| Layer | Keep here |
|---|---|
| Small role core | Objective, authority, truthful reporting, project-policy precedence, required completion signal, procedure pointers |
| Shared communication guidance | One audience description and a small approved example set; reused by workers and coordinator |
| Procedures loaded for the current stage | Dispatch, PR finalization, recovery, review, detailed templates |
| Scripts | Mechanically checkable requirements, queue/status helpers, merge and ready gates |
| Project guidance | Domain invariants, actual constraints, project-specific success criteria |
| Task and state | Current acceptance criteria and a bounded, timestamped state summary; focused evidence on demand |

Remove duplicated instructions and obsolete scaffolding. Move long recipes
to the stage that uses them. Keep critical triggers explicit: a procedure
that is never loaded cannot enforce anything. Moving text saves initial
context only; text loaded on every task still has a cost.

Use one canonical source for shared rules, assembled or explicitly loaded
for each CLI, rather than copying wording among prompts. Validate delivery
on each backend. Do not assume identical text has identical instruction
priority or activation behavior across the harnesses.

Concrete enforcement candidate: `pr-ready.sh` in the inspected checkout
does not invoke `lint-pr-screen.sh`; lint remains a step the agent must
remember. Put mandatory mechanical checks in their required commands.
Treat comprehension as a separate quality evaluation. Extending a ban on
backticks will not establish that a report makes sense.

Freshness caveat: GitHub already reports
[PR #574](https://github.com/seanoc5/llm-swarm-runner/pull/574) merged,
which routes all worker merge ratings through a gated command. The active
local checkout predates it. The October 1 audit's worker-merge finding must
therefore be reconciled with current GitHub changes before filing more
work. This review did not pull, change branches, or restart live swarms.

## Small next steps and finish lines

1. **Calibrate examples under #488.** Sean edits or selects three of the
   draft examples. Collect 5–10 real reports with the source facts and
   actual decision authority. Include ordinary follow-ups, no-action
   updates, a genuine decision, and a failed check. Keep a few real cases
   out of the examples used to tune the guidance.
2. **Pilot coordinator replies.** Implement the calibrated audience
   guidance and self-contained follow-up behavior from #533 in one fresh,
   pinned trial. Compare baseline and candidate on the same facts, model,
   and settings. Generate presentation samples without operational writes.
   Judge whether the reader can state the subject, actual status, and next
   move without reopening prior messages. Record Sean's preference and any
   decision-changing omissions or unsupported claims. Use the existing
   [evaluation guide](grokkability-evaluation.md), scaled to a small pilot.
3. **Close the quality loop.** Set the promotion rule before viewing the
   reserved cases: the candidate must be understandable without prior
   context, preserve material facts, and reduce Sean's need to ask for
   explanations. Record preference case by case and resolve regressions
   before promotion. Passing format lint alone cannot close #488.
4. **Simplify the prompt architecture under #509/#510.** After freezing the
   communication guidance, compare the full and short variants with that
   same guidance and fixed tasks. Start with one extracted procedure and
   one role; measure effective loaded instructions, missed requirements,
   task outcomes, and reader corrections. Preserve trial results outside
   disposable worktrees. Decide adopt, add back specific rules, or revert.
5. **Prevent regrowth.** Each new rule needs an owner and a placement:
   enforceable behavior in a script, rare behavior in a procedure, essential
   invariant in the core. Keep a size budget, but require a quality reason
   for additions and review overlapping rules. Size alone is insufficient.

Do the technical preparation and sample generation autonomously. Reserve
Sean's involvement for choosing examples, judging a small sample, and
settling consequential product or authority questions. The first useful
deliverable is better coordinator replies, not a transcript-mining system
or a comprehensive rewrite of every prompt.

## Scope and evidence

Inspected the active checkout at `02cd499`, worktree listings, `.swarm/`
state and available trial evidence, prompt delivery scripts, role prompts,
PR template, reporting lint, evaluation fixtures, roadmap, earlier audit,
relevant GitHub issues/comments, and eight recent merged PR descriptions.
Ran the existing screen linter against three recent PR bodies; all passed.
Did not run a model experiment or measure Sean's comprehension. Reviewed
backend/global guidance only through the repo's recorded audit, not a fresh
audit of every user's configuration or running session.
