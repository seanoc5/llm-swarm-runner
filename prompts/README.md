# Prompts

System and skill prompts used by the llm-swarm-runner agents.

| File | Purpose |
|---|---|
| [`coordinator.md`](coordinator.md) | System prompt for the coordinator agent |
| [`refs.md`](refs.md) | Sandbox reference-docs index |
| [`skill-refactor-trim-focus.md`](skill-refactor-trim-focus.md) | Skill prompt for refactoring (trim & focus) |
| [`skill-self-review.md`](skill-self-review.md) | Adversarial self-review skill — workers invoke via `claude -p` on 🟡/🔴 PRs before proposing/refusing merge (gated by `WORKER_SELF_REVIEW`) |
| [`worker.md`](worker.md) | System prompt for worker agents (delivered via `claude --append-system-prompt` / `GEMINI_SYSTEM_MD` / prompt-prefix for codex, which has no system-prompt flag, by `scripts/worker-listener.sh`) |
