# Why the same reporting rules keep breaking (issue #645)

Research only — no prompt or memory file was changed to produce this. Carved
from the "measure first" direction of epic #488.

## Bottom line

The rule that breaks most is "restate a carried-over decision/reference
instead of pointing at it" (Cluster A below): at least 12 dated, Sean-quoted
misses across 5 of 8 inspected projects over seven weeks (2026-08-29 to
2026-10-16), including three on one project (SAMlytics) in two days and four
on another (corpusminder-spring) across two weeks. A fix for part of this
was already written and reviewed — PR #531 — and closed **unmerged** on
2026-10-04 specifically because adding its one sentence pushed
`coordinator.md` over the mechanical byte budget that
`tests/test-shape-prompt-budget.sh` enforces. That budget test is still
tight today (see "What surprised me"). This is not "the model forgets a
rule"; it is "the repo's own mechanism for keeping prompts short is, right
now, in direct competition with the repo's own mechanism for fixing this
exact family of bug." Issue #509 ("prompt regrowth: pick a mechanism") is
the open issue that already names this trade-off and is still undecided.

## 1. Inventory and clustering

73 feedback-type memories exist across the 8 projects with memory dirs
(`~/.claude/projects/*/memory/*.md`, excluding `MEMORY.md` indexes). Grouped
by the underlying rule they encode (not by project):

| Cluster | Rule | Projects with a dated miss | Dated misses found |
|---|---|---|---|
| **A — Restate carried items** | A decision/action item that recurs across replies or was described earlier must restate its substance (what it is, the options, the recommendation) every time; a label, a section pointer, or "see earlier" is not a restatement. | SAMlytics, fand-app, corpusminder-spring, civicstrata, llm-swarm-runner | **≥12** (table in §2) |
| B — BLUF / plain language / register | Lead with the plain-English outcome and consequence; swarm jargon and process narration come after, or get translated. | civicstrata, fand-app, SAMlytics, llm-swarm-runner | ~6 |
| C — List-label hygiene | One label space per reply, typeable, no ambiguous comma-runs across several items' labels. | civicstrata, fand-etl, fand-guide | ~3 |
| D — Mandatory verdict/recommendation | Every option on a Decide table or menu gets a pro/con and an explicit recommendation; no naked options. | fand-app, corpusminder-spring | ~2 |
| E — Status reports surface all open work | A status/completion report must not omit open or deferred items to look finished. | civicstrata, fand-poc | ~2 |
| F — Attribution/authorship phrasing | Minor — comment sign-off wording, draft framing. | fand-guide, fand-etl | ~2 |
| G — Memory/prompt scoping (root-cause level) | The same lesson gets independently rediscovered per project because memory is project-scoped and the shared prompts don't carry the rule; this cluster is the subject of §3, not a reporting rule itself. | all 8 | n/a |

Cluster A dwarfs the others and is also the cluster named in issue #645's
own trigger incident, so the rest of this document focuses there; B-F are
real but lower-volume and already partly covered by prior art (the
`docs/manager-communication-history.md` H1-H6 catalog is mostly Cluster B/C,
not Cluster A — none of its six examples is a carried-item case).

## 2. Cross-swarm sample: Cluster A, dated

Every row is a project's own memory file, quoting Sean verbatim at the time.
One entry (marked ✅) was independently re-verified against the raw session
transcript, not just the memory's self-report.

| Date | Project | What was carried | Sean's words | Source |
|---|---|---|---|---|
| 2026-08-29 | civicstrata | A PR-status report used internal shorthand instead of plain language | "jargon-heavy, and hot-reader oriented" | `feedback_grokkable_reports.md` |
| 2026-09-22 | civicstrata | Two findings compressed into self-coined labels ("the X gap", "the Y caveat") and referenced, not restated | "this seems written for a hot-reader" | `feedback_grokkable_reports.md` |
| 2026-09-23 | fand-app | "Forest dual-write ruling (carry-over, A recommended)" repeated across ~6 digests with no restatement of A/B | "I don't see any real evaluation/description of the two choices... I **do** see 5-10 times you suggest A" | `feedback_carryover_items_stay_self_contained.md` |
| 2026-10-03 | fand-app | Follow-up reply opened "On #1378: the 'no' is deliberate..." assuming the prior screen was remembered | "do you give me any context in the visible screen about WTF you are talking about?" | `feedback_carryover_items_stay_self_contained.md`; escalated as `#488` comment, then issue `#533` |
| 2026-10-04 | corpusminder-spring | A pending item referenced as "your d)" / "the 12 drafts", unfindable in scrollback | "not grokkable... I don't find them listed in the scrollback" | `cold-reader-restate-items.md` |
| 2026-10-06 | corpusminder-spring | Resync steps left in an earlier `<details>`; a decision abbreviated to "widen, retype or wait" | "I need you to include specifics when you have action items" | `cold-reader-restate-items.md` |
| 2026-10-06 | llm-swarm-runner | "Run the command above" when the reply held several commands | "PLEASE PLEASE PLEASE: be specific... Repeating the command... is worth the extra tokens" | `no-back-references-repeat-the-thing.md` |
| 2026-10-11 | corpusminder-spring | "`i) go`: browser-check #1215 and #1212" carried across four digests undescribed | "low-grokkability... I see nothing about how" | `cold-reader-restate-items.md` |
| 2026-10-15 | SAMlytics | "Needs you: n1 below, plus h1 and h2 from earlier" | "no idea what h1 and h2 are nor where to find them" | `restate-carried-approvals.md` |
| 2026-10-15 | civicstrata | "Pending your approval: follow-ups A–D from earlier" for 3 replies running | "Where do I find A-D? I don't see anything on this screen" | `feedback_grokkable_reports.md` |
| 2026-10-16 | corpusminder-spring | A sudo/pg_hba command referenced as "from my M1-M3 report" instead of reprinted | "is the command on this screen?... reprint the command in situations like this" | `cold-reader-restate-items.md` |
| **2026-10-16** | **SAMlytics** | ✅ "the `?` keyboard-shortcuts overlay" carried across several digests as a compressed worker phrase | *verified in the raw transcript*, `92b63bed-...jsonl:4492` (digest) and `:4495` (reply): "From many pages back I 'think' it is a way to view keyboard shortcuts?... it says 'IIRC' '? plus a menu item' which does not grok for me" | `restate-carried-approvals.md` |
| 2026-10-16 | SAMlytics | "Tailwind plan, carve order in §4: review it" carried across several digests — the incident that triggered issue #645 | "I searched a dozen references and found nothing useful" | `restate-carried-approvals.md`; issue `#645` body |

