# scripts/

Helper scripts for the llm-swarm-runner. Each is self-documenting at the top — `head -20 <script>` is the canonical source of truth. This table is an index for quick discovery.

All scripts here require bash 4.0+; do not run them under `sh` or `dash`.

| Script | Purpose |
|---|---|
| `_load-env.sh` | Sourceable env loader: applies `<project>/.swarm/.env` then `.env.example` to the current shell; caller-set vars win. |
| `check-stuck-workers.sh` | Surveys `iss-*` worker panes, pattern-matches the last 50 lines against known healthy/attention/broken states, and exits non-zero if any worker needs eyes-on. |
| `coord-scratch-toggle.sh` | Toggles a bare-bash scratch pane in the coordinator window (split right, repo root, no container). Invoked by the Ctrl-Z binding in the coordinator window. |
| `coordinator-claude.sh` | Launches the Claude Code coordinator REPL (wraps the long `claude` invocation so the tmux line stays short). |
| `coordinator-error-tail.sh` | Surfaces truncated gemini-cli API errors by tailing the most recent `/tmp/gemini-*-error-*.json`. No-op for the claude path. |
| `coordinator-watch.sh` | Daemon that wakes the coordinator via `llm-start.sh` when a worker drops a new outcome JSON. |
| `demo-driver.sh` | Drives a deterministic ~70-second tmux + swarm demo recording (window switches, splits, PR list). |
| `demo-record-setup.sh` | Idempotent in-place patcher for `~/.ssr/settings.conf` — tunes SimpleScreenRecorder to the demo-friendly capture rect (1920x1080 fixed), codec (h264 CRF 18), and output path (`~/Videos/demo-raw.mkv`). |
| `demo-segments-pick.sh` | Interactive picker: plays the raw demo in mpv, captures beat-boundary timestamps on `c` keypresses, then prompts for SPEED/LABEL per pair and emits a ready-to-paste `SEGMENTS=(...)` block for `edit-demo.sh`. |
| `edit-demo.sh` | Post-processes a raw SimpleScreenRecorder demo capture into a Reddit-ready ~75-second MP4 via ffmpeg segment edits. |
| `gh-status-bar.sh` | Daemon that periodically pipes open-issue / open-PR / closed-today counts into tmux's `status-right`. |
| `install-tmux-binding.sh` | Installs the Ctrl-Z worker escape-hatch binding into `~/.tmux.conf` with the absolute path baked in, then re-sources every running `swarm-*` socket. |
| `kill-finished-workers.sh` | Bulk-closes idle `iss-*` worker tmux windows (parked-only by default; flags for active / worktree / dry-run; `--merged-only` and `--pr-finalized` bypass the parked check). |
| `kill-worktree.sh` | Removes one worker's worktree, branch, and tmux window — ABANDON-verdict helper. |
| `list-swarms.sh` | Enumerates per-project tmux swarm sockets in `/tmp/tmux-$UID/` as LIVE vs ORPHAN; `--prune` deletes orphan socket files. Read-only by default. |
| `provision-worker.sh` | Coordinator one-shot: creates worktree, initialises queue, writes brief, spawns worker tmux window. |
| `reap-orphan-worktrees.sh` | Bulk-reaps stale `wt-issue-*` worktree DIRECTORIES whose work is preserved elsewhere; complements `kill-finished-workers.sh` (which walks live tmux windows) by catching worktrees that outlived their session. |
| `relocate-blind-merge-risk.sh` | One-off PR-body rewriter: moves the visible "Blind-merge risk:" line from the top of a PR body to the bottom footer, matching the current PR template. |
| `requeue.sh` | Atomically drops a follow-up task brief into a worker's v2 inbox (file or stdin). |
| `sandbox-worktrees.sh` | Lists git worktrees; optionally launches sandboxes and/or tmux windows per worktree. |
| `setup.sh` | Host-side setup; currently symlinks `/usr/bin/rg` into the path gemini-cli expects. Idempotent. |
| `swarm-merge.sh` | Resolves the PR for an issue, merges it, and cleans up the local worktree + branch + tmux window in one shot. `--sweep-only` just runs the local-branch sweep. |
| `statusline-with-context.sh` | Claude Code statusLine command rendering `<model> · <cwd> · ctx: <used>/<total> (<%>)`. For long-lived coordinator sessions — see [advanced-usage.md → "Long-lived coordinator: context monitoring"](../docs/advanced-usage.md#long-lived-coordinator-context-monitoring). |
| `sweep-swarm-outcomes.sh` | Iterates worker outcome JSONs and invokes a user-configured posting hook; idempotent via `.posted` markers. |
| `tmux-worker-shell.sh` | Opens a login shell inside a swarm worker container — backs the `C-z` tmux escape hatch. |
| `worker-listener.sh` | Async queue watcher inside a worktree; atomically claims tasks from `inbox/`, dispatches to the LLM agent, writes outcome to `done/`. |
