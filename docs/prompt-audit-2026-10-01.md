# Swarm prompt audit — 2026-10-01

The current instructions contain useful operational knowledge, but too much of it is loaded before it is needed. In the inspected runs, tool output and repeated investigation consumed substantially more context than the fixed swarm prompts. The strongest opportunity is a combination of shorter core instructions, bounded state summaries, on-demand procedures, and checks enforced by scripts.

Five portable skills would normally require five shared workflow bodies and adapters for three CLIs, rather than fifteen independently maintained implementations. Their behavior still needs testing on each backend and model.

This audit reviewed the active runner checkout, rendered coordinator prompts, project configuration, live tmux/container configuration, and selected local transcripts. It made no changes to live swarms, prompts, policies, or GitHub state. This report is a proposed direction, not an implemented migration.

## Measured prompt size

File sizes are exact. Tokens below use `o200k_base` as a consistent comparison tokenizer; they are not authoritative token counts for every deployed model. Transcript usage numbers in the next section are runtime-reported counts.

| Component | Bytes | Comparison tokens |
|---|---:|---:|
| Coordinator source | 23,521 | 6,014 |
| Actual rendered FAND coordinator prompt | 23,584 | 6,028 |
| Standard worker prompt | 19,986 | 5,162 |
| Bare worker prompt | 10,779 | 2,921 |
| Fresh-review instructions | 5,844 | 1,412 |
| Worker reference index | 816 | 201 |
| FAND project `CLAUDE.md` | 7,433 | 2,001 |
| FAND `.swarm-policy.md` | 4,852 | 1,274 |
| CorpusMinder project `CLAUDE.md` | 18,542 | 4,630 |

The bare worker prompt saves **9,207 bytes (46.1%) and 2,241 comparison tokens (43.4%)** against the standard worker prompt. This is a real saving in injected instructions, not a demonstrated reduction of 43.4% in total task cost.

The runner already trimmed much larger prompts in September: commit `4e97d56` reduced worker instructions from roughly 52 KB to 17 KB and coordinator instructions from roughly 58 KB to 23 KB. The current worker budget was subsequently raised to 22 KB. `tests/test-shape-prompt-budget.sh` guards byte size, but does not measure instruction adherence, tool-output volume, or task-level cost.

## What is running and what the traces show

At inspection, `llm-fand-app` had a successfully completed Sol coordinator turn and a live watcher. Its worker prompt override was unset, so newly provisioned workers would receive the standard worker prompt. No FAND worker was dispatched in the inspected startup turns.

CorpusMinder has `WORKER_PROMPT_FILE=worker-bare.md` in project configuration. Both container configuration and actual user inputs in the worker transcripts confirm that issues #923 and #924 received the bare prompt. Those initial inputs contained approximately 4,194 and 4,160 comparison tokens including the task brief. The first runtime-reported inputs were 18,146 and 18,112 tokens, including the CLI's other context and tools. Removing 2,241 worker-instruction tokens is therefore approximately a **12% first-request reduction** in those particular runs.

CorpusMinder's current project configuration names Codex/Sol for future coordinator launches, but its existing live coordinator was still Claude Opus 5.5. The sampled workers actually ran Codex with **GPT-5.5**, not Sol or Luna. Configuration is not proof of the backend/model already running.

| Inspected run | Reported input, accumulated across requests | Cached input | Uncached input | Output | Last request's input |
|---|---:|---:|---:|---:|---:|
| FAND startup, 11:39 EDT, Sol | 595,493 | 533,888 | 61,605 | 5,750 | 72,058 |
| FAND startup, 01:22 EDT, Sol | 715,939 | 647,936 | 68,003 | 6,058 | 78,254 |
| CorpusMinder #923, 12:07 EDT, GPT-5.5 | 9,699,514 | 9,381,376 | 318,138 | 30,646 | 194,684 |
| CorpusMinder #924, 12:09 EDT, GPT-5.5 | 13,525,762 | 13,236,480 | 289,282 | 39,391 | 215,320 |

Accumulated input counts re-count earlier context on successive requests. They do not mean that a task simultaneously held millions of tokens. The reported context-window size was 258,400. Cached input is a subset of input. Reported reasoning output is a subset of output and must not be added again.

