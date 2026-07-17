# Architecture & Orchestration

This document outlines the design philosophy and technical architecture of the `llm-swarm-runner` multi-agent system.

## The 2026 Pattern: Git Worktree Isolation

As LLMs have reached 1M+ token contexts (e.g., Claude 4.6, Gemini 2.5 Pro), the industry standard for multi-agent development has shifted from complex micro-container orchestration to **Git Worktree Isolation**.

This pattern solves two major problems in multi-agent environments:
1.  **File Lock Contention:** Agents attempting to edit the same file simultaneously corrupt source code.
2.  **Context Pollution:** Reading a file that another agent is half-way through refactoring breaks the first agent's mental model.

By using Git Worktrees, each agent gets a physically separate clone of the repository on the filesystem, checked out to a unique branch, while sharing the underlying `.git` object database. They can compile, break, and refactor their own branch without impacting the main branch or other agents.

## Coordinator -> Worker Architecture

This sandbox supports a fully autonomous architecture managed via `tmux`:

1.  **The Coordinator (Brain):** A dedicated `tmux` session is bootstrapped by `llm-start.sh`. Window 1 runs the configured coordinator (`claude` by default; `COORDINATOR_CMD=gemini` or `COORDINATOR_CMD=codex` selects another CLI). The coordinator acts as an autonomous project manager — it uses `gh` to read your backlog, plans tasks, and provisions worker worktrees on the fly via `provision-worker.sh`.
2.  **The Workers (Hands):** The Coordinator autonomously provisions background `tmux` windows containing isolated worker sandboxes (`claude` by default; `WORKER_CMD=gemini` or `WORKER_CMD=codex` switches the per-worker agent).
3.  **The Communication:** The Coordinator drops task briefs into each worktree's `.swarm/tasks/inbox/` (the v2 queue protocol — atomic mktemp+mv writes, structured `done/*.json` outcomes). A background `worker-listener.sh` claims tasks one at a time, dispatches them to the worker LLM, and writes the outcome JSON. Coordinator monitors progress by polling `done/` and reading the worker's PRs via `gh`.

> **Side note on tmux as a channel.** The file-based bus above is the canonical inter-agent channel. Tmux is the *substrate* every agent runs on, and the host-side coordinator can also use it as a side-channel (read worker scrollback, `send-keys` recovery input) — this is latent capability, partially used by `scripts/check-stuck-workers.sh`. Workers cannot use tmux to talk to anyone (no socket mount in the container). Cross-swarm tmux messaging isn't wired up. The full pros/cons and an opt-out recipe for ignoring best practice are in [`docs/tmux-as-channel.md`](./tmux-as-channel.md).

## Worker Classes (Local vs GH Actions)

Two execution surfaces exist for Claude workers, and the coordinator routes between them per issue:

| Class                            | Locality      | Economics            | Presence              | Use for                                                 |
|----------------------------------|---------------|----------------------|-----------------------|---------------------------------------------------------|
| tmux/Docker workers (this repo)  | `--network host` | Claude Max OAuth      | Live tmux observation | Issues touching localhost / MCP, anything to babysit    |
| `claude-code-action` (GH)        | Isolated runner | API-token billing    | Post-hoc Actions logs | Small isolated work, overnight runs, host-off scenarios |

GH Actions does **not** replace the local swarm — it complements it. See [`adr/0001-claude-code-actions-as-third-worker-class.md`](./adr/0001-claude-code-actions-as-third-worker-class.md) for the decision rationale, routing rules, and rejected alternatives. A copy-paste workflow template lives at [`examples/github-workflows/claude-code.yml.example`](../examples/github-workflows/claude-code.yml.example).

## Open Source Landscape & Alternatives

While you can build complex systems using Python frameworks like **CrewAI** or **LangGraph**, those frameworks often lack safe execution environments. This sandbox provides the missing execution layer.

If you are looking for fully pre-built orchestration tools rather than this custom shell/tmux approach, consider:
*   **Composio Agent Orchestrator (AO):** Best for enterprise-level, fully autonomous PR handling and CI fixing across worktrees.
*   **Claude Squad:** A terminal-based orchestrator very similar to this project, focusing on `tmux` session management for solo developers.
*   **Dagger (Container Use):** Focuses on high-security, headless container execution rather than interactive tmux windows.

**General Similar Projects & Resources:**
*   **Cloud-based:** [E2B (Secure sandboxes for AI agents)](https://e2b.dev/), [Daytona (Standardized Dev Environments)](https://www.daytona.io/), [Replit Deployments](https://replit.com/)
*   **Localhost/Docker-based:** [Devcontainers](https://containers.dev/), [Runme](https://runme.dev/)
*   **Further Reading:** [Anthropic's research on AI safety and containment](https://www.anthropic.com/research), [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
