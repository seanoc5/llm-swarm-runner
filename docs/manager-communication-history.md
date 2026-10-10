# Historical reports: before and after

Drafts for Sean to judge, 2026-10-08. These examples come from actual
Claude exchanges. The A–F examples in
[the communication plan](manager-communication-plan.md) are synthetic
practice examples built from the repo's evaluation fixtures.

The original wording and Sean's reactions below are historical. The
rewrites are new proposals, not responses Sean has already approved.
Read each rewrite as an excerpt of a response at the original time;
none reports current system state or authorizes an operation today.

## What the history adds

Searching for `grok` finds the places where Sean explicitly signaled a
problem, including `grokkable`, `grokkability`, and `not-grokking`. The
surrounding turns show what he asked, what the answer said, and what he
needed explained afterward. That is better evidence for selecting examples
than an agent's opinion about which responses look bad.

Two distinct problems recur in the inspected exchanges:

- **The wording does not support judgment.** Unexplained labels, unclear
  ownership, options without a nearby recommendation, or many concepts
  introduced before the reader has a structure for them.
- **The useful wording is off-screen.** A clear opening is followed by
  extensive detail, leaving the terminal's final screen without the
  context or decision. This needs attention to placement and display as
  well as writing.

The tables use short original excerpts so the comparison is manageable.
The source links preserve access to the full answer and feedback. An
excerpt is not a claim that the full answer contained no useful context.

## H1. An explanation that introduces too much at once

**Situation:** Sean asked what a good executive debrief should look like.
The answer supplied seven principles, three pushbacks, and three questions.

**Sean's feedback:** “it is all good insight, but seems to me to overload
the reader.” He also asked where the ideas fit into a preexisting structure.

| Before: actual excerpts | After: proposed opening |
|---|---|
| “Manage by exception: every ask ships with a default.” / “Attention allocated by irreversibility, not by effort.” / “A tiering discipline.” | I recommend organizing updates around three questions: **What changed? What supports the conclusion? What decision is yours?** I’ll handle routine technical work within the authority you’ve given me. I’ll flag uncertainty or disagreement that could change your decision, and we should occasionally spot-check the work. |

**What changed:** the opening supplies a familiar structure before adding
principles. Detailed advice can follow when useful. This is a draft
opening, not a complete replacement for the historical answer and its
unresolved questions about reporting frequency and authority.

