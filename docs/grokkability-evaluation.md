# Cold-reader evaluation

Measure whether a returning manager understands the situation and can act,
not whether a message follows a template. Shorter is useful only when it
preserves the facts that change the decision.

## First implementation slice

The listener now ends each run with a compact result, next step, verification
evidence, and worker controls. Its process-ended marker does not imply task
success. The watcher still recognizes older completion banners.

A worker reporting `blocked` produces an `err` outcome with
`task_state: blocked`, even if its process or acceptance check succeeds.
The existing `ok`/`err` filename protocol remains; `err` here means the task
did not succeed, not necessarily that the process crashed. Outcomes and
eval rows also record `verification: passed|failed|not-run`.
Unchecked `ok` outcomes remain compatible with existing consumers, but
the scoreboard no longer counts them as passes. `pass_rate` and
`first_try_pass_rate` use **all tasks** as the denominator; `unchecked`
shows missing check coverage, not proven failures. Old logs are evaluated
with the same check-based rule; they cannot recover unrecorded blockers.
Passing an executed check is evidence, not proof of every requirement or
permission to merge.

This does not yet fix the watcher's synthesized outcomes, revision-bound
checks/reviews, or default eval-log durability. It does not reconcile the
prompt/template conflicts being worked on in #429. These are separate
follow-up changes, not claimed benefits of this patch.

## Repeatable pilot

The [12 synthetic cases](../tests/fixtures/grokkability/cases.json) cover
chat, issues, epics, PRs, and runtime notices. Eight are development cases;
four are reserved for evaluation after choosing the candidate guidance.
They are a starter benchmark, **not captured baseline outputs or evidence
of improvement**. Add anonymized real outputs before deciding to promote.

1. Freeze the baseline and candidate instructions. Record commit, actual
   prompt/template/policy contents and hashes, model, CLI version, generation
   settings, and whether the session is fresh. Changing files does not
   replace instructions already loaded in a running coordinator.
2. Generate both versions from identical facts in fresh, offline/no-action
   sessions. Give the writer only `surface` and `facts`, not `expected`,
   `material_errors`, or other cases. Use the intended worker and coordinator
   models. Keep original outputs; don't silently hand-edit the candidate.
3. Assign A/B randomly per case; keep the mapping private until scoring.
   Show the reader only the candidate message, initially its opening.
   Ask: what is this about and why does it matter; what is the actual state;
   what should happen next, and is a decision needed from me?
4. Score those answers against the expected meaning, allowing paraphrases.
   Separately compare the **whole artifact** with the source facts for
   unsupported claims or omitted decision-changing limitations. The
   `material_errors` lists are examples, not exhaustive keyword checks.
5. Record A/B/tie preference separately. For timed comprehension, use separate
   readers or matched, counterbalanced cases: seeing A teaches the context
   and biases B's reading time. Separate context clarification from legitimate
   disagreement. Ordinary chat response latency is not reading time.

Extract development inputs without the answer key:

```bash
jq '[.[] | select(.split == "development") | {id, surface, facts}]' \
  tests/fixtures/grokkability/cases.json
```

After unblinding, record one JSONL row per reading, for example:

```json
{"case_id":"chat-routine","variant":"candidate","reader":"r1","context_correct":true,"status_correct":true,"action_correct":true,"material_fact_error":false,"context_clarifications":0,"reading_seconds":null}
```

Keep individual answers and fact-check notes alongside the ratings. `null`
means time was not measured; don't invent zeroes. Aggregate the recorded
ratings, without asking a model to grade its own writing:

```bash
jq -s 'group_by(.variant) | map({
  variant: .[0].variant, readings: length,
  comprehension_rate: (map(select(.context_correct and .status_correct and .action_correct)) | length) / length,
  material_fact_errors: (map(select(.material_fact_error)) | length),
  context_clarifications: (map(.context_clarifications) | add)
})' ratings.jsonl
```

Choose promotion thresholds before opening held-out results, using a measured
baseline to set realistic targets. Prefer better comprehension and blind
preference **without new material factual errors** or worse execution
quality. Report small samples as exploratory, not statistically proven.
A judge model can help inspect facts after calibration against human ratings;
its score alone is not a grokkability metric.

Evaluate presentation with facts fixed first, then run the complete workflow:
worker output, PR/issue templates, coordinator synthesis, and script notices.
The five-line listener footer is a local regression constraint, not a universal
format requirement for agent writing.

## Safe trial and next work

Keep the current prompt rewrite separate from this runtime patch. Start fresh
sessions against a pinned trial checkout and a disposable target repository;
record the actual runner launch path. Do not switch an active swarm's checkout
or assume that setting an environment variable selects every mounted script.
Switching branches does not undo GitHub writes, merges, or target-repo edits.

Next: reconcile the audience rules, templates and coordinator forwarding
(#429); fix synthesized completion and revision-bound verification; persist
evaluation records outside disposable worktrees; then compare leaner prompts
(#320) with these cases and real sessions (#283).