FAND's latest startup had 11 distinct reported usage totals. The initial request was 23,057 tokens; the rendered coordinator instructions account for roughly a quarter of that. Ten tool orchestrations returned approximately **50,405 comparison tokens**, including issue bodies/comments, PR state, local guidance, and script output. Several individual batches returned 8,000–12,400 comparison tokens. The earlier startup returned approximately 56,651 comparison tokens of tool output.

The latest startup checked nine candidate issues, found zero dispatchable, repaired a missing upstream cross-link, marked a completed investigation blocked, and nudged two pending PRs. Those are useful coordination outcomes. The traces also demonstrate that a fresh broad startup repeatedly inspects a largely blocked backlog; they do not prove every read was necessary or that any particular instruction was useless.

CorpusMinder's two sampled runs returned approximately **144,232 and 155,560 comparison tokens of tool output**. Their listener records ended with `exit_code=1`, `outcome=err`, and `verification=not-run`; neither transcript had a final agent message. These records establish incomplete runs, not their cause. Both were receiving follow-up work during this audit. They are not a controlled test of prompt quality, and their failure cannot be attributed to the bare prompt from this evidence.

A separate CorpusMinder session at 12:25 EDT received about **45,222 comparison tokens in its user input**. It was not a normal bare-prompt worker invocation. This is another reason to record invocation type: auxiliary reviews, repair prompts, and requeues can dominate costs even when the normal worker instructions are shorter.

## Cost versus benefit

The FAND runs cached approximately 90% of accumulated input. The sampled CorpusMinder runs cached approximately 97%. Total input alone substantially overstates uncached processing and is not an invoice.

For API billing, use the model's actual rates:

```text
cost = uncached_input * input_rate
     + cached_input * cache_read_rate
     + cache_write_input * cache_write_rate
     + output * output_rate
```

Use consistent units, such as prices per million tokens. The FAND traces reported zero cache-write input. Authentication and billing arrangements must be recorded before applying dollar estimates: ChatGPT or Claude subscription usage cannot simply be converted into an API invoice.

Prompt caching can reduce input cost and latency, but cached text is still part of the input available to the model. Stable prefixes help reuse; rewriting earlier messages or changing configuration can affect it. Measure the CLI's actual usage before and after, rather than assuming a particular API cache control is exposed by every CLI. [OpenAI prompt-caching documentation](https://developers.openai.com/api/docs/guides/prompt-caching)

Useful cost measures for this runner are:

- Uncached input, cached input, cache-write input, and output per completed task.
- Peak request input and time until first useful action.
- Time and token usage spent on retries, repeated verification, and repeated backlog inspection.
- Verified outcomes and operator corrections per unit of usage.
- Time the operator spends understanding or repairing the handoff.

The appropriate objective is **less cost per verified useful outcome**, with preserved operational correctness. A shorter prompt can lose its savings if it causes one additional broad investigation, failed handoff, or repair cycle.

## Signal and instruction placement

There is no defensible universal signal-to-noise percentage from these traces. Instructions can be useful yet irrelevant to the current stage. The following partition is an editorial description, not a quality score:

| Standard worker content | Comparison tokens | Share |
|---|---:|---:|
| Operations and queue/protocol rules | 2,639 | 51% |
| Writing, decisions, handoffs, and PR templates | 2,306 | 45% |
| Issue authoring and documentation placement | 217 | 4% |

The bare worker still spends approximately 42% of its comparison tokens on writing and templates. The coordinator spends about 44% on reporting, review, merging, and follow-ups. Some of these sections also include operational rules, so these groups are approximate editorial categories.

Cold-reader handoffs are deliberate functionality: the operator runs several projects and returns after context is gone. Preserve that outcome. A sentence about leading with the consequence can stay in the core; multi-page templates and examples can load when writing the final artifact.

High-value always-present material includes role/scope, project-policy precedence, merge authority, truthful status reporting, the required completion signal, and how to find the relevant procedure. Rare recovery recipes, optional GitHub Action routing, detailed issue skeletons, PR-body examples, and backend-specific review commands are good candidates for conditional loading.

The full prompt does not automatically provide more reliable enforcement. Specific gaps in the inspected checkout:

