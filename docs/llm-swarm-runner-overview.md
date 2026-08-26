# llm-swarm-runner: Project Overview

A persistent, local-first sandbox for running autonomous LLM agents (Claude Code, Gemini CLI, Codex CLI) against your real host services, with safety isolation provided by Docker + git worktrees + tmux. This document is the canonical reference for *how the pieces fit together*; for narrower topics see the other files in `docs/`.

## Contents

- [Why This Exists](#why-this-exists)
- [Architecture at a Glance](#architecture-at-a-glance)
- [Components](#components)
  - [sandbox.sh — Docker wrapper for one agent](#sandboxsh--docker-wrapper-for-one-agent)
  - [llm-start.sh — Bootstrap a Coordinator session](#llm-startsh--bootstrap-a-coordinator-session)
  - [kill-worktree.sh — Clean up a worker worktree](#kill-worktreesh--clean-up-a-worker-worktree)
  - [requeue.sh — Drop a follow-up brief into a worker's queue](#requeuesh--drop-a-follow-up-brief-into-a-workers-queue)
  - [provision-worker.sh — One-call worker dispatch](#provision-workersh--one-call-worker-dispatch)
  - [setup.sh — Host-side post-install setup](#setupsh--host-side-post-install-setup)
  - [.swarm-policy.md — Per-project rules-of-engagement](#swarm-policymd--per-project-rules-of-engagement-optional)
  - [OpenBrain MCP integration](#openbrain-mcp-integration)
  - [coordinator-watch.sh — Event-driven coordinator wake-ups](#coordinator-watchsh--event-driven-coordinator-wake-ups)
  - [sweep-swarm-outcomes.sh — Audit-trail post-processing](#sweep-swarm-outcomessh--audit-trail-post-processing)
  - [coordinator-error-tail.sh — Surface gemini API errors](#coordinator-error-tailsh--surface-gemini-api-errors-in-the-pane)
  - [worker-listener.sh — Queue watcher for worker agents](#worker-listenersh--queue-watcher-for-worker-agents)
  - [prompts/coordinator.md — Coordinator's brain](#promptscoordinatormd--coordinators-brain)
  - [Other scripts — see scripts/README.md](#other-scripts--see-scriptsreadmemd)
  - [test-shape-swarm.sh — Non-LLM shape test](#test-shape-swarmsh--non-llm-shape-test-for-the-queue-protocol)
  - [test-shape-helpers.sh — Non-LLM shape test for triage helpers](#test-shape-helperssh--non-llm-shape-test-for-triage-helpers)
  - [test-shape-orchestration.sh — Non-LLM shape test for provision/watch/list](#test-shape-orchestrationsh--non-llm-shape-test-for-provisionwatchlist)
  - [test-watcher-autoclose.sh — Non-LLM shape test for WATCHER_AUTOCLOSE](#test-watcher-autoclosesh--non-llm-shape-test-for-watcher_autoclose)
  - [test-e2e-swarm.sh — Local end-to-end test (with real LLM)](#test-e2e-swarmsh--local-end-to-end-test-with-real-llm)
- [End-to-End Flow (Real Use)](#end-to-end-flow-real-use)
- [Coordinator Trade-offs](#coordinator-trade-offs)
- [Coordinator Lifecycle](#coordinator-lifecycle)
- [Known Limitations](#known-limitations)
- [Reproducible Builds](#reproducible-builds)
- [Related Files](#related-files)

## Why This Exists

Running autonomous LLM agents directly on your host is risky: a hallucinated `rm -rf` or wrongly-confident `kubectl delete` can ruin your day. This sandbox provides:

1. A **containment layer** (Docker) so destructive commands hit a container, not the host.
2. A **multi-agent orchestrator** (tmux + worktrees) so multiple agents work in parallel without stepping on each other's files.
3. **Identity passthrough** (mounted `~/.claude`, `~/.ssh`, `~/.config/gh`) so the agent inherits your auth without re-login or copying secrets.

## Architecture at a Glance

```
+----------------------------------------------------------------+
|  tmux session: llm-<project-basename>                           |
|                                                                |
|  +---------------+  +-------------+  +-------------+           |
|  | window 1      |  | window 2    |  | window 3    |   ...     |
|  | "coordinator" |  | "iss-42"    |  | "iss-57"    |           |
|  | configured    |  | sandbox.sh  |  | sandbox.sh  |           |
|  | coordinator   |  | -> worker   |  | -> worker   |           |
|  | (host shell)  |  | (in docker) |  | (in docker) |           |
|  +-------+-------+  +------+------+  +------+------+           |
|          | provisions       | watches             | watches    |
|          v                  v                     v            |
|  +-------+----------+  +----+----------+   +-----+----------+  |
|  | main repo        |  | wt-issue-42   |   | wt-issue-57    |  |
|  | (host fs)        |  | (worktree)    |   | (worktree)     |  |
|  |                  |  | .swarm/tasks/ |   | .swarm/tasks/  |  |
|  +------------------+  +---------------+   +----------------+  |
+----------------------------------------------------------------+
```

- **Coordinator** lives on the host (not containerized) so it can `tmux new-window`, `git worktree add`, and `gh` against your auth directly.
- **Workers** live inside `llm-swarm-runner:latest` Docker containers (via `sandbox.sh`) so any destructive command they invent is blast-radius-limited.

### Tmux as substrate, not just a UI

The choice of tmux for the session layer is load-bearing in a way that's easy to miss. Every agent — coordinator and each worker — runs inside a tmux pane rather than as a detached background process, which gives every line every agent ever prints a **persistent, host-readable artifact**: the pane's scrollback. `llm-start.sh` sets `history-limit 50000` and `remain-on-exit failed` on the swarm's tmux socket at startup (also mirrored in [`examples/tmux.conf.example`](../examples/tmux.conf.example) for manual/non-`llm-start.sh` tmux use), so even an agent that crashed an hour ago still has its full transcript sitting in a `[dead]` pane, grep-able via:

```bash
tmux -L swarm-<repo> capture-pane -t llm-<repo>:iss-N -p -S -50000
```

Two distinct capabilities flow from this:

- **For humans (used today)**: post-mortem grep over a dead worker's exact transcript without re-running it, replay-style debugging, cross-worker comparison. Most of [`docs/tmux-cheatsheet.md`](./tmux-cheatsheet.md) is built around this — `capture-pane -S -200`, the dead-pane workflow, the `kill-finished-workers.sh` helper.
- **For the host-side coordinator**: the coordinator runs host-native and has unrestricted access to the swarm's tmux socket, and this is no longer purely latent. `scripts/check-stuck-workers.sh` already `capture-pane`s to classify a stuck REPL, and `coordinator-watch.sh`'s `WORKER_AUTO_COMPACT` already `send-keys`s a real `/compact` (plus a "continue your task" nudge) into idle over-threshold worker panes by default (issue #226) — an engineered, idle-gated flow, not the coordinator LLM improvising a recovery `send-keys` on its own initiative. The current coordinator prompt ([`prompts/coordinator.md`](../prompts/coordinator.md)) still polls `.swarm/tasks/done/<id>.json` outcome files and `gh pr list` as its primary loop, but explicitly blesses read-only `capture-pane` as a diagnostic fallback (`coordinator.md:99`).

**Asymmetric visibility — not the symmetric one you might assume.** The coordinator can read every worker's pane scrollback; **workers cannot read the coordinator's or each other's panes via tmux**, because the host tmux socket isn't bind-mounted into worker containers (see [`sandbox.sh`](../sandbox.sh) mount list). Workers do, however, share `/var/run/docker.sock` and can `docker exec` into sibling containers — a *larger* blast radius than tmux visibility, covered in [`docs/security.md`](./security.md).

For a consolidated treatment of tmux as an inter-agent channel — what works today, what's blocked by design, pros/cons vs the file-based bus, and the escape-hatch recipe for opting out of the sandbox — see [`docs/tmux-as-channel.md`](./tmux-as-channel.md).

## Components

### `sandbox.sh` — Docker wrapper for one agent

Generalized launcher: `sandbox.sh <project-dir> <agent> [extra-args]`

- `<agent>` ∈ `{claude, gemini, codex, listener, bash}` (default `bash`).
- Mounts: project dir (rw), `~/.claude` (rw), `~/.claude.json` (rw), `~/.codex` (rw), `~/.ssh` (ro), `~/.gitconfig` (ro), `~/.config/gh` (ro), `~/.npm-global` (rw), `~/.npm` (rw), and the script's own dir (ro, so worker-listener.sh is reachable).
- Auto-mounts the **git common dir** when invoked on a worktree whose `.git` file points outside the project dir.
- **Docker-out-of-Docker (DooD):** mounts `/var/run/docker.sock` so Testcontainers / `docker` CLI work inside the sandbox; `--group-add` gives the sandbox user write perms on the socket.
- **GH token passthrough:** reads `gh auth token` on the host and injects as `GH_TOKEN` (necessary because `gh` stores its token in the system keyring on Linux, not in the mounted config dir).
- **SSH agent forwarding** when `SSH_AUTH_SOCK` is set.
- **Memory cap:** `SANDBOX_MEM_LIMIT` (default `8g`) is applied as `--memory`/`--memory-swap` on every container; set higher (e.g. `24g`) for heavyweight builds or `0` to disable. Exit code 137 inside the sandbox usually means this cap fired — see [advanced-usage.md](./advanced-usage.md#memory-limit-sandbox_mem_limit).
- `EXTRA_MOUNTS` env var: comma-separated `host:container[:ro|:rw]` extra bind mounts.
- `.sandbox-env` file in the project dir is auto-loaded as a Docker `--env-file`.
- Networking: `--network host` (so agents can reach `localhost:5432` Postgres, etc.).

### `llm-start.sh` — Bootstrap a Coordinator session

Creates `tmux` session `llm-<basename-of-cwd>` if missing, opens window 1 as `coordinator`, and launches the configured coordinator with the initial prompt and the procedure from `prompts/coordinator.md`. Claude defaults to an interactive REPL; Codex runs one-shot via `codex exec`; Gemini supports print or interactive mode.

Also spawns `coordinator-watch.sh` as a second pane in the `util` window when `WATCH=1` — the default; set `WATCH=0` to skip it. The watcher inherits `POST_OUTCOMES`, `OUTCOME_HOOK`, `DEBOUNCE_SECS`, `WAKE_PROMPT`, `POLL_SECS`, `WORKSPACE`, and `SWEEP` directly from the caller's env, plus `MAX_WORKERS`, `MAX_TMUX_WINDOWS`, `TARGET_AVAILABLE`, `OWNER_LABELS`, and `INCLUDE_ASSIGNED_TO_OTHERS` via the tmux session env (set by `tmux new-session -e` after `llm-start.sh` loads `<project>/.swarm/.env` + `.env.example`). So:

```bash
WATCH=1 POST_OUTCOMES=1 OUTCOME_HOOK=/path/to/poster ./llm-start.sh
```

…spins up the entire unattended supervisor pattern (coordinator + event-driven wakes + audit-trail posting) from a single invocation. Idempotent — re-running against an existing session that already has a coordinator-watch pane running in `util` logs `coordinator-watch pane already running in '<session>:util' — skipping spawn` instead of stacking duplicates.

#### Session reuse: detect-dead-coordinator

When the session already exists, `llm-start.sh` inspects the coordinator pane's current command (`tmux list-panes -F '#{pane_current_command}'`) and decides:

- **Idle pane** (bash/zsh/sh) → previous coordinator already exited. **Reuses the existing window** and sends the new prompt into it. Same scrollback, no need to kill anything.
- **Busy pane** (node/claude/etc.) → coordinator is mid-run. Doesn't disturb; just attaches.
- **No session** → creates fresh.

This means you can re-invoke `llm-start.sh` repeatedly with new prompts without thinking about state cleanup.

#### CLI flags

`llm-start.sh --help` prints the canonical reference. Summary:

| Flag                    | Equivalent env                  | Notes                                                                  |
|-------------------------|---------------------------------|------------------------------------------------------------------------|
| `-h`, `--help`          | n/a                             | Full reference (env vars, yolo bundle, examples)                       |
| `-w`, `--watch`         | `WATCH=1`                       | Spawn `coordinator-watch.sh` in the `util` window (already the default; use `WATCH=0` to disable) |
| `-y`, `--yolo`          | (bundle — see below)            | Opinionated automation; explicit flags + shell env still win            |
| `--status`              | `STATUS=1`                      | Spawn `gh-status-bar.sh` in a dedicated `status` window                 |
| `--max-workers N`       | `MAX_WORKERS=N`                 | Concurrent worker tmux windows (default 5)                              |
| `--max-windows N`       | `MAX_TMUX_WINDOWS=N`            | Total session window cap (default 10) — runaway brake                  |
| `--target-available N`  | `TARGET_AVAILABLE=N`            | Backlog target; `0` disables auto-issue-creation                        |
| `--include-others`      | `INCLUDE_ASSIGNED_TO_OTHERS=1`  | Claim teammates' tickets too                                            |
| `--owner-labels L1,L2`  | `OWNER_LABELS=L1,L2`            | Comma-sep "human-owned" labels                                          |

Both forms accepted: `--max-workers 8` and `--max-workers=8`.

**Precedence:** flag > shell env > `<project>/.swarm/.env` > `<sandbox>/.env.example`. Implementation: flags `export` directly (overwriting any shell-env value), then `_load-env.sh` runs and only fills *unset* vars. So `MAX_WORKERS=8 ./llm-start.sh --max-workers=10` ⇒ `MAX_WORKERS=10`.

**`--yolo` bundle** (only sets unset vars, so explicit flags + caller env still win):

```
WATCH=1  STATUS=1  MAX_WORKERS=5  INCLUDE_ASSIGNED_TO_OTHERS=1  DEBOUNCE_SECS=15
```

`MAX_TMUX_WINDOWS` is deliberately **not** bumped by `--yolo` — the runaway brake stays at 10 even in unattended-sprint mode.

#### Env vars

| Variable                     | Default            | Flag                          | Notes                                                                                            |
|------------------------------|--------------------|-------------------------------|--------------------------------------------------------------------------------------------------|
| `COORDINATOR_CMD`            | `claude`           | —                             | `claude`, `gemini`, `codex`, or any custom CLI                                                    |
| `COORDINATOR_MODEL`          | backend-dependent  | —                             | Passed to Claude, Gemini, or Codex when set. Codex otherwise uses the CLI-configured default.      |
| `COORDINATOR_VERBOSE`        | `0`                | —                             | When `1` and using gemini: swaps `-p` for `-i` (`--prompt-interactive`) so tool calls are visible live in the pane. Agent stays alive — exit with `/quit`. claude is unaffected (its `-p` already streams). |
| `COORDINATOR_HEADLESS`       | `0`                | —                             | When `1` and using claude: run one-shot (`-p`, exits after each prompt) like codex, instead of the default resident interactive REPL. |
| `COORDINATOR_USE_API_KEY`    | `0`                | —                             | When `1` and using claude: keeps `ANTHROPIC_API_KEY` in the agent's env (bills the API account). Default strips it so Claude Max OAuth is used. |
| `NON_INTERACTIVE`            | `0`                | —                             | When `1`, skip auto-attach (used by tests)                                                       |
| `WATCH`                      | `1`                | `-w`, `--watch`               | On by default: spawns `coordinator-watch.sh` as a second pane in the `util` window. Set `0` to disable. |
| `STATUS`                     | `0`                | `--status`                    | When `1`, spawn `gh-status-bar.sh` in a dedicated `status` window                                |
| `MAX_WORKERS`                | `5`                | `--max-workers N`             | Concurrent worker tmux windows the coordinator may have alive at once. `provision-worker.sh` enforces server-side (exit 3 on cap). |
| `MAX_TMUX_WINDOWS`           | `10`               | `--max-windows N`             | Hard cap on total tmux windows in the session — counts `coordinator` + `util` (always present; hosts the watcher as a second pane by default) + optional `status` + alive workers + leftover finished worker windows. |
| `TARGET_AVAILABLE`           | `10`               | `--target-available N`        | Backlog target. Housekeeping creates new issues when AVAILABLE drops below this — NOT when raw open count is low. |
| `OWNER_LABELS`               | empty              | `--owner-labels L1,L2`        | Comma-separated label names treated as "human-owned" (e.g. `sean,radesh`). The coordinator skips issues bearing any owner-label that isn't `@me`. |
| `INCLUDE_ASSIGNED_TO_OTHERS` | `0`                | `--include-others`            | `1` = drop the `@me`-or-unassigned filter. Free-text override in the prompt (`"grab anything"`, `"include others"`) also engages this for one-shot use. |

The cap/filter rows (last seven) are **also** loadable from `<project>/.swarm/.env` (durable per-project) and `<sandbox>/.env.example` (shipped defaults). Full precedence: flag > shell env > project file > sandbox defaults. See [README → Configuring caps and filters](../README.md#configuring-caps-and-filters) for the per-project setup recipe.

#### Auto-discovery

- **`GEMINI_API_KEY`**: when not in environment, walks `$PWD/.env` → `~/.gemini/.env` → `llm-swarm-runner/.env` → `/opt/work/sysadmin/.env` and sources the first match. Propagated into the tmux session env via `tmux new-session -e` so the coordinator pane inherits it without a per-project `.env` copy.
- **Claude OAuth**: just works via the mounted `~/.claude/` config — no env vars needed. If `ANTHROPIC_API_KEY` *is* set, a warning is printed and the variable is stripped from the coordinator's env (override with `COORDINATOR_USE_API_KEY=1` to bill the API instead of the Max plan).

#### Coordinator command construction (claude path)

- The system prompt is injected via `--append-system-prompt "$(cat $SYSTEM_PROMPT_FILE)"` (claude-code's equivalent of gemini's `GEMINI_SYSTEM_MD`).
- `--dangerously-skip-permissions` is passed (matches gemini's `--yolo` semantics for autonomous operation).

### `kill-worktree.sh` — Clean up a worker worktree

Reverse of `provision-worker.sh`. Removes the worktree, deletes the `fix/issue-N` branch, and kills the `iss-N` tmux window if any. Idempotent — warns about missing pieces but never errors.

```bash
kill-worktree.sh <issue-number> [project-dir]
```

Use for ABANDON verdicts from coordinator triage. Uses `--force` on the worktree removal — uncommitted work is lost. The script prints `N commits ahead of <default-branch>, M uncommitted changes` before deletion so you can spot any worktree that has unexpected work.

(issue #181) If `coordinator-watch.sh`'s check-on-done has an acceptance check actively running against the worktree (a `.swarm/tasks/status/<task_id>.check-claim` dir, mkdir'd for the duration of the run), removal is deferred — exit code 75 — rather than yanking the worktree out from under the running check. `kill-finished-workers.sh` and `reap-orphan-worktrees.sh` both recognize this exit code and log it as a deferral, not a failure; the next reap pass retries. A claim older than `CHECK_CLAIM_STALE_SECS` (default: `WORKER_CHECK_TIMEOUT` + 300s) is treated as a crashed check and no longer blocks removal.

### `requeue.sh` — Drop a follow-up brief into a worker's queue

Atomic write into a worker's `.swarm/tasks/inbox/`. Wraps the mktemp+mv pattern so the listener never sees a half-written brief.

```bash
requeue.sh <wt-path|issue-N> <brief-file>     # brief from file
requeue.sh <wt-path|issue-N> -                # brief from stdin
echo "..." | requeue.sh <wt-path|issue-N> -
```

If the first argument is purely numeric, it's resolved to `../wt-issue-<N>` relative to PWD. Otherwise it's a literal path.

After dropping the brief, prints a hint about whether the listener tmux window is alive — so you don't sit waiting for a brief that nothing is polling. If no listener is running, prints the exact `tmux new-window` / `sandbox.sh listener` command to start one.

Use for PARTIAL or NEEDS_REVIEW verdicts where a follow-up surgical brief is the right next step.

### `provision-worker.sh` — One-call worker dispatch

Coordinator helper that creates a worktree, initializes the v2 queue, embeds `.swarm-policy.md` guardrails into the brief, atomic-writes the task, and spawns the worker tmux window — all in a single command call.

```bash
provision-worker.sh <issue-number> [project-dir]
provision-worker.sh --help        # config, cap enforcement, events log
```

#### Why this exists

The coordinator's tool layer (gemini's `run_shell_command`, claude's Bash tool in some configs) **blocks `$(...)` command substitution** as a safety guardrail. The earlier inline-heredoc pattern in `prompts/coordinator.md`:

```bash
cat > $WT/.swarm/tasks/inbox/$TASK_ID.md <<EOF
$(cat .swarm-policy.md)
$(gh issue view $ISSUE)
EOF
```

…can't run under that guardrail. By moving the multi-step pipeline into a script, the coordinator just runs `provision-worker.sh 142` — no `$()` at the coordinator's tool layer; the script's internal `$()`'s execute in a normal bash subshell.

#### Idempotent

Re-running for the same issue is safe:
- Worktree exists → reuses (no error)
- tmux window exists → reuses, listener picks up the new task
- New task gets a fresh `<timestamp>-<issue>` id, so listener processes it as a follow-up

### `setup.sh` — Host-side post-install setup

Idempotent script that fixes one known host-side issue: the npm-published `@google/gemini-cli` package omits its bundled ripgrep binary, but gemini's runtime still probes for it at `<pkg>/bundle/vendor/ripgrep/rg-<plat>-<arch>` and logs `Ripgrep is not available. Falling back to GrepTool.` when missing. `setup.sh` symlinks the system's `/usr/bin/rg` into the path gemini expects.

Run once after install, and again after any `npm i -g @google/gemini-cli` upgrade. The Dockerfile applies the equivalent fix at image-build time, so workers don't need this.

### `.swarm-policy.md` — Per-project rules-of-engagement (optional)

Drop a `.swarm-policy.md` file at the root of any project to give the coordinator binding constraints for *that project's* workers. The coordinator reads it on every wake and embeds the contents verbatim at the top of every worker's task brief under a `## Project Guardrails (MUST OBEY)` header.

Free-form markdown — typical contents include:
- PR rules (`workers may only push branches`, `PR titles must include [swarm]`, etc.)
- File-modification denylist (`do not touch Dockerfile / flyway/** / secrets/** / .env*`)
- Tool-use denylist (`no gradle *release*`, `no kubectl/terraform/aws`, `no DB migrations`)
- Concurrency caps (`max 1 active worker per worktree`)
- Communication rules (`stop and ask in pane on real ambiguity, don't guess`)

A starter is in [`examples/swarm-policy.md.example`](../examples/swarm-policy.md.example) — copy to your project root, edit, commit. Per-project means your monorepo can have stricter rules than your scratch repo.

If the file is absent, the coordinator omits the Guardrails section entirely (no fabricated rules).

### OpenBrain MCP integration

Claude and Gemini coordinators/workers can talk to a local **OpenBrain** MCP server (knowledge graph at `http://127.0.0.1:8100`) via Model Context Protocol. Codex has the same config mount and host-network reachability, but still needs its MCP entry configured before it has parity. OpenBrain gives configured agents persistent memory tools across invocations:

| MCP tool | What it does |
|---|---|
| `capture_thought` | Save a new thought with auto-extracted metadata + embeddings |
| `list_thoughts` | Retrieve recent thoughts, filter by type/topic/person |
| `search_thoughts` | Semantic search across captured thoughts |
| `thought_stats` | Summary stats — totals, top topics |

#### How it's wired

| Where | Config | Mounted into worker container? |
|---|---|---|
| **Claude** (host coordinator) | `~/.claude.json` → `mcpServers.open-brain` (already present) | yes — `~/.claude.json` rw-mounted into sandbox |
| **Claude** (workers in docker) | inherited via the mount | yes |
| **Gemini** (host coordinator) | `~/.gemini/settings.json` → `mcpServers.open-brain` (added `gemini mcp add open-brain ... -s user -t http --trust`) | yes when present |
| **Gemini** (workers in docker) | inherited via mount | yes — `~/.gemini` ro-mounted into sandbox if it exists |
| **Codex** (host coordinator) | `~/.codex/config.toml` → MCP entry not configured yet | yes — `~/.codex` rw-mounted into sandbox |
| **Codex** (workers in docker) | inherited via mount after configuration | yes |

Workers reach `http://127.0.0.1:8100` because `sandbox.sh` runs containers with `--network host`, so the container's loopback IS the host's.

#### Setup checklist

```bash
# 1. OpenBrain server running on host (systemd unit at /opt/openbrain/openbrain.service)
ss -tln | grep ':8100 '

# 2. Claude already configured? (one-time, already done on this host)
jq '.mcpServers."open-brain"' ~/.claude.json

# 3. Gemini already configured? (added this session)
jq '.mcpServers."open-brain"' ~/.gemini/settings.json

# 4. To re-add gemini config from scratch:
KEY=<openbrain-key>
gemini mcp add open-brain "http://127.0.0.1:8100?key=$KEY" \
    -s user -t http --trust \
    --description "OpenBrain knowledge graph (local)"

# 5. Verify gemini sees it:
gemini --yolo --skip-trust -p 'List the MCP servers you have access to.'
```

#### Security note

The MCP key is embedded in the URL query string in both `~/.claude.json` and `~/.gemini/settings.json`. Both files are `chmod 600`-equivalent (owned by user, not world-readable), but anyone with read access to your home dir can extract the key. OpenBrain itself is bound to `0.0.0.0:8100` — verify you're behind a host firewall before treating that key as "local-only".

### `coordinator-watch.sh` — Event-driven coordinator wake-ups

Long-running daemon that watches every worker's `.swarm/tasks/done/` directory under a project. When a new outcome JSON appears (i.e. a worker finished a task), wakes the coordinator via `llm-start.sh` so it can triage / re-dispatch / merge / etc. It also watches every worker's `.swarm/tasks/outbox/` (`WATCH_OUTBOX`, default on — issue #129): a message file a worker drops there wakes the coordinator with a message-triage prompt (`OUTBOX_WAKE_PROMPT` to override), giving workers a mid-task channel to the coordinator without any tmux access. Together with the queued protocol, this delivers the **event-driven coordinator** option from the README's "Automating the loop" section without rewriting the agent itself.

```bash
# default — watches $PWD, debounces 30s, blocks on Ctrl-C
coordinator-watch.sh

# config, env vars, event categories
coordinator-watch.sh --help

# in another project
coordinator-watch.sh /opt/work/myproject

# preview without actually waking the coordinator
DRY_RUN=1 coordinator-watch.sh

# exit after the first wake (useful for testing)
ONCE=1 coordinator-watch.sh
```

**Backends (auto-detected):**

| Backend | Latency | Setup |
|---|---|---|
| `inotifywait` (preferred) | instant | `sudo apt install inotify-tools` (and bump `fs.inotify.max_user_watches` for large repos) |
| polling `find` (fallback) | `POLL_SECS=2` (default) | none — works out of the box |

**Env vars:**

| Var | Default | Notes |
|---|---|---|
| `DEBOUNCE_SECS` | `30` | Coalesce N events into 1 wake when many workers finish near-simultaneously |
| `DRY_RUN` | `0` | Log triggers without invoking llm-start.sh |
| `ONCE` | `0` | Exit after first wake — for smoke-tests |
| `LLM_START` | `$LLM_SWARM_DIR/llm-start.sh` | Override path |
| `WAKE_PROMPT` | (top-up prompt — see below) | What the coordinator does when woken |
| `POLL_SECS` | `2` | Polling interval (polling backend only) |
| `POST_OUTCOMES` | `0` | Set to `1` to also run `sweep-swarm-outcomes.sh` on each detected outcome. Honors `$OUTCOME_HOOK`. Fires outside the wake-debounce window so every outcome gets audit coverage even when wakes are coalesced. |
| `SWEEP` | `$LLM_SWARM_DIR/scripts/sweep-swarm-outcomes.sh` | Override sweep path |
| `WATCHER_AUTOCLOSE` | `1` | Before each coordinator wake, reap finalized workers (window + worktree + local branch) via `kill-finished-workers.sh --with-worktree --yes` plus a PR-state flag from `WATCHER_AUTOCLOSE_MODE`. `0` disables all auto-reaping, including the poll and orphan-sweep timers below. |
| `WATCHER_AUTOCLOSE_MODE` | `merged` | (issue #237) Which terminal PR states are reap-eligible. `merged` (default): only a MERGED PR is reaped; a CLOSED-without-merge PR is left untouched (window, worktree, branch) for operator inspection. `finalized`: MERGED *or* CLOSED is reap-eligible (the pre-#237 behavior) — the branch survives a CLOSED reap via `kill-worktree.sh`, recoverable with `gh pr reopen N`. |
| `WATCH_PR_POLL_SECS` | `60` | (issue #119) Background timer that polls `gh pr list --state all` across all worker branches and re-fires the `WATCHER_AUTOCLOSE` reap pass for any worktree whose PR went MERGED/CLOSED since the last outcome-driven check (catches PRs merged later, e.g. a parked interactive worker). Also powers the `WATCH_CHECK_ON_DONE` PR-open backstop. `0` disables (falls back to outcome-only detection). |
| `WATCH_ORPHAN_SWEEP_SECS` | `3600` | (issue #225) Slower independent timer that runs `reap-orphan-worktrees.sh --pr-finalized --yes` to clear worktrees whose tmux window is already gone but the directory + branch survive with a finalized PR — the case `WATCH_PR_POLL_SECS`'s window-based reap can't reach. Gated by `WATCHER_AUTOCLOSE`; `0` disables just this sweep. |
| `WATCH_CHECK_ON_DONE` | `1` | Runs the project's acceptance check in a visible `chk-N` tmux window the moment a worker signals done (a `status/<id>.json` with `state: ready-for-review`, or a PR appearing with no status file, via the `WATCH_PR_POLL_SECS` backstop). Records the result to `<id>.check.json` and `events.log`; skipped (state=skipped) if the PR is already MERGED/CLOSED by the time the check claim is won. `0` disables. |
| `AUTO_COMPACT` | `1` | Before waking a long-lived coordinator, injects a real `/compact` into the coordinator pane if it's at/above `AUTO_COMPACT_THRESHOLD_TOKENS`. Requires `scripts/statusline-with-context.sh` installed as the coordinator's statusLine (no probe file = no-op). `0` disables. See [advanced-usage.md § Compact discipline](./advanced-usage.md#compact-discipline). |
| `AUTO_COMPACT_THRESHOLD_TOKENS` | `150000` | Used-token threshold that triggers `AUTO_COMPACT`. |
| `AUTO_COMPACT_TICK_SECS` | `60` | (issue #210) Independent poll-tick trigger so a coordinator that never reaches a wake (pure interactive use) still gets auto-compacted. `0` disables just this trigger. |
| `WORKER_AUTO_COMPACT` | `1` | (issue #226) Same pattern generalized to every `iss-*` worker window — injects `/compact` (via rendered statusline text, not a probe file) into idle over-threshold workers, then nudges them to continue. `0` disables. See [advanced-usage.md § Worker auto-compact](./advanced-usage.md#worker-auto-compact). |
| `WORKER_COMPACT_SCAN_SECS` | `30` | Sweep interval for `WORKER_AUTO_COMPACT`. |
| `WORKER_COMPACT_THRESHOLD_TOKENS` | `150000` | Used-token threshold for `WORKER_AUTO_COMPACT` (raised to `WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS`, default `300000`, once a worker has an open PR). |

The full knob list — including all `AUTO_COMPACT_*` / `WORKER_COMPACT_*` timeouts, `WATCHER_QUIET`, `CHECK_RUNNER`, and `SESSION_NAME` — is documented in `coordinator-watch.sh`'s own header comment; the rows above cover the behavior-changing defaults worth knowing before your first unattended run.

The watcher also reads `MAX_WORKERS` / `MAX_TMUX_WINDOWS` / `TARGET_AVAILABLE` / `OWNER_LABELS` / `INCLUDE_ASSIGNED_TO_OTHERS` from the same precedence chain (shell env > project `.swarm/.env` > sandbox `.env.example`). It uses them in two places: (a) the startup `watch.start` event line, and (b) implicitly via the wake prompt referencing the caps so the coordinator computes slots correctly.

**Default wake prompt (top-up mode):** *"Triage outcome JSONs … then top up workers per the Initial Startup Checklist (compute AVAILABLE, count alive workers, fill open slots up to `MAX_WORKERS` subject to `MAX_TMUX_WINDOWS`). Use the @me-or-unassigned filter unless `INCLUDE_ASSIGNED_TO_OTHERS=1`."* This means the swarm self-replenishes without the user having to re-issue `llm-start.sh "provision more workers"` between worker generations.

**Anti-runaway brakes** are layered:
1. `provision-worker.sh` enforces `MAX_WORKERS` and `MAX_TMUX_WINDOWS` server-side (exit 3, refuses to spawn).
2. `DEBOUNCE_SECS` (default 30s) coalesces back-to-back finishes into a single coordinator wake.
3. The coordinator system prompt tells the LLM to compute `slots = min(MAX_WORKERS - alive, MAX_TMUX_WINDOWS - total_windows)` and stop when ≤ 0.

To revert to the old conservative behavior ("triage only, don't dispatch"), set `WAKE_PROMPT` explicitly to your own text.

**Events log:** the watcher and `provision-worker.sh` both append structured event lines to `<project>/.swarm/events.log` (`watch.start`, `worker.start`, `worker.finish`, `coord.wake`, `cap.refused`, etc.). `tail -F` it for live status.

`WATCHER_AUTOCLOSE` reap passes add two more: `watch.autoclose` (one line per pass — `trigger=outcome|pr_poll mode=<WATCHER_AUTOCLOSE_MODE>+worktree dry_run=<0|1> killed=<n>`) and, per-target, `reap.window` from `kill-finished-workers.sh` itself (`issue=N window=iss-N branch=... reasons=... with_worktree=1 capture=<path>`). Every real (non-dry-run) kill snapshots the pane's last `REAP_CAPTURE_LINES` (default 500) scrollback lines to `<project>/.swarm/reaped/iss-N-<utc>.txt` *before* the window dies — that `capture=` path (or `capture=failed` if the window died mid-snapshot) is the only surviving record of what happened in a reaped window's pane.

**Combined audit + wake (recommended for unattended runs):**

```bash
POST_OUTCOMES=1 \
OUTCOME_HOOK=/opt/work/myproject/scripts/post-swarm-outcome.sh \
    coordinator-watch.sh /opt/work/myproject
```

This single supervisor process watches `done/*.json` events, posts the audit comment via your hook, and wakes the coordinator. Posting fires for every outcome (idempotent via `.posted` markers); wakes are coalesced via `DEBOUNCE_SECS`. Survives across coordinator one-shot invocations.

### `sweep-swarm-outcomes.sh` — Audit-trail post-processing

Iterates worker-finished outcome JSONs across all sibling worktrees of a project and invokes a user-configured posting hook for each one. Idempotent via `<outcome>.posted` markers — re-runs only post new outcomes.

The intended use case: at end-of-session (or after a coordinator-wake triage) you want every finished worker's outcome surfaced as a comment on the corresponding GitHub issue. The poster itself is **not** built into this repo because the comment format / target system is project-specific. Provide it via the `OUTCOME_HOOK` env-var.

```bash
# Default hook — dry-run, prints what it would post (safe to try)
sweep-swarm-outcomes.sh /opt/work/myproject

# Real use — point at your project's poster
OUTCOME_HOOK=/opt/work/myproject/scripts/post-swarm-outcome.sh \
    sweep-swarm-outcomes.sh /opt/work/myproject

# Force re-post (e.g., after editing the hook to format differently)
SWEEP_FORCE=1 OUTCOME_HOOK=... sweep-swarm-outcomes.sh /opt/work/myproject
```

**Hook contract:**

The hook receives 2 args:
1. `<worktree-path>` — e.g., `/opt/work/myproject/../wt-issue-142`. The hook can derive the issue number from `basename` (matches `wt-issue-N`).
2. `<outcome-json-path>` — full path to the `<task_id>.{ok,err}.json` file. Parse with `jq` for `task_id`, `outcome`, `exit_code`, `duration_seconds`, etc.

Hook exit `0` = success → sweep writes the `.posted` marker. Non-zero = retry on next sweep, no marker.

**Why a hook instead of built-in `gh issue comment`:**

- Comment format is opinionated: PR link? Test results? Triage verdict? Each project differs.
- Audit destination varies — could be Slack, Linear, an internal dashboard, not just GitHub.
- Keeps `llm-swarm-runner` agnostic about how a project tracks work.

**Why a sweep instead of automatic post-on-worker-exit:**

- Post-on-exit would need `gh` auth from inside the worker container — extra coupling.
- Sweep gives you a chance to inspect outcomes before they're broadcast (especially `.err.json` cases).
- Re-runnable: idempotent markers mean you can safely re-sweep after fixing a bad hook.

If you want post-on-exit despite the trade-offs, layer it: have `coordinator-watch.sh`'s wake-prompt also invoke `sweep-swarm-outcomes.sh`, or add a `WORKER_POST_HOOK` env-var to `worker-listener.sh` (not built today).

### `coordinator-error-tail.sh` — Surface gemini API errors in the pane

Called automatically by `llm-start.sh` immediately after every gemini invocation. Checks for `/tmp/gemini-*-error-*.json` files modified in the last minute and decodes the nested `.error.message` (gemini's API errors are double-encoded JSON) into the pane.

Without this, gemini-cli truncates server-side errors to `Operation cancelled.[ERROR] Operation cancelled.` while writing the real cause to `/tmp` — users had to know to check there. With it, the actual error (e.g., `INVALID_ARGUMENT: Please ensure that function response turn comes immediately after a function call turn.`) is visible in the same pane.

No-op for the claude path: claude's `-p` already streams errors and tool calls directly.

### `worker-listener.sh` — Queue watcher for worker agents

Runs inside the worker sandbox. In **interactive mode** (default), between tasks the pane drops to a real `bash -i` idle shell — a background subshell polls the inbox every 2 seconds (`poll_for_brief`, worker-listener.sh:470-481) and a `PROMPT_COMMAND` hook re-launches the agent once a new brief lands and the operator's prompt redraws (`run_idle_shell`, worker-listener.sh:483-515). This means an untouched idle prompt won't pick up a queued brief until Enter is pressed. In **`WORKER_HEADLESS=1`** mode there's no prompt to redraw, so the listener falls back to a silent `sleep 2` poll loop (worker-listener.sh:653-654) between tasks. Two protocols supported:

**v2 queue (preferred)** — per-worktree directory tree:

```
<worktree>/.swarm/tasks/
  inbox/        coordinator writes <id>.md here (atomic mktemp+mv)
  processing/   listener mv on pickup (atomic claim — wins race if multiple listeners)
  done/         listener mv when finished + writes <id>.{ok,err}.json
  status/       worker writes <id>.json here mid-task (atomic mktemp+mv) to
                declare state while still parked and attachable
  outbox/       worker writes <ts>-<slug>.md message files here (atomic
                mktemp+mv; temp name must not end .md) — fyi /
                decision-needed / brief-draft; coordinator-watch.sh wakes
                the coordinator on arrival (issue #129); handled messages
                are archived to outbox/processed/
```

`done/<id>.{ok,err}.json` is a structured outcome record the coordinator can poll without scraping the pane:

```json
{
  "task_id": "20260504-031415-1234",
  "started":  "2026-05-04T03:14:15Z",
  "finished": "2026-05-04T03:18:42Z",
  "duration_seconds": 267,
  "exit_code": 0,
  "outcome": "ok",
  "agent": "claude",
  "model": "claude-sonnet-5",
  "headless": false,
  "check_cmd": "./gradlew test",
  "check_exit": 0,
  "check_output_tail": "BUILD SUCCESSFUL in 41s\n",
  "retried": false
}
```

The `check_*` fields are the **executed acceptance check** (concept adopted from ringer — see [`ringer-adoptions.md`](ringer-adoptions.md)): after the agent exits, the listener runs a per-issue check command and a task is `outcome: ok` only when both the agent exit code *and* the check exit code are 0. All three fields are `null` when no check is configured (resolution order: `<!-- SWARM_CHECK: <cmd> -->` marker in the brief → `.swarm/check.sh` in the worktree → `WORKER_CHECK_CMD` env). Full check output is archived at `done/<id>.check.log`. On check failure the listener re-dispatches the agent **once** with the failure output injected into the prompt and re-runs the check (`retried: true`; first attempt's output kept at `done/<id>.check.attempt1.log`; disable with `WORKER_CHECK_RETRY=0`).

`status/<id>.json` is the worker's own hand-off signal — written by
the worker (not the listener) immediately after opening a PR, or on
reaching a terminal no-PR state (`blocked`, `done-no-pr`), so the
watcher can react while the worker is still parked and attachable
rather than waiting on a `gh pr list` poll. Schema:
`{"task_id", "state": "ready-for-review"|"blocked"|"done-no-pr", "pr", "ts", "note"}`.
See "Worker status file" in [`prompts/worker.md`](../prompts/worker.md)
for the full convention. It started as a convention with no consumer —
the first standardized message type in the worker→coordinator hand-off
explored in
[issue #129](https://github.com/seanoc5/llm-swarm-runner/issues/129) —
but `coordinator-watch.sh` now actively reads it: its check-on-done pass
(issue #181) scans every worktree's `status/*.json` for state
`"ready-for-review"` and fires the acceptance check
(`coordinator-watch.sh:1351-1367`), and the same directory also carries
the check-claim coordination files (`kill-worktree.sh`'s deferred-removal
handling, see its own section above).

**v1 single-file (legacy, still supported)** — `.agent-task.md` → `.agent-task-last.md`. No structured outcome.

The listener checks v2 inbox first, falls back to v1. Both can be in use simultaneously (mid-migration). New work should use v2.

#### Listener loop, per task:

1. **Claim** via atomic `mv` (v2) or rename (v1).
2. **Echo brief** (first 40 lines) to the pane so attached observers see what's running.
3. **Dispatch** the configured agent (default claude, override via `WORKER_CMD`; claude workers default to `claude-sonnet-5`, gemini/codex use their CLI's default model — override via `WORKER_MODEL`).
4. **Check** (v2 only) — resolve and run the acceptance check, if one is configured; capture exit code + output tail.
5. **Archive + record** — move brief to `done/` (v2) or `.agent-task-last.md` (v1); for v2 also write `done/<id>.{ok,err}.json` with timing, agent exit code, and check result.
6. **Loop** back for the next task — interactively via the idle shell described above, headless via the silent poll loop.

#### Worker mode

| Mode                  | Agent flags                                | Lifecycle                                                                                                  |
|-----------------------|--------------------------------------------|------------------------------------------------------------------------------------------------------------|
| **interactive** (default) | `claude "$TASK"` / `gemini -i "$TASK"` | Runs prompt + tools, drops to REPL. User attaches to interact / answer questions / `/quit` when done.       |
| **headless** (`WORKER_HEADLESS=1`) | `claude -p "$TASK"` / `gemini -p "$TASK"` / `codex exec "$TASK"` | Prints output and exits. Skips claude's "Trust this folder?" dialog. Used by e2e tests and any automation. |

#### Worker env vars (threaded through `caller → llm-start.sh → tmux session env → sandbox.sh -e → container env`)

| Variable              | Default          | Notes                                                                                       |
|-----------------------|------------------|---------------------------------------------------------------------------------------------|
| `WORKER_CMD`          | `claude`         | Switches the worker's LLM CLI (`gemini` or `codex` are supported alternatives).             |
| `WORKER_MODEL`        | `claude-sonnet-5` (claude); CLI default (gemini/codex) | Passed as `--model` (claude) or `-m` (gemini/codex). E.g. `sonnet`, `gemini-2.5-flash`. |
| `WORKER_HEADLESS`     | `0`              | When `1`, run agent with `-p` (print + exit). Required when no human is attached.           |
| `WORKER_CHECK`        | `1`              | Executed acceptance checks. `0` disables (outcome JSON reverts to agent-exit-only).         |
| `WORKER_CHECK_CMD`    | (none)           | Listener-wide default check command (e.g. the project test suite). Brief marker / `.swarm/check.sh` take precedence. |
| `WORKER_CHECK_TIMEOUT`| `600`            | Seconds before the check is killed (`timeout`; exit 124 recorded as a failure).             |
| `WORKER_CHECK_RETRY`  | `1`              | Retry-once on check failure with the failure output injected into the prompt. `0` disables. |
| `SWARM_EVAL_LOG`      | `.swarm/eval-log.jsonl` | Where the listener appends one JSONL eval row per completed v2 task. Point outside the worktree to survive reaping / pool across workers. |

This decouples the coordinator from the workers: the coordinator just drops a markdown file into the worktree and the worker picks it up asynchronously.

### `swarm-scoreboard.sh` — Per-(agent, model) eval scoreboard

Aggregates the JSONL eval rows the listener appends per completed task (`.swarm/eval-log.jsonl` per worktree, or `$SWARM_EVAL_LOG`) into a per-(agent, model) table: tasks, pass rate, **first-try pass rate** (passed without the retry-once firing), retries, checked count, average duration. Concept adopted from ringer's model log + scoreboard (see [`ringer-adoptions.md`](ringer-adoptions.md) #3) — it makes model-default choices (e.g. Sonnet 5 for workers) empirically checkable.

```bash
swarm-scoreboard.sh                       # glob CWD + sibling wt-issue-* worktrees
swarm-scoreboard.sh /opt/work/myproject   # same, from a project root
swarm-scoreboard.sh --json logs/*.jsonl   # raw aggregation for scripts
```

### `prompts/coordinator.md` — Coordinator's brain

Defines the coordinator's Initial Startup Checklist, run sequentially on every wake:

1. **Project guardrails** — `cat .swarm-policy.md` if present (binding constraints on every worker it provisions).
2. **Worker guidance roadmap** — count entries in `docs/worker-guidance-roadmap.md` if present; report the count, never auto-file one as an issue.
3. **Local state** — `git status`, `git branch`, `git worktree list`, `tmux list-windows`; note alive-worker count (`iss-*` windows) and total window count.
4. **Config from env** — `MAX_WORKERS` (default 5), `MAX_TMUX_WINDOWS` (10), `TARGET_AVAILABLE` (10), `OWNER_LABELS`, `INCLUDE_ASSIGNED_TO_OTHERS`, loaded by `llm-start.sh` from `.env.example` + `<project>/.swarm/.env`.
5. **Remote state** — `gh pr list`, then compute **AVAILABLE** (mechanical filters via `scripts/available-issues.sh`, plus LLM judgment filters for tracking issues, policy-blocked work, and issues with a PR already linked). Report `OPEN=N AVAILABLE=M ALIVE=A/$MAX_WORKERS WINDOWS=W/$MAX_TMUX_WINDOWS`.
6. **Housekeeping** — if `AVAILABLE < TARGET_AVAILABLE`, file new issues to fill the gap (per the "Issue skeleton" format in `prompts/worker.md`).
7. **Provisioning** — compute `slots = min(MAX_WORKERS - alive_workers, MAX_TMUX_WINDOWS - total_windows)`, then route up to `slots` AVAILABLE issues through `provision-worker.sh` (the script re-enforces both caps server-side, exit 3 on cap hit):

```bash
$LLM_SWARM_DIR/scripts/provision-worker.sh 42
```

`provision-worker.sh` itself handles worktree creation (`../wt-issue-42`, branch `fix/issue-42`, idempotent), queue init (`.swarm/tasks/{inbox,processing,done}/`), `.swarm-policy.md` embedding, issue-body append, atomic brief write, and the `tmux new-window -d` spawn (background, so it doesn't steal focus) — the coordinator never assembles these steps by hand.

### Other scripts — see [`scripts/README.md`](../scripts/README.md)

The sections above cover the scripts most of the flows in this document depend on directly; `scripts/` ships more tooling than fits here. Notable ones the described flows also rely on:

- **Reaping trio** — `kill-finished-workers.sh` (closes tmux windows for workers whose PR reached a terminal state; invoked by `coordinator-watch.sh`'s autoclose pass and by the coordinator's JIT-reap step), `reap-orphan-worktrees.sh` (removes worktrees whose work is preserved elsewhere), `check-stuck-workers.sh` (flags workers idle past a threshold).
- `available-issues.sh` — computes the `AVAILABLE` backlog count the coordinator's startup checklist and `TARGET_AVAILABLE` housekeeping use.
- **Review/merge helpers** — `swarm-merge.sh`, `self-review-pr.sh`, `review-scoreboard.sh`, `lint-brief.sh`, `stale-pr-nudges.sh`.
- `list-swarms.sh`, `sandbox-worktrees.sh`, `gh-status-bar.sh`, `coordinator-claude.sh` / `coordinator-codex.sh`.

`scripts/README.md` is the maintained one-line-per-script index — consult it for the complete, current list rather than this document.

The five suites documented below are a representative sample, not the full list — `scripts/run-all-tests.sh` runs every `tests/test-*.sh` suite (~20 as of this writing) under a per-suite timeout and prints a PASS/FAIL/TIMEOUT summary; see [`scripts/README.md`](../scripts/README.md) for the complete index.

### `test-shape-swarm.sh` — Non-LLM shape test for the queue protocol

Deterministic regression coverage for `worker-listener.sh` that doesn't burn LLM tokens or require auth. Uses the listener's `bash` fallback agent (executed when AGENT is none of `claude`, `gemini`, or `codex` — codex has its own dedicated dispatch branch, worker-listener.sh:252-257) to make task briefs runnable shell commands; assertions then check files produced by those briefs.

Covers:
- v2 happy path: atomic-write to `inbox/`, brief archives to `done/`, `.ok.json` written with full schema validation
- v2 failure path: non-zero exit produces `.err.json` with the right `exit_code` and `outcome`
- v1 legacy: `.agent-task.md` → `.agent-task-last.md`, no spurious JSON
- Lex ordering: 3 v2 tasks processed in queue order
- `.tmp.*` exclusion: in-flight atomic-write filenames must not be claimed

Runs in seconds. Pair with `test-e2e-swarm.sh` for full claude/gemini path coverage when you have auth + want to validate the LLM end too. Use `KEEP=1` to retain the temp dir for inspection.

### `test-shape-helpers.sh` — Non-LLM shape test for triage helpers

Deterministic coverage for `requeue.sh` and `kill-worktree.sh` — the two destructive/critical helpers in the triage workflow. Sets up a fixture git repo + worktree on issue #99, then exercises both scripts across their main paths.

Covers:
- `requeue.sh`: numeric-issue arg vs path arg, stdin brief vs file brief, missing-worktree error, missing-brief-file error, no `.tmp.*` leaks on failure
- `kill-worktree.sh`: worktree+branch removal, `Worktree state: N commit(s) ahead, M uncommitted` reporting, idempotent re-runs on missing pieces

Runs in seconds. No LLM, no tmux, no network. Use `KEEP=1` to retain the temp dir for inspection.

### `test-shape-orchestration.sh` — Non-LLM shape test for provision/watch/list

Deterministic coverage for the three orchestration helpers that don't slot into the worker-listener or triage-helper buckets:

- `provision-worker.sh`: worktree+branch+queue creation, brief assembly with `gh issue view` body, `.swarm-policy.md` embedding, idempotent re-run
- `coordinator-watch.sh`: polling backend detects a fresh `.ok.json`, would-wake logged in `DRY_RUN` mode, `ONCE=1` exit, missing-project error
- `sandbox-worktrees.sh`: lists worktrees of a multi-worktree repo, errors on non-git, errors on `-t` outside a tmux session

Stubs `gh` and `tmux` via `PATH` override so no GitHub auth and no live tmux server are needed. Watch test runs `DRY_RUN=1 ONCE=1 POLL_SECS=1` so it never invokes a real `llm-start.sh`. Total runtime ~10s.

### `test-watcher-autoclose.sh` — Non-LLM shape test for WATCHER_AUTOCLOSE

Deterministic coverage for the `coordinator-watch.sh` autoclose pass (issue #32) — the per-outcome invocation of `kill-finished-workers.sh` that frees slots when a worker's PR has reached a terminal state. Stubs both `kill-finished-workers.sh` (via `KILL_FINISHED=`) and `llm-start.sh` (via `LLM_START=`) so we can assert what was called, with what argv, in what order — no tmux, no `gh`, no real worktree.

Covers:
- `WATCHER_AUTOCLOSE=1` (default): `kill-finished-workers.sh` is invoked **before** `coord.wake`, with `--with-worktree --yes` plus a PR-state flag from `WATCHER_AUTOCLOSE_MODE` — `--merged-only` by default, or `--pr-finalized` when `WATCHER_AUTOCLOSE_MODE=finalized` (issue #237).
- `WATCHER_AUTOCLOSE=0`: stub is **not** invoked; `coord.wake` still fires.
- Sequential outcomes: each `.ok.json` arrival triggers its own autoclose+wake pair (smooth-flow contract).
- `.err.json` parity: error outcomes trigger autoclose+wake too (covers worker abort, `/quit`, etc.).
- `events.log` records `watch.autoclose` and `coord.wake` lines per outcome.

Runs in ~10s. Use `KEEP=1` to retain the temp dir for inspection.

### `test-e2e-swarm.sh` — Local end-to-end test (with real LLM)

Spins up `/tmp/swarm-e2e-<epoch>/main-repo` as a fresh git repo, copies the project's `.env` (so the coordinator inherits `GEMINI_API_KEY`), and invokes `llm-start.sh` with a hardcoded prompt that asks the coordinator to:

1. Create two worktrees (`../wt-alpha`, `../wt-beta`).
2. Spawn a worker listener in each via `tmux new-window`.
3. Drop `.agent-task.md` in each instructing the worker to write `alpha-success.txt` / `beta-success.txt`.

Then polls those marker files for up to 90 seconds, with stuck-detection (kills the session if the coordinator pane stops changing for 60s) and error detection (`grep -iE 'error|exception|missing API key|...'`).

Set `KEEP_ALIVE=1` to leave the tmux session running on success/timeout for inspection.

The test uses your Claude Max plan by default. `COORDINATOR_CMD=gemini ./tests/test-e2e-swarm.sh` runs the same flow against the Gemini free tier — useful when burning fewer Max-plan tokens matters more than ensuring claude-path coverage.

## End-to-End Flow (Real Use)

1. `cd /opt/work/myproject`
2. `./llm-start.sh` (or `COORDINATOR_CMD=gemini ./llm-start.sh` to use Gemini instead of Claude Max).
3. Coordinator wakes, runs `gh issue list`, picks unassigned issues, provisions worktrees + worker windows.
4. Workers pick up the brief from `.swarm/tasks/inbox/` (v2 queue, written by `provision-worker.sh`), do the work, push a branch, open a PR via `gh`, and record a structured outcome in `.swarm/tasks/done/`.
5. You attach with `tmux -L swarm-myproject a -t llm-myproject` to watch / intervene (or run `scripts/list-swarms.sh` for a ready-to-paste attach command).

## Coordinator Trade-offs

| Coordinator           | Pros                                                                          | Cons                                                                |
|-----------------------|-------------------------------------------------------------------------------|---------------------------------------------------------------------|
| `gemini` (free tier)  | $0; large context; fast for simple orchestration                              | 20 req/min, 1500/day — burns quickly during multi-agent swarms      |
| `gemini` (paid tier)  | Higher rate limits (~360 req/min); same model strengths                       | Pay-as-you-go API billing                                           |
| `claude` (Max OAuth)  | No per-request billing under Max plan; strong tool use                        | Subject to Max-plan rolling 5-hour usage caps                       |
| `claude` (API key)    | Highest reliability, paid                                                     | Pay-per-token; the script *strips* the API key by default — opt-in  |

## Coordinator Lifecycle

Codex coordination runs one-shot via `codex exec`: each `llm-start.sh` invocation wakes it, the agent reads disk state (`git`, `gh`, worktrees), takes its action, and exits. Claude defaults to a resident interactive REPL so follow-up invocations can land in the same conversation. The watcher remains a separate lightweight process in either case.

The disk *is* the coordinator's memory across invocations: worktrees, branches, open PRs, `.agent-task-last.md` archives. Any new wake re-derives state from that.

## Known Limitations

- ripgrep symlink (host) survives gemini-cli upgrades only if you re-run `setup.sh`. The Dockerfile applies the same fix at image-build time, so workers are immune.

## Reproducible Builds

The `Dockerfile` pins all upstream-version-sensitive tools via `ARG`-driven version strings near the top:

| ARG | Default | Notes |
|---|---|---|
| `NODE_MAJOR` | `22` | Major only — NodeSource ships stable patches inside a major. |
| `CLAUDE_CODE_VERSION` | `2.1.126` | Bump after testing — claude-code minor releases occasionally rename CLI flags. |
| `GEMINI_CLI_VERSION` | `0.40.1` | Bump cautiously — gemini-cli's tool-call protocol has changed across versions. |
| `OPENAI_CODEX_VERSION` | `0.128.0` | Less load-bearing — we don't currently script against it. |
| `PROMPTFOO_VERSION` | `0.121.9` | Same. |
| `DENO_VERSION` | `2.7.14` | Pinned via positional arg to `deno.land/install.sh`. |
| `UV_VERSION` | `0.11.8` | Pinned via direct GitHub release tarball (astral's `install.sh` ignores `UV_VERSION` env, so we bypass it). |

Apt-managed tools (Java, ripgrep, gh, docker-cli) are intentionally NOT pinned to dpkg version strings — too fragile for a personal sandbox. Major versions are still pinned via package selection (`openjdk-21`, `setup_22.x`).

**Upgrade workflow:**
```bash
# Find the current latest of any pinned tool
npm view @anthropic-ai/claude-code version
curl -s https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r .tag_name

# Bump the ARG in Dockerfile, OR override at build time:
docker build --build-arg CLAUDE_CODE_VERSION=2.2.0 -t llm-swarm-runner:latest .

# Test the e2e suite to confirm nothing regressed:
./tests/test-e2e-swarm.sh

# Or run the full deterministic suite (no LLM auth required):
scripts/run-all-tests.sh
```

- `gemini-3-flash-preview` (and possibly other preview models) hit a server-side `400 INVALID_ARGUMENT` on multi-tool-call sequences — which is exactly the coordinator's workload. Stick to `gemini-2.5-flash` (the default) until Google fixes the preview tier.
- ripgrep symlink (host) survives gemini-cli upgrades only if you re-run `setup.sh`. Add to your shell rc or a post-`npm-i` hook if you upgrade often.

## Related Files

- [`./architecture.md`](./architecture.md) — design philosophy, comparison to CrewAI / LangGraph / Composio AO.
- [`./advanced-usage.md`](./advanced-usage.md) — manual worktrees, Testcontainers, custom mounts.
- [`./security.md`](./security.md) — `--yolo`/`--dangerously-skip-permissions` blast radius.
- [`./troubleshooting.md`](./troubleshooting.md) — SSH, `gh` auth, networking issues.