**Note on the two 2026-10-16 SAMlytics rows:** the earlier summary of this
research session flagged these as possibly the same incident misattributed.
They are not — `restate-carried-approvals.md` itself records them as the
memory's *second* and *third* dated miss, same day, different items. The
raw transcript at `92b63bed-...jsonl:4492/4495` confirms the keyboard-overlay
one directly; the Tailwind one is sourced from the memory file and issue
#645's own body (both first-party, written at the time), not independently
re-located in the raw transcript in this pass — a limitation, not a
contradiction.

**Does it cluster by situation?** Of the 13 rows, 11 are carried/digest
items (the condition the issue asked about specifically) and 2 are
conversational follow-ups. All but one (2026-10-06, llm-swarm-runner, a
single command) involve a *multi-reply carry*, not a first-mention failure
— the rule holds on first mention and breaks on repetition. The SAMlytics
transcript spans two prior context compactions (lines 2494, 3849) and
~3,300 accumulated messages by the time of the verified miss, consistent
with (but not proof of) a long-session/compaction effect; the
2026-10-06/10-11 corpusminder-spring misses and the 2026-10-03 fand-app miss
have no compaction markers nearby in the memory's own account, so
compaction is at most a contributing factor, not the sole cause.

## 3. Root-cause hypotheses, evaluated

