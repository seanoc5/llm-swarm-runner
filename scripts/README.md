# scripts/

Helper scripts for the llm-swarm-runner. Each is self-documenting at the top — `head -20 <script>` is the canonical source of truth. This table is an index for quick discovery.

| Script | Purpose |
|---|---|
| `_load-env.sh` | Sourceable env loader: applies `<project>/.swarm/.env` then `.env.example` to the current shell; caller-set vars win. |
| `coordinator-claude.sh` | Launches the Claude Code coordinator REPL (wraps the long `claude` invocation so the tmux line stays short). |
| `coordinator-error-tail.sh` | Surfaces truncated gemini-cli API errors by tailing the most recent `/tmp/gemini-*-error-*.json`. |
| `coordinator-watch.sh` | Daemon that wakes the coordinator via `llm-start.sh` when a worker drops a new outcome JSON. |
| `demo-driver.sh` | Drives a deterministic ~70-second tmux + swarm demo recording (window switches, splits, PR list). |
| `gh-status-bar.sh` | Daemon that periodically pipes open-issue / open-PR / closed-today counts into tmux's `status-right`. |
| `kill-finished-workers.sh` | Bulk-closes idle `iss-*` worker tmux windows (parked-only by default; flags for active / worktree / dry-run). |
| `kill-worktree.sh` | Removes one worker's worktree, branch, and tmux window — ABANDON-verdict helper. |
| `provision-worker.sh` | Coordinator one-shot: creates worktree, initialises queue, writes brief, spawns worker tmux window. |
| `requeue.sh` | Atomically drops a follow-up task brief into a worker's v2 inbox (file or stdin). |
| `sandbox-worktrees.sh` | Lists git worktrees; optionally launches sandboxes and/or tmux windows per worktree. |
| `setup.sh` | Host-side setup; currently symlinks `/usr/bin/rg` into the path gemini-cli expects. Idempotent. |
| `sweep-swarm-outcomes.sh` | Iterates worker outcome JSONs and invokes a user-configured posting hook; idempotent via `.posted` markers. |
| `tmux-worker-shell.sh` | Opens a login shell inside a swarm worker container — backs the `C-z` tmux escape hatch. |
| `worker-listener.sh` | Async queue watcher inside a worktree; atomically claims tasks from `inbox/`, dispatches to the LLM agent, writes outcome to `done/`. |
