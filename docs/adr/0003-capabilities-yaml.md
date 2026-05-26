# ADR 0003 — Structured project capabilities via `.swarm/capabilities.yml`

- **Status:** Proposed
- **Date:** 2026-05-26
- **Deciders:** llm-swarm-runner maintainers
- **Tracking PRD:** [PRD 0001 — Structured capabilities](../prd/0001-structured-capabilities.md)
- **Related ADRs:** [0002 — Worker communication baseline](./0002-worker-communication-baseline.md)

## Context

Two patterns have ossified in the worker → coordinator interface since the tiered self-merge convention (#112) and the adversarial self-review (#116) landed:

1. **Workers infer the project's verify command** from filesystem cues (`build.gradle.kts` ⇒ `./gradlew check`; `package.json` ⇒ `npm test`; etc.). The inference is correct often but not always, and in the "not always" cases the worker happily opens a PR with no test run, claiming green. The 🟢-low self-merge tier then merges that PR.
2. **The coordinator triages outcomes from pane scrollback.** Outcome JSON (`worker-listener.sh`) records `exit_code` and `duration_seconds` but nothing about whether *the project's own correctness gate* passed. The coordinator's only way to know is to `tmux capture-pane` and grep for words like "BUILD SUCCESSFUL" — fragile, prompt-sensitive, and silently wrong on misconfigured projects.

`.swarm-policy.md` exists, but it is prose. It cannot carry an *executable* contract: "run *this exact command* and refuse to open a PR if it returns non-zero."

This ADR records the two decisions needed to fix that: **structured config**, and **listener (not LLM) executes verify.**

## Forces

- **Cross-project portability.** Today every project either inherits the worker's guess about its build system, or repeats the command verbatim inside `.swarm-policy.md`'s freeform prose. Neither is parsable by the listener.
- **LLM honesty.** Workers asked to "run the tests then open the PR" sometimes report tests passed without running them, or run a subset, or skip slow ones. The behaviour worsens under context pressure and toward the end of a session.
- **Operator trust budget.** Tiered self-merge is only safe if the structural signal under "green" is independently verifiable. A worker saying "tests passed" is not independently verifiable; a JSON record `verify.passed=true` written by a non-LLM process that observed exit code 0 is.
- **Back-compat.** llm-swarm-runner runs against many projects today (`fand-app`, `fand-etl`, this repo itself). Any new contract must be opt-in via file presence; absent file ⇒ unchanged behaviour.

## Decisions

### Decision 1: Structured YAML file, not extended `.swarm-policy.md`

Add `<project>/.swarm/capabilities.yml` with a small fixed schema (verify / lint / build / identity_checks / blast_radius_deny / verify_timeout_seconds). `.swarm-policy.md` remains the home for prose policy.

**Why a separate file:**

- `.swarm-policy.md` is *embedded verbatim* in every worker brief. Adding YAML structure to it would mean either parsing markdown for code blocks (fragile) or shipping config inside prose the LLM is supposed to read as guardrails (confusing). Separating channels keeps each one's job clear.
- A separate file can be schema-versioned; prose cannot. When we add fields in later phases (D-δ's `sandbox_profile`, D-α's cost fields), we have a clean place to put them.
- `.swarm/` is already gitignored in most projects, but `capabilities.yml` *should* be committed — moving it under that directory mirrors the existing convention without forcing a gitignore change. (Projects that want it gitignored can add `!.swarm/capabilities.yml` to their `.gitignore`.)

**Why YAML and not TOML / JSON:**

- Comments. The example file ships with inline rationale for each field; users will edit it. JSON has no comments; TOML is fine but YAML is what the existing `.github/workflows/*.yml` ecosystem the user already operates in uses.
- `yq` is already installed in the worker image.

### Decision 2: Listener executes verify, not the LLM

`worker-listener.sh` runs the configured `verify` command itself. The LLM signals "I am ready for verify" by writing a `.swarm/tasks/processing/<id>.ready` marker; the listener then runs verify, captures result + log tail, writes the outcome sub-record, and either hands control back to the LLM (verify passed ⇒ open PR) or moves the task to `done/<id>.err.json` with the verify failure.

**Why not let the LLM run verify itself:**

- The LLM is the *thing being verified*. Asking it to run its own gate violates the same principle that drove Phase 3 (B: judge worker) — the actor and the verifier should not share a context window.
- Listener-side execution gives us a single point to enforce `verify_timeout_seconds`, capture cost-isolated metrics (verify doesn't burn LLM tokens), and assert that verify *actually ran* before any PR opens. The LLM can lie about "I ran ./gradlew check"; it cannot lie about a marker file's mtime or an exit code captured by `bash`.
- Decoupling verify from the LLM also means a future Phase-5 dependency graph can run verify steps that don't need an LLM at all (lint-only gates, etc.).

**Trade-off accepted:** the LLM cannot interactively fix failures during the verify run. If verify fails, the task parks and the LLM gets the verify log on its next claim of the brief (via requeue). Slower iteration loop on rough drafts, but the failure mode where workers ship broken code under self-merge is worse than the failure mode where workers iterate one round longer.

## Alternatives considered

### Alt A: Extend `.swarm-policy.md` with a structured "Capabilities" section

Rejected. Would require markdown-parser logic in `worker-listener.sh` (currently zero parsing — it just `cat`s files into briefs). Mixing executable config with prose guardrails in the same file makes both harder to evolve. Schema versioning becomes "is this prose version 1 or 2?" which is exactly what we want to avoid.

### Alt B: Inferred verify from project type

Rejected. We already do this implicitly via the worker's reading of `build.gradle.kts` / `package.json` / etc.; that is *the* failure mode this ADR addresses. Smarter inference is still wrong sometimes, and "sometimes wrong" composes badly with tiered self-merge.

### Alt C: LLM runs verify, listener parses pane scrollback for "BUILD SUCCESSFUL"

Rejected. Pane scraping is what we already do, badly. Build systems' success messages are not standardised; ANSI escapes complicate matching; multiline test summaries can include the word "FAILED" in green-run output (e.g., "FAILED: 0"). Worst, it requires the listener to *trust* that the LLM actually invoked the build command rather than just printing the success string.

### Alt D: Centralise capabilities in `prompts/worker.md`

Rejected. The whole point is *per-project* commands. A central worker prompt cannot know that fand-app uses Gradle and a different project uses uv + pytest.

## Consequences

### Positive

- Tiered self-merge becomes safe to widen. Phase 1 keeps the 🟢-low gate as today, but with verify required; a future phase could widen 🟡-medium auto-merge for verify-green PRs in a way that is *not* terrifying.
- Outcome JSON gains a load-bearing field every later phase (B, C, D-α, D-δ) consumes. Less ad-hoc plumbing per future PR.
- The judge worker (Phase 3) has structured input (`verify.log_excerpt_tail` + diff) instead of prose-summarised pane scrollback.
- Dogfoods immediately: this repo's `tests/test-shape-*.sh` is exactly the kind of fast deterministic verify the schema is designed for.

### Negative

- One more file projects must learn about. Mitigated by: file is optional; absent file ⇒ today's behaviour; example file ships with extensive comments.
- Verify-blocked iteration loop is slower than "LLM runs verify and fixes inline." Mitigated by: shape tests run in seconds; for projects with slow verify suites the `WORKER_SKIP_VERIFY=1` escape hatch exists for prototyping.
- Listener gains code surface (YAML parsing via `yq`, process management for the verify subprocess, log capture). Mitigated by: `yq` is already in the image; the verify subprocess pattern follows the existing dispatch-to-LLM pattern.

### Neutral

- `.swarm-policy.md` stays freeform. No migration required from existing projects.

## Compliance / rollout

See PRD 0001 §Rollout. Default off until dogfooded on this repo; flips to on after one clean week.

## Out of scope for this ADR

- Test-result parsing (JUnit XML, etc.). v1 trusts exit codes only; richer parsing is a future enhancement, not a blocker.
- Cost telemetry surfaced through the verify sub-record. Phase 8 (D-α) handles cost as a separate top-level outcome field; verify's `duration_seconds` is wall-clock only.
- Listener-enforced `blast_radius_deny` (hard refusal). v1 is prompt-only; lifting to hard enforcement is its own ADR after we observe LLM compliance rates.