| # | Hypothesis (from issue #645) | Verdict | Evidence |
|---|---|---|---|
| Template pull | Models copy the digest template's terse style and their own previous digest more reliably than prose rules | **Holds** | civicstrata's own self-diagnosis inside `feedback_grokkable_reports.md`'s companion file (`feedback_register_mirroring.md`, Cluster B): the model writes by matching the tone of what it just read, so reciting a rule in the system prompt ≠ writing under it. `coordinator.md`'s "Moved since last wake" instruction explicitly diffs against the coordinator's own prior digest — the mechanism rewards compression, and a carried item compresses to a label. |
| Direct conflicts | `coordinator.md:201` says quote a PR's Decide table **verbatim**; Cluster-A memories say never pass worker Decide wording through verbatim | **Holds, and is independently documented** | `docs/manager-communication-plan.md` (2026-10-07, prior art, not written for this issue) already names this exact conflict: "The coordinator forwards prose too literally... quote the worker's summary, ask, and decision table verbatim... Audience rules conflict [with] the PR screen rules [that] prohibit them there." |
| Pointer-because-unread | The coordinator cites a thing (a doc section, a worker's line) it never actually opened, so it literally cannot restate it | **Holds** | The Tailwind-§4 case: Sean "searched a dozen references and found nothing useful" is exactly what happens when the citer never read the section either — there is nothing to restate. Same shape as civicstrata's 2026-09-22 self-coined-label case. |
| Session-length effects | Compaction/long sessions reduce self-checking | **Partially holds** | True for the one deeply-verified transcript (2 compactions, ~3,300 messages); not established for the other dated misses, which have no compaction evidence recorded. Treat as a contributing factor, not the mechanism. |
| Memory bodies may never load | Only the `MEMORY.md` index line is in context; the body (the "how to apply" steps) is read only if the model opens it | **Not established either way in this pass** | Plausible and consistent with every incident (a loaded index line clearly did not stop the miss), but I did not find a tool-call in the sampled transcript window that reads vs. skips the memory file itself, so this is "consistent with," not "proven by," the evidence gathered. Flagging as unresolved rather than guessing. |
| Authority ranking | The harness frames memory as background context ("what was true when written"), while prompts/project instructions are framed as overriding | **Holds, directly inspectable** | This worker's own system prompt says memory content should be treated this way ("recalled memories... reflecting what was true when written... trust what you observe now" if they conflict). A feedback-type memory's rule is phrased as a standing instruction, but the harness frames the memory *channel* itself as lower authority than current instructions — a structural tension independent of any one project. |
| **New, not in the original list** | The byte-budget shape test and the Cluster-A fix compete for the same scarce resource | **Holds, and is the strongest single finding** | PR #531 (2026-10-04) drafted and reviewed exactly the right fix for the 2026-10-03 fand-app incident, then was **closed unmerged** because it pushed `coordinator.md` over `tests/test-shape-prompt-budget.sh`'s budget (25611 vs. then-25000 bytes), and the PR's own author flagged the conflict belonged to #509/#510. Issue #533 (the same fix, re-filed) is still open today. Measured right now: `prompts/worker.md` is 24,047 of a 24,100-byte budget — **53 bytes of headroom** — so any further one-sentence Cluster-A fix risks tripping the same gate again. |

## 4. Proposals

### Proposal 1 (Do) — a pre-send lint for coordinator reports, same shape as `lint-pr-screen.sh`

`scripts/lint-pr-screen.sh` already mechanically enforces the PR-screen
register rules before `pr-ready.sh` will proceed, but only for PR bodies.
#488's own "candidate direction 2" already named extending it to pane
reports; nobody has built it. Add a second check — reusing the same
word-budget/screen-extraction logic — for the pattern this research
actually found: a bare backward reference with no inline gloss on the
same screen (`§\d`, "from earlier", "carried over", "as noted", or a
short label like `h1`/`n1`/`A`/`B` that the same reply never defines).
Run it on the coordinator's drafted digest/reply text before sending,
exactly as `pr-ready.sh` runs the PR lint before readying.

**How to measure it:** the 13 quoted misses in §2 are a ready-made test
fixture — each is a known-bad string. A clean run against the civicstrata
digests that *didn't* draw a complaint (there are many) is the
false-positive check. Report precision/recall on that fixture before
wiring it into the live coordinator loop, the same way
`tests/fixtures/grokkability/cases.json` is used for the candidate/baseline
comparison in `docs/grokkability-evaluation.md`.

**Memories that become redundant once this ships and holds:**
`restate-carried-approvals.md` (SAMlytics), `cold-reader-restate-items.md`
(corpusminder-spring), `feedback_carryover_items_stay_self_contained.md`
(fand-app), `no-back-references-repeat-the-thing.md` (llm-swarm-runner),
and the carry-over-specific bullets (2026-09-22, 2026-10-15) inside
civicstrata's `feedback_grokkable_reports.md`. Their incident history stays
useful as the lint's test fixture; their "how to apply" prose is what the
script would take over. This document does not edit any of them — that is
project-local follow-up work once the check is live and proven.

### Proposal 2 (Decide — operator's call, not mine to file) — unblock #509 before adding another prose rule here

Issue #509 ("Prompt regrowth: pick a mechanism") already names exactly the
trade-off this research re-discovered independently: prose rules keep
getting added one incident at a time, and the shape-budget test is the
thing now refusing them. It has been open since the #531 closure
(2026-10-04) without a decision. Two live, unblocked options sit behind it:

- **Near-term, narrow:** issue #533 (land the exact #531 wording — "action
  items stand alone in follow-up replies") is still open and still useful
  on its own, independent of Proposal 1. `coordinator.md` currently has
  ~285 bytes of headroom (25,715 of 26,000) but `worker.md` has only 53 (of
  24,100) — whether #533's wording fits today needs a fresh byte count
  against current `prompts/worker.md`, not the 2026-10-04 numbers in the
  closed PR.
- **Structural:** #509's own "option a" (mechanism over prose: enforce by
  script, keep at most one clause in the prompt) is exactly what Proposal 1
  does for Cluster A specifically. Deciding #509 in that direction would
  also tell every other project whether to keep writing per-incident
  memory prose (current state) or expect a shared mechanical check instead.

I am not filing a new issue for this — #509 already is the issue — the ask
is a decision on it, not a new ticket.

## Scope notes and limitations

- This document and its supporting issue comment are the only changes made
  for issue #645; no prompt or memory file was edited.
- The cluster counts in §1 are closest for Cluster A, where every instance
  was read in full; B-F are undercounted by construction (not the focus of
  this pass) and should not be read as a precise ranking below Cluster A.
- Deep transcript verification (reading raw JSONL, not just the memory's
  self-report) was done for one incident (SAMlytics, 2026-10-16, keyboard
  overlay). The other 12 rows in §2 are sourced from the memory files
  themselves, which quote Sean directly and are dated at write time, but
  were not independently re-located in raw session JSONL in this pass.
- `docs/manager-communication-history.md` and `docs/manager-communication-plan.md`
  (2026-10-07/08) already cover Cluster B/C with a different, complementary
  methodology (keyword search for "grok" across transcripts) and already
  named the verbatim-quoting conflict independently. This document does not
  duplicate their H1-H6 catalog; none of those six examples is a Cluster A
  case.