Source: 2026-09-13,
[original answer](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/492f4635-100a-4022-a10d-cf8af5d32fdb.jsonl:156),
[Sean's feedback](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/492f4635-100a-4022-a10d-cf8af5d32fdb.jsonl:159).

## H2. A menu of actions without a usable recommendation at the end

**Situation:** a communication-style investigation ended with four options:
settle a PR-format trial, file a manager-voice issue, move the terminal
summary, and hide thinking summaries. The body contained recommendations,
but the final action menu required the reader to reconstruct them.

**Sean's feedback:** “you give me 4 naked options, no pros/cons, no
suggestions”.

| Before: actual excerpt | After: proposed handoff |
|---|---|
| “Action: Reply with any of a/b/c/d (e.g. ‘b, c, d — and keep the skeleton’).” | I recommend keeping the PR summary with expandable details, improving its manager-facing wording, and putting the coordinator’s summary at the end of terminal replies. This builds on the existing format, though wording changes alone still need evaluation. Rebuilding the format would be a larger change with no demonstrated benefit yet. Hiding thinking summaries is a separate display preference; it won’t improve the answer itself. May I file the two reporting issues? |

**What changed:** the handoff contains the recommendation, its basis, an
alternative and its cost, and a specific ask. The display preference is
separate from report quality. No issues are claimed to have been filed.
The statement about evaluating wording is a proposed editorial addition,
not a historical measurement.

Source: 2026-09-13,
[original answer](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/492f4635-100a-4022-a10d-cf8af5d32fdb.jsonl:74),
[Sean's feedback](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/492f4635-100a-4022-a10d-cf8af5d32fdb.jsonl:78).

## H3. Labels that require looking backward

**Situation:** instructions for switching three swarms to Gemini workers
used both numbered steps and S1/S2/S3 names for the swarms.

**Sean's feedback:** “You mix 'Step 1' and 'S1'” and “what is S1 for
restarting??”.

| Before: actual excerpt | After: proposed instruction |
|---|---|
| “Step 3. Smoke test. Restart S1 the usual way and give it one low-risk issue.” | First test the switch on **corpusminder-spring**: restart that swarm and give one low-risk issue to a new Gemini worker. Confirm that the worker identifies itself as Gemini and produces a usable PR. If that succeeds, restart fand-app and SAMlytics. |

**What changed:** the project name and purpose replace a remembered label.
The conditional rollout is preserved. This repairs the instruction's
meaning; a fully actionable replacement would also supply the verified
restart command beside the instruction. The historical excerpt does not
establish that command, so this review does not invent one.

Source: 2026-10-01,
[original answer](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/5c80aefc-7fbf-457c-b566-a2411aed4460.jsonl:165),
[Sean's feedback](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/5c80aefc-7fbf-457c-b566-a2411aed4460.jsonl:168).

## H4. An “Action” link that does not say what to do

**Situation:** the assistant recommended leaving a RAM-build proposal
unmerged while first trying a shared dependency cache. It requested
permission to add an explanatory PR comment, then labeled the PR URL
as the action.

**Sean's feedback:** “I **think** that means: park and wait??? confusing
because the action is essentially 'no ation'???”.

| Before: actual excerpt | After: proposed ask |
|---|---|
| “Action: https://github.com/seanoc5/llm-swarm-runner/pull/530 (to be parked with a comment)” | I recommend leaving **the RAM-build proposal, PR #530, open and unmerged** while we try the shared dependency cache first. May I add a comment explaining that it is on hold? That does not merge or close it. |

**What changed:** the ask states who will act and what will happen to the
proposal. This preserves the recommendation already made in the source
answer; it does not silently reverse the earlier recommendation to merge.
The separate request to enable the dependency cache would still need its
own clear wording.

Source: 2026-10-04,
[original answer](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/e472797f-9925-472f-b26b-b34b7b9c0e3e.jsonl:721),
[Sean's feedback](/home/sean/.claude/projects/-opt-work-llm-swarm-runner/e472797f-9925-472f-b26b-b34b7b9c0e3e.jsonl:729).

## H5. A technical next step with an unclear owner

**Situation:** while helping Sean find a GitHub permission, the assistant
found that the worker's token could read workflow results but could not
read them through the interface used by the runner. It recommended a
runner change, leaving Sean unsure whether he was supposed to implement it.

**Sean's feedback:** “not grokkable... how do I do (2)?”.

| Before: actual excerpt | After: proposed handoff |
|---|---|
| “Change the swarm's CI-wait script so it falls back to the Actions run list when the checks view returns ‘not accessible’.” | Leave the token unchanged: it can read build results through an interface the runner isn’t using. I recommend a small runner fix that uses that working interface when needed. If you approve, **I’ll file the implementation issue in llm-swarm-runner**. You don’t need to edit a script. |

**What changed:** the next action has an owner, the requested permission is
explicit, and the reason for the fix is understandable. This preserves the
historical request for permission to file an issue. With standing authority
to file it, an actual agent should do so and report the result instead.
The example makes no general claim about which GitHub token permissions
are available today.

Source: 2026-10-01,
[original answer](/home/sean/.claude/projects/-opt-work-springboot-corpusminder-spring/4dd556a7-da73-48f0-bf12-bee439f982c0.jsonl:914),
[Sean's feedback](/home/sean/.claude/projects/-opt-work-springboot-corpusminder-spring/4dd556a7-da73-48f0-bf12-bee439f982c0.jsonl:917).

## H6. A useful opening that disappears from the terminal screen

**Situation:** an answer about application monitoring opened with a useful
finding: Prometheus and Grafana already ran on both machines, but data
collection and dashboards were incomplete. Long technical tables and
queries followed. There was no closing manager summary.

**Sean's feedback:** “It is focused on worker details, and hides the lede
(at the top, out of sight)”.

| Before: actual excerpt near the end | After: proposed closing summary |
|---|---|
| “For now, `journalctl -u <app>` is still the right tool and needs nothing.” | The monitoring tools are already running on both machines; the gaps are collecting data from the apps and showing it in useful dashboards. Some missing data comes from stopped development apps, while other apps need configuration or access fixes. I recommend a shared overview dashboard and request tracing for fand-app. May I make those dashboard and tracing additions? |

**What changed:** the last screen restores the topic, state, and proposed
action after the technical material. The original opening was useful;
its placement was part of the failure. The full answer also contained
collection/access repairs that this short closing summary does not replace.
This is a text-based assessment; the screenshot referenced in the feedback
was not inspected in this review.

Source: 2026-09-26,
[original answer](/home/sean/.claude/projects/-opt-work-sysadmin/44fb08fb-0934-4cca-bded-e065dd05ed76.jsonl:80),
[Sean's feedback](/home/sean/.claude/projects/-opt-work-sysadmin/44fb08fb-0934-4cca-bded-e065dd05ed76.jsonl:84).

## How to use these

Start with a reaction to H1, H3, and H5: do the proposed versions give
enough context and a clear next move? Edit the wording directly when a
sentence still makes you reconstruct the situation. The question is
whether these drafts help Sean judge, not whether they sound polished to
the writer.

Keep approved examples as a small writing reference. Use different real
exchanges to evaluate whether the guidance transfers. Do not grade a
candidate only on examples used to write its instructions. Include a few
responses Sean liked as positive examples, and do not treat every request
for clarification or use of `grok` as a communication failure.

## Search scope and provenance

Searched `/home/sean/.claude/projects` JSONL histories case-insensitively
for `grok`, excluding subagent directories. Filtered candidate files to
omit paths containing `-worktrees-`, then extracted user text while omitting
metadata, sidechain/compact-summary records, and messages over 12,000
characters. The resulting index contained **109 matching turns in 69
session files across nine project directories**. These are candidate
matches, not 109 failures or a failure-rate measurement. Some matches
discuss UI design, quote other material, or use the word positively.

Reviewed selected conversations, using parent-message links to connect
feedback to the preceding assistant response. H2 is adjacent feedback in
a session found through the keyword search; its critique does not itself
contain `grok`. Dates above use UTC from the records. Source links point to
local files and may stop working if those histories are removed. Only
task-relevant excerpts are copied here, not full transcripts or credentials.

The keyword index remains in `/tmp/grokkability-history/user-grok.jsonl`
for this review. It is temporary working material, not part of the repo
or a durable dataset. No prompt changes, operational commands from the
history, GitHub writes, or live swarm changes were made to produce these
examples.