1. **Merge path mismatch.** Both worker prompts direct workers to raw `gh pr merge --squash`; review-block and migration gates are implemented in `swarm-merge.sh`. The coordinator's unattended merge path uses the wrapper. The worker instructions also imply collision checks occur at merge time. Raw GitHub merges do not invoke this local wrapper. Backend-neutral agent merge actions should consistently use a gated entry point, with lifecycle/cleanup behavior designed for the worker caller.
2. **PR lint is a remembered step.** Worker instructions require `lint-pr-screen.sh` before `pr-ready.sh`, but `pr-ready.sh` does not invoke that lint. Put required lint in the ready command itself. Keep prose explaining the rule; remove the model's responsibility for sequencing an independently enforceable check.
3. **Claude assumptions remain in shared instructions.** The standard worker's fallback fresh review pipes into `claude -p`; coordinator review guidance names Claude and an Opus model. The local review script now supports Codex, but the prompt text still invites a different backend. Instructions should call the neutral review script; the script should select the backend/model.
4. **Enforcement differs by CLI.** Worker instructions say Agent/Task/Workflow tools are denied. The listener mechanically sets `--disallowedTools` only for Claude. Background-task disabling is also Claude-specific. Codex/Gemini prompt prohibitions are not equivalent to these tool restrictions. A capability profile should describe what is actually enforced for each backend.
5. **Project guidance is uneven.** The coordinator startup checklist explicitly reads policy but does not explicitly load project `CLAUDE.md` or equivalent neutral guidance. Codex workers in the samples chose to read it, but that is not proof of guaranteed startup loading. Keep required project facts and policy explicit, with detailed domain recipes routed by task type.
6. **Current evaluation logging cannot answer the experiment.** `append_eval_log()` records model, duration, outcome, checks, retry, and task state, but not prompt variant/hash, token usage, cache usage, CLI version, or instruction misses. Default logs live in worktrees and may disappear at reap. Preserve pooled experiment records outside worktrees.

These are recommendations; this audit did not change the merge or ready behavior.

## Skills across Claude, Gemini, and Codex

