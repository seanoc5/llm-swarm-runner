# Concepts adopted from ringer — attribution and pointers

This project adopts several **concepts** from [ringer](https://github.com/NateBJones-Projects/ringer)
by Nate B. Jones (Nate Jones Media LLC). This document is the canonical
attribution record: every adoption below links the ringer source of the idea
and our implementation of it. Code comments at each adoption site point back
here.

## License posture (read before extending this list)

ringer is licensed under **PolyForm Shield 1.0.0** (`LICENSE.md` in their
repo; "Required Notice: Copyright Nate Jones Media LLC — Ringer and
Ringside"). Our ground rules, applied to everything in this document:

- **Concepts, never code.** No ringer source is copied, ported, or
  translated. Every implementation here is written from scratch in bash
  against our own queue-v2 / GitHub-lifecycle architecture (ringer is a
  Python headless batch runner — the architectures barely overlap).
- **Not a competing product.** llm-swarm-runner is an interactive
  tmux/GitHub-lifecycle swarm; ringer is a headless batch harness with a
  dashboard. We adopt QC ideas, we do not replicate their product.
- **Attribute everything.** New adoptions must add a row + section here and
  a short comment at the implementation site.

Reference evaluation: 2026-07-17 session (the working branch,
`trial/ringer-adoption`, was deleted after merge — see PR #170 or merge
commit `7431e01`, or tags `ringer-trial-checkpoint-1`/`-2`). ringer clone
examined at commit `4ac3791`.

## Adoption index

| # | Concept | Ringer source (idea) | Our implementation |
|---|---------|----------------------|--------------------|
| 1 | Executed acceptance checks — a task passes only when an executed check exits 0 | `ringer.py:85` (`VERIFY_METHOD = "executed-check"`); per-task required `check` field (`ringer.py:~1027-1031`) | `scripts/worker-listener.sh` (`resolve_check_cmd` / `run_check` / extended `write_outcome`); `check_*` fields in `done/<id>.json` |
| 2 | Self-review as machinery, not prompt convention | ringer runs checks/verdicts in the harness, not inside the worker's own context | `scripts/self-review-pr.sh` (verdict → exit code + PR marker comment); BLOCK gate in `scripts/swarm-merge.sh` |
| 3 | Eval log + per-(model, task_type) scoreboard | JSONL eval log; `first_try_pass_rate` (`ringer.py:~2364`); `./ringer.py models` scoreboard | `append_eval_log` in `scripts/worker-listener.sh`; `scripts/swarm-scoreboard.sh`; `SWARM_EVAL_LOG` |
| 4 | Find ≠ fix — the agent that finds a problem never fixes/reviews its own work | `templates/adversarial-review` kit; "never same worker finds and fixes" rule | `prompts/coordinator.md` § "Find ≠ fix: independent review dispatch" |
| 5 | Retry-once with failure output injected | retry prompt fed by check failure output (`ringer.py:~1176` lint: "check may fail without printing why; retry prompt and eval log depend on failure output") | `scripts/worker-listener.sh` (retry block in main loop, `dispatch_agent`); `retried` field in `done/<id>.json`; `WORKER_CHECK_RETRY` |
| 6 | Brief/manifest lint — reject unverifiable or underspecified tasks before dispatch | manifest lint findings (`ringer.py:~1160-1200`): "check cannot fail", "spec is probably underspecified", pointer-spec warning | `scripts/lint-brief.sh`; warn-only hook in `scripts/provision-worker.sh`; `BRIEF_LINT=0` |

## 1. Executed acceptance checks

**Ringer's idea:** every task in a ringer manifest must declare a `check`
command; the harness executes it after the engine finishes, and only exit 0
counts as PASS. An agent *saying* it finished is not evidence; an executed
check is. Their manifest lint even rejects checks that cannot fail
(`ringer.py:~1172`: "check cannot fail, so the task cannot be verified").

**Our gap before adoption:** `done/<id>.json` recorded only the agent CLI's
exit code — a worker that exited cleanly after doing the wrong thing (or
nothing) produced `outcome: ok`.

**Our implementation (original, bash):** after the agent exits on a v2 task,
`worker-listener.sh` resolves a check command in priority order —

1. `<!-- SWARM_CHECK: <cmd> -->` marker in the task brief (per-task, the
   closest analogue to ringer's per-task `check` field)
2. `.swarm/check.sh` in the worktree (standing per-issue check)
3. `WORKER_CHECK_CMD` env (listener-wide default, e.g. the project test
   suite)

— runs it under `timeout $WORKER_CHECK_TIMEOUT`, archives full output to
`done/<id>.check.log`, and stamps `check_cmd` / `check_exit` /
`check_output_tail` into the outcome JSON. A failing check flips
`outcome` to `err` (and the filename to `.err.json`) even when the agent
exited 0. Kill switch: `WORKER_CHECK=0`. No check configured → fields are
`null` and behavior is identical to pre-adoption.

**Deliberate divergences from ringer:** checks are optional here (ringer
requires them per task) because our briefs are generated from GitHub issues
that don't yet carry acceptance criteria universally — adoption #6 (brief
lint) is the pressure toward always having one. Check output archiving and
the ok/err file-suffix contract are ours.

## 2. Self-review as machinery

**Ringer's idea:** quality gates live in the *harness*, not in the worker's
goodwill — checks are executed and parsed by machinery, so a worker
forgetting (or rationalizing away) a gate doesn't silently bypass it.

**Our gap before adoption:** the adversarial self-review
(`prompts/skill-self-review.md`) was a prompt convention in
`prompts/worker.md` — nothing ran it, parsed it, or enforced its verdict.

**Our implementation (original, bash):** `scripts/self-review-pr.sh <N>`
runs the existing skill prompt against a fresh `claude -p` session with the
PR title/body + diff, parses the verdict token, and maps it to exit codes
(0 APPROVE / 3 APPROVE_WITH_CAVEATS / 2 BLOCK / 4 skipped / 1 error). With
`--post` it publishes the verdict as an idempotent
`<!-- SWARM_SELF_REVIEW: <verdict> -->` marker comment on the PR.
`scripts/swarm-merge.sh` reads the latest marker and refuses to merge on
BLOCK unless `--override-review` is given.

**Deliberate divergences:** the review content and verdict taxonomy are
ours (pre-dated this adoption); ringer contributes the *machinery* framing.
The worker-side convention stays — this script makes it independently
runnable and its verdict enforceable.

## 3. Eval log + scoreboard

**Ringer's idea:** every task run appends a row to a JSONL model log; a
scoreboard aggregates per-(model, task_type) pass rates — crucially
including **first_try_pass_rate** (`ringer.py:~2364`), which feeds routing
(untested → probation → proven ladder). Model choices become measurements,
not vibes.

**Our implementation (original, bash/jq):** `append_eval_log` in
`worker-listener.sh` writes one row per completed v2 task (ts, task_id,
issue, agent, model, duration, exit code, check_cmd/check_exit, retried,
outcome) to `.swarm/eval-log.jsonl` (or `$SWARM_EVAL_LOG`).
`scripts/swarm-scoreboard.sh` pools logs across worktrees and renders
per-(agent, model) tasks / pass% / first-try% / retries / checked / avg
duration. This makes the "claude workers default to Sonnet 5" decision
empirically checkable.

**Deliberate divergences:** we group by (agent, model) — we have no
task_type taxonomy (our tasks are GitHub issues, not manifest kits). The
probation/proven routing ladder is NOT adopted; the scoreboard is
observability-only for now.

## 4. Find ≠ fix

**Ringer's idea:** the same worker never both finds and fixes a problem,
and review is done by *different* models/agents than the author (their
`adversarial-review` template kit has N different models review the same
artifact). Author confidence is systematically miscalibrated; independence
is the antidote.

**Our implementation (prompt-level):** a "Find ≠ fix: independent review
dispatch" section in `prompts/coordinator.md`: the authoring worker is
never asked to judge its own PR; the default gate is the fresh-context
`self-review-pr.sh` (adoption #2); 🔴 high PRs additionally get a
different-model or different-CLI reviewer; reviewers stay read-only and
findings are requeued to the author to fix.

**Deliberate divergences:** this is coordinator doctrine, not enforced
machinery (the merge-blocking half lives in adoption #2's verdict gate).
N-model review panels are not adopted — one independent reviewer per tier
matches our interactive economics.

## 5. Retry-once with failure output injected

**Ringer's idea:** a task whose check fails gets exactly one retry, and the
retry prompt carries the check's failure output — the worker gets concrete
evidence of *what* failed, not just "try again." Their manifest lint even
flags checks that "may fail without printing why; retry prompt and eval log
depend on failure output" (`ringer.py:~1176`).

**Our implementation (original, bash):** when the acceptance check fails on
a v2 task and `WORKER_CHECK_RETRY=1` (default), `worker-listener.sh`
re-dispatches the agent once with a retry preamble containing the check
command, its exit code, and the last 20 lines of its output — placed
*before* the original brief so the final instruction the agent reads is the
task itself — then re-runs the check. The outcome JSON records
`retried: true` and the first attempt's full check output is preserved at
`done/<id>.check.attempt1.log`.

**Deliberate divergences:** ringer's workers are stateless one-shots; ours
may be interactive (the retry re-enters the REPL with an attached human able
to watch). The retry fires on check failure regardless of the agent's own
exit code — a crashed agent gets the same single second chance.

## 6. Brief lint

**Ringer's idea:** lint the work definition *before* dispatch — a check
that cannot fail verifies nothing (`ringer.py:~1172`), a spec under a
minimum length is "probably underspecified; workers are stateless and
cannot ask questions", and a spec that is just a pointer starves the retry
prompt of context.

**Our implementation (original, bash):** `scripts/lint-brief.sh` lints the
`## Task` section of a queued brief for: `no-done-definition` (no
`SWARM_CHECK` marker and no acceptance criteria/checklist),
`check-cannot-fail` (`true` / `:` / `echo …` / `exit 0`),
`no-named-files`, and `underspecified` (< 200 chars).
`provision-worker.sh` runs it warn-only right after queueing the brief
(`BRIEF_LINT=0` disables; `--strict` available for callers that want a
hard gate).

**Deliberate divergences:** warn-only where ringer's lint blocks — our
briefs come from live GitHub issues mid-conversation, and blocking dispatch
on prose quality would fight the interactive workflow. The lint's job here
is to pressure issues toward carrying acceptance criteria (which feed
adoption #1's executed checks).
