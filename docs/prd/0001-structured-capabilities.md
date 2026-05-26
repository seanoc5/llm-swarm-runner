# PRD 0001 — Structured project capabilities (`.swarm/capabilities.yml`)

- **Status:** Draft
- **Date:** 2026-05-26
- **Owner:** TBD
- **Tracking issue:** TBD
- **Related:** [ADR 0003 — capabilities YAML](../adr/0003-capabilities-yaml.md), [Level-5 roadmap](../level-5-roadmap.md)

## Problem

`.swarm-policy.md` is the only place a project tells the swarm what it cares about, and it is freeform prose. That works for "don't touch `flyway/`", but it cannot carry executable contracts. Two concrete failures today:

- The worker prompt ([`prompts/worker.md`](../../prompts/worker.md)) *encourages* "run the project's tests before opening the PR" but has no way to know what that command is. Workers guess (`./gradlew test`, `./gradlew check`, `npm test`, `pytest`) and frequently guess wrong, then open a PR claiming green when nothing ran.
- The coordinator triages from pane scrollback plus the outcome JSON written by [`scripts/worker-listener.sh`](../../scripts/worker-listener.sh). That JSON carries `exit_code` and `duration_seconds`, but nothing about whether the project's verify suite actually passed. A 🟢-low tiered self-merge (introduced in #112) can therefore happen with broken tests, because "broken tests" is not a structured signal.

## Goals

1. Projects can declare verify / lint / identity-check / build commands in a structured file the swarm reads on every worker launch.
2. The worker is contractually required to run `verify` before opening a PR; refusal-to-run becomes a failure outcome, not a silent omission.
3. Outcome JSON carries `verify.passed`, `verify.command`, `verify.duration_seconds`, and a bounded `verify.log_excerpt` (last N lines on failure).
4. The tiered self-merge gate (#112) consumes `verify.passed` as a hard prerequisite for 🟢-low auto-merge.

## Non-goals

- Replacing `.swarm-policy.md`. Prose policy stays; capabilities is the *executable* sibling.
- Cross-language smart inference. There is no "we sniffed `pom.xml` and guessed `mvn verify`"; projects opt in by writing the file.
- Test-result *parsing* (JUnit XML, etc.). v1 trusts the command's exit code only.
- Coordinator-side verify execution. Verify always runs in the worker's sandbox, never on the host.

## Spec

### File: `<project>/.swarm/capabilities.yml`

```yaml
# Required commands. Each runs in the worktree root, in the worker sandbox.
verify:    ./gradlew check --no-daemon              # green = ready-for-PR
lint:      ./gradlew ktlintCheck                    # advisory; failure logged, not blocking
build:     ./gradlew assemble --no-daemon           # optional

# Optional. Listed commands run as part of verify when present;
# any failure folds into verify.passed.
identity_checks:
  - { name: "balance sheet identity", cmd: "./gradlew :engine:identityTests" }

# Blast-radius hints. Workers SHOULD refuse and surface ambiguity if a
# change touches these. Glob syntax; matched against git diff --name-only.
blast_radius_deny:
  - "flyway/**"
  - "Dockerfile"
  - ".env*"

# Optional resource caps applied to the verify step.
verify_timeout_seconds: 600
```

All fields optional; missing file ⇒ swarm behaves exactly as today (back-compat).

### Outcome JSON additions

```json
{
  "...": "existing fields unchanged",
  "verify": {
    "ran": true,
    "command": "./gradlew check --no-daemon",
    "passed": false,
    "exit_code": 1,
    "duration_seconds": 187,
    "log_excerpt_tail": "...last 80 lines, ANSI-stripped, bounded at 8KB..."
  },
  "lint":   { "ran": true,  "passed": true,  "exit_code": 0, "duration_seconds": 12 },
  "build":  { "ran": false, "skipped_reason": "no command defined" }
}
```

### Worker prompt contract

A new beat added to `prompts/worker.md`, near the end of the "before opening a PR" section:

> If `.swarm/capabilities.yml` defines `verify`, you must run it from the worktree root and wait for it to finish before opening the PR. If verify fails, do **not** open a PR; write the failure into the outcome and park on the brief. If `capabilities.yml` is absent, fall back to today's behaviour (best-effort test inference, mentioned but not contractual).

### Self-merge gate change

🟢-low tier today: "if blind-merge risk is low, self-merge without operator nod."
After this PRD: "if blind-merge risk is low **and** `verify.passed=true`, self-merge. Otherwise park as today."

🟡-medium / 🔴-high: unchanged. Verify failure already prevents merge transitively via PR-not-opened.

### Listener implementation

`worker-listener.sh` reads `capabilities.yml` at task start, exports the commands into the agent's brief context, and writes the `verify` / `lint` / `build` sub-records into the outcome JSON. The **listener — not the LLM — is responsible for actually running verify.** The LLM signals "I am ready for verify" by writing a `.swarm/tasks/processing/<id>.ready` marker file; the listener then runs the configured `verify` command in the worktree root, captures the result, and only after a green run hands control back to the LLM to open the PR.

Rationale for keeping verify out of the LLM's hands lives in [ADR 0003](../adr/0003-capabilities-yaml.md).

## Acceptance criteria

- a. `examples/swarm-capabilities.yml.example` exists and is referenced from the README and the overview doc.
- b. A new `tests/test-shape-capabilities.sh` shape test asserts:
  - missing file ⇒ outcome JSON has `verify.ran=false`
  - present file with passing command ⇒ `verify.passed=true`
  - present file with failing command ⇒ `verify.passed=false` and no PR opened (mock `gh` to assert non-call)
- c. `prompts/worker.md` updated; `prompts/coordinator.md` triage step references `verify.passed` instead of (or in addition to) reading scrollback.
- d. `kill-finished-workers.sh --pr-finalized` semantics unchanged.
- e. `docs/llm-swarm-runner-overview.md` Components section adds a short subsection.
- f. ADR 0003 captures the structured-vs-prose decision and the listener-runs-verify decision, with rejected alternatives.

## Open questions

- i. Where does the listener stream verify output? Pane (for the human) **and** a `verify.log` file (for the outcome excerpt) both — but the file needs rotation if commands re-run.
- ii. Should `lint` failure ever block the PR? Proposal: no, advisory only in v1. Revisit if false-green rates stay high.
- iii. `blast_radius_deny` enforcement: prompt-only ("worker should refuse"), or hard ("listener refuses to dispatch the agent if `git diff --name-only` matches a deny glob")? Proposal: prompt-only in v1; bump to listener-enforced in a follow-up after we see how often LLMs ignore the rule.

## Rollout

- α. Land schema + listener changes behind `SWARM_CAPABILITIES=1` (default off).
- β. Add `capabilities.yml` to *this* repo (`tests/test-shape-*.sh` is `verify`); dogfood for one week.
- γ. Flip default to on. Existing projects without the file see no behaviour change.

## Risk

Single biggest risk: listener-enforced verify slows the swarm down on projects whose `verify` is slow (Gradle cold-start, large test suites). Mitigations:

- `verify_timeout_seconds` per-project cap.
- `WORKER_SKIP_VERIFY=1` env-var escape hatch for "I know what I'm doing" runs (logged in outcome JSON so the bypass is auditable).
- Document Gradle daemon / build-cache settings in the example file's comments.