The portable unit is a directory containing `SKILL.md` with `name`, `description`, Markdown instructions, and optional references/scripts/assets. All three CLIs support the shared Agent Skills approach. This is primarily a **harness integration** issue, rather than requiring separately authored instructions for each model family. [Agent Skills specification](https://agentskills.io/specification), [Claude Code skills](https://code.claude.com/docs/en/skills), [Gemini CLI skills](https://geminicli.com/docs/cli/skills/), [Codex skills](https://learn.chatgpt.com/docs/build-skills)

Use one canonical source, such as `skills/swarm-review/SKILL.md`, and let the runner install or link it into supported discovery directories. Codex and Gemini document `.agents/skills`; Claude documents `.claude/skills`. The canonical files and supporting scripts must also be available inside worker containers and isolated worktrees. Do not assume mounting the runner makes its skill directory discoverable automatically.

Keep CLI-specific features out of the shared workflow body: Claude's dynamic shell substitution, forked execution, invocation controls, Gemini activation/approval behavior, and Codex metadata are adapter concerns. Older image CLIs also need compatibility checks.

Thus five skills imply approximately **five shared bodies plus three integration paths**, while validation still spans the relevant skills and backends. Individual models can differ in selection and adherence even with identical instructions.

Five plausible shared skills:

| Skill | Load when | Shared functionality |
|---|---|---|
| `swarm-triage-dispatch` | Startup/top-up or an issue needs routing | Atomic scope, duplicate checks, policy eligibility, explicit dispatch decision |
| `swarm-pr-finalize` | A worker has code ready for a PR | Risk rationale, final body template, evidence, neutral ready command |
| `swarm-review-pr` | An independent review is requested | Adversarial review criteria, verdict format, read-only reviewer scope |
| `swarm-recover-worker` | A brief is stranded or a worker fails | Queue preservation, worktree/PR checks, safe recovery options |
| `swarm-debrief` | Completion, blocked outcome, or operator digest | Cold-readable summary, decisions/defaults, evidence references |

Some of this already exists: `skill-self-review.md` is loaded only for a fresh review, and `refs.md` routes agents to longer documentation. Standard skill packaging would improve discovery and reuse; it is not a new execution engine.

Skills save initial context because only short metadata is loaded before activation. Once a skill body is read, it occupies context. A skill used on every task does not eliminate those tokens; loading it near the end can avoid carrying its template through earlier turns. Reference files should also be narrow, rather than five skills each instructing the agent to read the entire old worker prompt. [Claude skill loading](https://code.claude.com/docs/en/skills), [Codex progressive disclosure](https://learn.chatgpt.com/docs/build-skills)

Implicit activation is a fallible decision. Critical workflow stages should be selected by the launcher/event type or explicitly required in the stage prompt. Required checks belong in scripts regardless of whether the model remembers the skill.

## Proposed sequence

1. **Record what actually ran.** Add prompt path/hash, role/stage, backend/model, CLI version, usage counters, and check outcome to pooled evaluation records. Associate each review/retry/requeue with its originating task. Record the actual runtime model, not only current `.env`.
2. **Close the enforceable gaps.** Require PR lint inside readying; consolidate agent merge entry points; provide validated status/outbox/completion helpers so the agent need not hand-build JSON or copy atomic-write recipes. Emit exact task identifiers at dispatch.
3. **Bound state and tool output.** Build a timestamped, compact coordinator snapshot of caps, workers, inbox metadata, issue eligibility/reasons, PR changes, and blockers. Keep raw data/logs on disk and return paths plus focused excerpts. Fetch long bodies/comments only for unresolved candidates. Keep verification evidence available for claims that need it.
4. **Split core from procedures.** Start with a provisional 1,000–1,500 comparison-token core per role, plus explicit project guardrails and the current task/state. This is a target for testing, not a proven optimum. Render backend capability notes from actual launch configuration. Add a configurable coordinator prompt/profile selector alongside the worker selector.
5. **Pilot portable skills.** Finalization and worker recovery are good first candidates. Leave their trigger and required command in the short core. Retain the existing fixed prompt as a control variant until adherence is measured.

Moving a 2,000-token procedure to an on-demand file saves that amount only on invocations that do not read it, minus the metadata and retrieval cost. If every invocation uses it immediately, the main benefit is maintainability, not fewer tokens. Measure also whether the split creates extra searching or redundant reads.

## Controlled evaluation

Use frozen local snapshots or stubbed CLI fixtures before a live pilot. Avoid repeating GitHub writes, merges, or provisions to test prompt behavior. Compare the current full prompt, bare prompt, and a short core with explicitly selected procedures while holding model, reasoning level, CLI, tools, task, and project guidance constant.

Representative scenarios should include an empty dispatchable backlog, an epic whose suggested work already shipped, a candidate with an open PR, host-cap refusal, a stranded processing brief, a review BLOCK, a red-CI PR, a migration collision, a no-PR blocked outcome, a claimed environmental failure without evidence, worker follow-up suggestions, and a required operator decision.

Run repeated trials per scenario; record both warm and cold cache conditions when the harness allows meaningful control. Measure action correctness, missed mandatory steps, valid status/completion artifacts, calibrated evidence, handoff comprehension, tool-output volume, latency, and runtime usage. A lower byte count alone is not success. Existing shape tests establish wiring and format budgets; they do not establish model adherence.

For a live pilot, compare similar issue categories on one fixed model first. Then test the portable skill bodies on the other backends. Do not infer prompt effects from comparisons that also switch Claude to Codex, Opus to GPT-5.5, interactive to headless, and task complexity.

## Evidence and reproduction

The audit script and sanitized aggregate measurements are currently saved at `/tmp/swarm-prompt-audit.py` and `/tmp/swarm-prompt-audit-measurements.json`. They contain no raw prompt/transcript bodies. Re-run with:

```bash
UV_CACHE_DIR=/tmp/swarm-prompt-audit-cache \
  uv run --with tiktoken python /tmp/swarm-prompt-audit.py
```

Selected local transcript basenames:

- FAND: `rollout-2026-10-01T11-39-27-01a0f81e-dbc9-7123-80c8-d8c6f458b99e.jsonl` and `rollout-2026-10-01T01-22-54-01a0f5ea-63f0-7ac3-8ca6-de62f449f39d.jsonl`.
- CorpusMinder: `rollout-2026-10-01T16-07-48-01a0f838-d134-71a2-b3fd-e33ff571141a.jsonl`, `rollout-2026-10-01T16-09-02-01a0f839-f2c1-73c3-a2f3-63822ba54453.jsonl`, and auxiliary session `rollout-2026-10-01T16-25-04-01a0f848-a1b1-77c1-a0ea-a1cc33bdc788.jsonl`.

Live configuration can change during the audit. Measurements describe these selected launches, not every run of either project. Current files are used for file-size comparison; actual injected transcript text confirms the sampled worker variant.
