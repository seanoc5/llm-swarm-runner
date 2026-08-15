# Advanced Usage & Configuration

This document covers advanced workflows, custom mounts, and manual Git worktree setups.

## Contents

- [Git Worktrees](#git-worktrees)
  - [Manual Multi-worktree tmux setup](#manual-multi-worktree-tmux-setup)
  - [Creating worktrees manually](#creating-worktrees-manually)
  - [Worktree layout (SWARM_WORKTREE_GROUPING)](#worktree-layout-swarm_worktree_grouping)
- [Custom Configuration](#custom-configuration)
  - [Per-project Environment (.sandbox-env)](#per-project-environment-sandbox-env)
  - [Extra Mounts](#extra-mounts)
  - [Memory limit (SANDBOX_MEM_LIMIT)](#memory-limit-sandbox_mem_limit)
- [Docker Integrations](#docker-integrations)
  - [Testcontainers / Docker CLI](#testcontainers--docker-cli)
  - [Rebuilding the Image](#rebuilding-the-image)
- [Worker Escape Hatch (Ctrl-Z opens a sibling bash pane)](#worker-escape-hatch-ctrl-z-opens-a-sibling-bash-pane)
- [Peering at Workers from the Host (capture-pane)](#peering-at-workers-from-the-host-capture-pane)
- [Long-lived coordinator: context monitoring](#long-lived-coordinator-context-monitoring)
  - [Worker auto-compact](#worker-auto-compact)
- [Triage Workflow](#triage-workflow)
  - [The triage cycle](#the-triage-cycle)
  - [Read-only triage prompt](#read-only-triage-prompt)
  - [Acting on each verdict](#acting-on-each-verdict)
  - [Reviving listeners after a tmux session is killed](#reviving-listeners-after-a-tmux-session-is-killed)

## Git Worktrees

`sandbox.sh` automatically detects git worktrees. When the project directory is a worktree (its `.git` is a file pointing to the main repo), the script mounts the main repo's `.git/` directory into the container so all git operations work normally.

### Manual Multi-worktree tmux setup

While `llm-start.sh` handles orchestration autonomously, you can manually use `sandbox-worktrees.sh` to list worktrees and optionally create tmux windows and/or launch sandboxes:

```bash
# List all worktrees and their branches
./scripts/sandbox-worktrees.sh /opt/work/myproject

# Launch Claude sandbox in the current shell for this worktree
./scripts/sandbox-worktrees.sh -a claude

# Create tmux windows starting at 7 — one per worktree
./scripts/sandbox-worktrees.sh -t /opt/work/myproject

# Create tmux windows AND launch Claude in each
./scripts/sandbox-worktrees.sh -t -a claude /opt/work/myproject

# Start at window 3 (implies -t)
./scripts/sandbox-worktrees.sh -s 3 -a gemini /opt/work/myproject
```

The `-a` flag behaves differently depending on whether `-t` is present:
- **`-a` alone:** launches the sandbox in the current shell via `exec` (replaces the shell process).
- **`-t -a`:** creates tmux windows and launches a sandbox in each.

This pairs well with projects that use docker compose with per-worktree port offsets (via `.env` files), letting you run fully isolated stacks side by side. A typical setup:

```
Window 7:  fand-api       (main worktree, master)     → ports 35432, 18081, 18082
Window 8:  fand-api-wt1   (feature/new-batch-job)     → ports 35433, 18084, 18083
Window 9:  fand-api-wt2   (fix/dashboard-bug)         → ports 35434, 18086, 18085
Window 10: fand-api-wt3   (spike/experiment)           → ports 35435, 18088, 18087
```

### Creating worktrees manually

```bash
# From the main repo — create worktrees alongside it
cd /opt/work/myproject
git worktree add ../myproject-wt1 master
git worktree add ../myproject-wt2 --detach HEAD

# List all worktrees
git worktree list

# Clean up when done
git worktree remove ../myproject-wt2
```

### Worktree layout (`SWARM_WORKTREE_GROUPING`)

`scripts/_load-env.sh` derives every swarm worktree path from `SWARM_WORKTREE_GROUPING`, which supports two layouts:

- **`flat`** (default, for backward compat) — `<parent>/wt-issue-N`, i.e. a worktree sits directly next to the project directory.
- **`project`** — `<parent>/<project>-worktrees/wt-issue-N`, i.e. worktrees for a given project are grouped under their own subdirectory.

`project` grouping exists to solve a cross-project namespace collision: when several sibling repos live under the same parent directory and each spawns swarm workers, they can all produce a `wt-issue-N` path for the same issue number, and a deleted-then-recreated worktree in one project can clobber a live one in another. Set `SWARM_WORKTREE_GROUPING=project` per project (e.g. in `<project>/.swarm/.env`) to give each project its own worktree namespace.

Set this **before** any worktrees exist for the project — there is no automatic migration between layouts, so switching it after the fact leaves existing worktrees at the old path while new ones land at the new path.

**The triage/revive examples elsewhere in this doc (and `requeue.sh`) assume `flat` layout** — paths like `../wt-issue-N` or `$(dirname $PWD)/wt-issue-$issue` resolve to the wrong location under `project` grouping. If your project uses `project` grouping, adjust those paths to `<project>-worktrees/wt-issue-N` instead.

## Custom Configuration

### Per-project Environment (`.sandbox-env`)

Create a `.sandbox-env` file in your project directory to pre-set credentials and service URLs. `sandbox.sh` passes it to the container via `--env-file` when present.

```bash
# /opt/work/myproject/.sandbox-env  — gitignore this file
PGHOST=localhost
PGPORT=5432
PGDATABASE=mydb
PGUSER=myuser
PGPASSWORD=mypassword
APP_URL=http://localhost:8080
```

Add `.sandbox-env` to your project's `.gitignore` to avoid committing credentials.

### Extra Mounts

Pass additional mounts via `EXTRA_MOUNTS` (comma-separated). Two formats are supported:

```bash
# Same-path mirror — host path appears at the same path inside the container
EXTRA_MOUNTS="/opt/data/myfiles/:ro" ./sandbox.sh /path/to/project

# Explicit host:container mapping
EXTRA_MOUNTS="/opt/data:/mnt/data:ro" ./sandbox.sh /path/to/project

# Multiple mounts
EXTRA_MOUNTS="/opt/data:ro,/opt/models:/models:ro" ./sandbox.sh /path/to/project
```

#### Persistent mounts for swarm workers

The form above sets `EXTRA_MOUNTS` for one ad-hoc `sandbox.sh` invocation. For the swarm-coordinator flow — where `provision-worker.sh` spawns containers automatically — declare mounts in `<project>/.swarm/.env` so every worker spawn picks them up:

```bash
# /opt/work/myproject/.swarm/.env  — gitignored
EXTRA_MOUNTS=/opt/data/reference:ro,/opt/work/myorg/sibling-repo:ro
```

`scripts/_load-env.sh` reads this file (precedence: shell env > `<project>/.swarm/.env` > sandbox `.env.example`) and `provision-worker.sh` injects the value as a prefix on the `tmux new-window` command that starts the worker listener, so the listener's `sandbox.sh` sees it. `${FAND_DATA_ROOT}` (and any other env var resolved earlier in the chain) is expanded via envsubst before docker sees the spec — see `scripts/_load-env.sh:55-72`.

**Common pattern: cross-project siblings.** When several related repos live under one org dir (e.g. `/opt/work/myorg/{app,guide,poc}`), give each project's workers read-only access to its siblings so they can cross-reference code, ADRs, and docs:

```bash
# /opt/work/myorg/app/.swarm/.env
EXTRA_MOUNTS=/opt/work/myorg/guide:ro,/opt/work/myorg/poc:ro
```

Use the same host:container path on both sides (the implicit default when you omit the container side) so absolute paths in code resolve identically inside and outside the container.

**Mounts apply only to newly-spawned workers.** In-flight `iss-*` containers were started with whatever `EXTRA_MOUNTS` was set when *they* spawned — they don't see edits to `.swarm/.env` after the fact. To pick up changes: `tmux -L swarm-<project> kill-window -t llm-<project>:iss-N`, then re-provision the issue. Restarting the whole coordinator session (`tmux -L swarm-<project> kill-session -t llm-<project>` then a fresh `llm-start.sh`) is the heavier-hammer equivalent.

**Verify mounts landed.** After a worker spawns, inspect the running container:

```bash
docker inspect swarm-llm-<project>-iss-<N> \
    --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' \
    | grep -v ' -> /home\| -> /var/run'
```

The non-`/home`-or-docker-socket lines should be exactly the host paths you put in `EXTRA_MOUNTS`. If a path is missing, the propagation broke somewhere between `.swarm/.env` and the `docker run` invocation. Don't bother with `tmux show-env … EXTRA_MOUNTS` — `EXTRA_MOUNTS` never lands in the tmux session environment; it travels as a prefix on the `tmux new-window` command that starts the worker listener (`provision-worker.sh:412`), not through `tmux new-session -e`/`set-environment`, so `show-env` shows nothing even on a healthy setup. Instead check the listener's actual launch command with `tmux -L swarm-<project> capture-pane -t llm-<project>:iss-<N> -pS -100` (scroll to the top of the pane for the `EXTRA_MOUNTS=...` prefix), or just read `<project>/.swarm/.env` directly.

### Memory limit (`SANDBOX_MEM_LIMIT`)

Every sandbox container runs with a memory cap, applied as `--memory` and `--memory-swap` (set equal to each other, so the cgroup can't overflow into swap and stall the host on IO). `SANDBOX_MEM_LIMIT` defaults to `8g`; `SANDBOX_MEM_LIMIT=0` disables the cap entirely (ad-hoc debugging only).

Heavy builds and test suites — JVM projects in particular — can exceed the 8g default. Set it higher per-project in `.swarm/.env` so every worker spawn picks it up:

```bash
# /opt/work/myproject/.swarm/.env  — gitignored
SANDBOX_MEM_LIMIT=24g
```

Some full-suite JVM runs need even more headroom — 40g is not unusual on a beefy host. The symptom of hitting the cap is exit code 137 in the worker log (the cgroup OOM-killed the process inside its own container). See [troubleshooting.md's OOM entry](troubleshooting.md#oom-kills-host-or-container) for how to confirm this is what happened.

## Docker Integrations

### Testcontainers / Docker CLI

The host Docker socket (`/var/run/docker.sock`) is mounted automatically when present. Socket write access is actually granted via `--group-add "$(stat -c '%g' /var/run/docker.sock)"` on the `docker run` line in `sandbox.sh` (sandbox.sh:178); `entrypoint.sh` merely registers a group named `docker` with the host's GID (`sudo groupadd -f -g "$DOCKER_GID" docker`, entrypoint.sh:5) so group-name lookups don't warn — it does not add the sandbox user to any group itself. `TESTCONTAINERS_HOST_OVERRIDE=localhost` is set automatically so Testcontainers resolves mapped ports correctly with `--network host`.

`_JAVA_OPTIONS=-Dapi.version=1.45` is also set automatically so Testcontainers' shaded docker-java client negotiates a Docker Engine API version that modern daemons (Docker 25+, minimum API 1.40) will accept — without this, every `@SpringBootTest` using Testcontainers fails with `client version 1.32 is too old`. Override per-invocation with `_JAVA_OPTIONS=-Dapi.version=<other> ./sandbox.sh …`, or per-project via `systemProperty("api.version", "…")` in your `build.gradle.kts` test block (project-level wins, because it's set on the forked test JVM).

### Rebuilding the Image

```bash
# After Dockerfile changes
docker build -t llm-swarm-runner:latest .

# Force a full rebuild (no cache)
docker build --no-cache -t llm-swarm-runner:latest .
```

## Worker Escape Hatch (Ctrl-Z opens a sibling bash pane)

> **Not a subshell, not a job-control suspend.** Because each worker runs as `docker run` foreground inside its own tmux window, there is no host shell to "drop to". The Ctrl-Z binding instead **splits a new sibling pane next to claude** and runs `docker exec -it … bash -l` against the same worker container. Claude in the original pane is untouched; the new pane shares the worktree, branch, gh auth, and env of the worker it sits beside.

Sometimes you want a plain shell **inside the same container** as a running worker — to inspect the worktree, run a quick `git log`, check `gh pr view`, poke at `node_modules/`, or drop a manual brief into `.swarm/tasks/inbox/`. You don't want to suspend claude (no useful way to resume it from inside a `docker run` foreground), and you don't want to spin up a separate container that wouldn't share the worktree state.

The tmux Ctrl-Z escape hatch handles this: in any `iss-*` window, **Ctrl-Z splits a sibling pane that `docker exec`s into the same worker container as a login shell**. The original pane keeps running claude untouched. The new pane sees the same worktree mount, same git state, same gh auth, same env.

### How it works

Three pieces have to line up:

| Piece | Where |
|---|---|
| Container is started with a deterministic `--name` | `sandbox.sh` (worker mode) |
| `provision-worker.sh` uses the format `swarm-<session>-<window>` | `scripts/provision-worker.sh` |
| Tmux intercepts Ctrl-Z in `iss-*` windows and runs the helper script | `~/.tmux.conf` (you install this) |
| Helper resolves the session/window names and `docker exec`s in | `scripts/tmux-worker-shell.sh` |

### Install (recommended): use the install script

The repo ships a small installer that bakes the correct absolute path to *this* checkout into a managed block in `~/.tmux.conf` and re-sources the config on every running swarm socket:

```bash
./scripts/install-tmux-binding.sh             # install + reload all swarm-* sockets
./scripts/install-tmux-binding.sh --dry-run   # preview the diff first
./scripts/install-tmux-binding.sh --uninstall # remove the managed block
```

The managed block lives between sentinel markers (`# >>> llm-swarm-runner ctrl-z binding (managed by install-tmux-binding.sh) >>>` / `<<<`) so re-running the script is idempotent — it rewrites the block in place rather than appending duplicates. A timestamped backup of `~/.tmux.conf` is taken before any write. If you have a previous manually-pasted copy of the binding outside the managed block, the script warns about it (tmux's last-binding-wins keeps the managed one effective, but you may want to delete the stray).

### Install (manual)

If you prefer to edit `~/.tmux.conf` by hand, paste the block below — also included in [`examples/tmux.conf.example`](../examples/tmux.conf.example):

> ⚠️ **You MUST edit the absolute path below to match where you cloned `llm-swarm-runner`.** If the path is wrong, the sibling pane will appear and immediately die with `bash: line 1: …/tmux-worker-shell.sh: No such file or directory` (exit 127). The install script above sidesteps this by baking in `$SCRIPT_DIR` at install time.

```tmux
# Ctrl-Z dispatch:
#   • iss-* window  → split a sibling bash pane in the same worker container.
#   • coordinator   → toggle a bare-bash scratch pane next to claude.
#   • anywhere else → fall through to normal Ctrl-Z.
#
# >>> EDIT THE TWO PATHS to match your clone of llm-swarm-runner <<<
bind-key -n C-z if-shell -F '#{m:iss-*,#{window_name}}' \
    'split-window -h "/opt/work/llm-swarm-runner/scripts/tmux-worker-shell.sh"' \
    'if-shell -F "#{==:#{window_name},coordinator}" \
        "run-shell \"/opt/work/llm-swarm-runner/scripts/coord-scratch-toggle.sh\"" \
        "send-keys C-z"'
```

**Why the helper script?** tmux's `if-shell -F` expands `#{...}` formats in its *condition*, but `split-window`'s shell-command argument is passed **literally** — no format substitution. An earlier version of this binding put `#{session_name}` and `#{window_name}` directly in the `docker exec` line; those reached docker unexpanded as the literal container name `swarm-#{session_name}-#{window_name}`, which never matched a real container, so the new pane died with exit 1 every time. The helper sidesteps the limitation by resolving the names at run time via `tmux display-message -p -t "$TMUX_PANE"` (which *does* expand formats) before exec-ing into docker.

After editing the config manually, reload it on every running swarm socket (each swarm uses its own tmux server `tmux -L swarm-<repo>`, so reloading the default socket alone leaves existing swarms unchanged):

```bash
tmux source-file ~/.tmux.conf      # default socket
for s in /tmp/tmux-$(id -u)/swarm-*; do
    tmux -L "$(basename "$s")" source-file ~/.tmux.conf
done
tmux list-keys -T root | grep C-z  # expect a binding here — if empty, the source-file didn't take
```

### Using it

1. Attach to a swarm session and select an `iss-N` window.
2. Press **Ctrl-Z**. A new pane splits to the right with a `bash -l` prompt inside the same container.
3. Do whatever — `git log`, `ls .swarm/tasks/`, `gh pr view`, etc.
4. When done, `exit` to close the helper pane. Claude in the original pane is unaffected.

### Coordinator scratch pane (same key, different window)

In the `coordinator` window, Ctrl-Z does **not** open a container shell — it toggles a **bare-bash scratch pane** next to claude, started in the repo root. No worktree, no docker, just a shell for the ad-hoc commands the coordinator occasionally suggests running on the host.

1. In the coordinator window, press **Ctrl-Z**. A pane splits to the right with a plain bash prompt in the repo root.
2. Press **Ctrl-Z** again from anywhere in the window (including from the scratch pane itself) to close it.

The scratch pane is identified by its tmux pane title (`coord-scratch`), so the toggle is index-free — it works regardless of how panes have been reordered or zoomed. Each toggle-open spawns a fresh shell, so don't rely on it to preserve state across closes; if you need a long-lived bash with history, use the bare-bash pane in the `util` window instead.

### Gotcha: config edited but not loaded

If you edit `~/.tmux.conf` while a tmux server is already running, **the binding does not take effect until you source the file**. Symptom: Ctrl-Z in an `iss-*` window suspends claude inside the container and prints "Claude Code has been suspended. Run `fg` to bring Claude Code back" — but since the foreground process in that window is `docker run`, there's no host-side shell to type `fg` into.

Recovery:

```bash
# Resume the suspended claude process directly inside the container
docker exec swarm-<session>-iss-N bash -c 'pkill -CONT -f claude'

# Then load the binding so this doesn't happen again
tmux source-file ~/.tmux.conf
tmux list-keys -T root | grep C-z
```

See also: [Troubleshooting → Ctrl-Z accidentally suspended claude](./troubleshooting.md#ctrl-z-accidentally-suspended-claude-inside-a-worker).

## Peering at Workers from the Host (capture-pane)

> Architectural background for *why* this works lives at [overview → "Tmux as substrate"](./llm-swarm-runner-overview.md#tmux-as-substrate-not-just-a-ui). Security implications at [security → "Tmux Scrollback Exposure"](./security.md#tmux-scrollback-exposure). This section is the operational how-to.

Because every agent runs in a tmux pane (not a detached background process), the coordinator pane and every worker pane have **host-readable scrollback** for the life of the session — even after the agent inside has exited. The default config retains 50000 lines and keeps `[dead]` panes around on non-zero exit (`remain-on-exit failed`), so post-mortem inspection of a crashed worker works without rerunning anything.

### The one command you'll actually use

```bash
tmux -L swarm-<repo> capture-pane -t llm-<repo>:iss-<N> -p -S -50000
```

- `-L swarm-<repo>` selects the per-repo tmux server (each swarm uses its own socket — see [tmux-cheatsheet.md](./tmux-cheatsheet.md)).
- `-p` prints to stdout (pipeable to `grep`, `less`, `tee`, an LLM, whatever).
- `-S -50000` includes the full retained scrollback rather than only what's currently visible.

Example — find which worker hit a particular error:

```bash
for w in $(tmux -L swarm-fand-etl list-windows -t llm-fand-etl -F '#W' | grep '^iss-'); do
    echo "=== $w ==="
    tmux -L swarm-fand-etl capture-pane -t "llm-fand-etl:$w" -p -S -50000 \
        | grep -i 'lazyinitialization\|ParseException' || echo "(no match)"
done
```

### What the coordinator does with this today

The host-native coordinator has unrestricted access to the swarm tmux socket. Cross-agent coordination is still primarily file-based via `.swarm/tasks/done/<id>.json` outcomes and GitHub PR state, but [`prompts/coordinator.md`](../prompts/coordinator.md) now explicitly blesses read-only `capture-pane` as a diagnostic fallback (its "Never `tmux send-keys`" section, `coordinator.md:99`) and its status-update procedure checks pane scrollback when a window closed with no PR (`coordinator.md:107`). Two of the three capabilities once listed here as latent are now shipped tooling, not prompt behavior:

- **Stuck-worker detection is shipped**: `scripts/check-stuck-workers.sh` captures each `iss-*` pane, strips ANSI, and pattern-matches it into one of eight states (`IDLE-PARKED`, `ACTIVE`, `EXITED-IDLE`, `CONTEXT-LARGE`, `EXIT-CONFIRM-PENDING`, `UNKNOWN`, `DEAD-PANE`, `ORPHANED-CONTAINER`). Recovery, when the worker is idle over its context threshold, is a real `/compact` injection via `coordinator-watch.sh`'s `WORKER_AUTO_COMPACT` (below) — an engineered, idle-gated `send-keys`, not a coordinator LLM improvising one. See [`docs/tmux-as-channel.md`](./tmux-as-channel.md) §1c for the full argument on why that distinction matters.
- **Cross-worker failure grep remains a manual pattern** — the loop shown earlier in this section (`for w in ... capture-pane ... | grep`) is the closest thing shipped; nothing automates "grep every worker for the same error" on a timer yet.
- **Transcript replay into a follow-up brief is still unbuilt** — a failed worker's transcript still has to be read and summarized by hand into a `requeue.sh` brief.

### What workers can't do

Workers cannot use `tmux capture-pane` to read the coordinator or sibling workers — their containers don't bind-mount the host tmux socket. If you need cross-worker visibility *from inside a worker*, the alternative paths are `docker exec` / `docker logs` (because `/var/run/docker.sock` is mounted), or the shared filesystem under `.swarm/tasks/`. Both have their own risk profiles; see [security.md](./security.md).

## Long-lived coordinator: context monitoring

The default flow keeps the coordinator Claude Code session running across many worker dispatches — provisioning, watching, reporting outcomes, resuming the next wave — for hours or days at a stretch. The cross-coordination memory is valuable: which workers are doing what, which PRs are mid-review, what the user just asked about last turn. But a single Claude session that lives that long accumulates context bloat, and somewhere above ~120k tokens (a soft, model-and-task-dependent boundary often referred to as the "stupid zone") the model starts to lose focus on the actual work in front of it.

Two related observations make this worse than it sounds:

1. **Claude Code's own built-in auto-compact is not user-tunable.** It fires as you approach the context limit, but there is no setting to raise or lower its threshold — you cannot pin it to "auto-compact at 150k" or "at 60%." The trigger is internal to Claude Code. This project ships its own external mechanism to get ahead of that internal trigger — see "Compact discipline" below — and its knobs (`AUTO_COMPACT_THRESHOLD_TOKENS`, `WORKER_COMPACT_THRESHOLD_TOKENS`, etc.) *are* user-tunable; only Claude Code's native trigger is opaque.
2. **There is no built-in visual indicator of context usage.** `/context` works, but it's a slash command you have to type. If you don't type it, you don't see context % until auto-compact fires — by which point degradation has already happened.

The fix is operator-side instrumentation, not architectural change. The long-lived coordinator is the right design; what it needs is a context-window gauge in the statusline so you can see drift coming.

### Statusline with context indicator

`scripts/statusline-with-context.sh` is a Claude Code statusLine command that renders:

```
opus · spring-search-tempo · ctx: 195k/1M (19%)
```

— model, working-dir basename, and context-window usage. To install (per-user), add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/opt/work/llm-swarm-runner/scripts/statusline-with-context.sh"
  }
}
```

(`/opt/work/llm-swarm-runner` is this repo's path in the reference swarm deployment — adjust to wherever you cloned it. Or symlink the script under `~/.claude/` and reference that path — your call.) Restart Claude Code for the change to take effect.

The script also writes the raw stdin JSON payload to `$STATUSLINE_PROBE` (default `${XDG_RUNTIME_DIR:-/tmp}/claude-statusline-$UID.json`) on every render. This is intentional — the first version of the script tries several plausible jq paths for the context fields because Claude Code's statusLine JSON schema isn't documented exhaustively; the dump lets you confirm which path is actually used in your build. Once you see `ctx: <something>k/<something>M (<n>%)` rendered correctly, the probe has served its purpose; if you see `ctx: ?`, inspect the dump and either update the script or report back so the fallback paths can be tightened.

### Compact discipline

This used to be purely a prompt convention (the coordinator LLM checking its own `ctx` reading and choosing to `/compact`); it's now also automated. `coordinator-watch.sh`'s `AUTO_COMPACT` (default on) injects a real `/compact` into the coordinator pane itself — the same idle-gated `send-keys` mechanism `WORKER_AUTO_COMPACT` generalizes to worker panes below — before waking a long-lived coordinator that's over `AUTO_COMPACT_THRESHOLD_TOKENS` (default 150k). The prompt-level discipline below still applies as a second line of defense and for the user-facing status indicator:

- **On every coordinator wake** (the `coordinator-watch.sh` re-trigger after a worker finishes), check the statusline `ctx` reading before processing the wake event; if it's > 60%, run `/compact` first. The just-completed worker is done; there's no live in-flight reasoning to preserve.
- **On every status report to the user,** the coordinator can include a one-line `ctx: 195k/1M (19%) — healthy` indicator so you don't have to ask.

If you don't want to keep the coordinator long-lived, the alternative is the **reset-after-each-coordination** flow — `/clear` (or exit and re-invoke `llm-start.sh`) after each batch. You lose the cross-coordination memory but you also never have to think about context drift. The trade-off is yours; the long-lived path is the default because the memory is usually worth more.

### Worker auto-compact

Everything above is about the coordinator's own session. Workers have the same problem, and arguably a worse one: `AUTO_COMPACT` above only watches the `coordinator` pane, and Claude Code's built-in auto-compact keys off *context-window fill*, not absolute token count. A worker running a model with a native 1M context window (Sonnet 5, the default worker model — see `.env.example`'s `WORKER_MODEL`) can cruise past 400k+ tokens without the built-in trigger ever firing, sitting deep in the "stupid zone" the whole time.

`coordinator-watch.sh` (issue #226) generalizes the same pattern to every `iss-*` worker window via `WORKER_AUTO_COMPACT` (on by default). The mechanism differs from the coordinator's in one important way: a worker's statusline probe file is written *inside* its docker container, to a path the host genuinely cannot see (no `/tmp` or `$XDG_RUNTIME_DIR` bind-mount). So instead of reading a probe file, it parses the rendered statusline text straight out of `tmux capture-pane` — the same `ctx: <used>/<total> (<pct>%)` line `statusline-with-context.sh` renders, since that script is installed per-user (`~/.claude/settings.json`) and gets bind-mounted into every worker container the same way it renders in the coordinator's own pane.

On its own timer (`WORKER_COMPACT_SCAN_SECS`, default 30s), it sweeps every `iss-*` window and, for any that's idle at its REPL prompt (not mid-turn — workers idle between tasks the same way the coordinator idles between wakes) and over threshold, injects a real `/compact` and follows it with a short "continue your task" nudge once compaction finishes. A worker whose worktree already has an open PR (per its `.swarm/tasks/status/<task_id>.json`) gets a raised threshold (`WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS`, default 300k vs. the normal 150k) — a worker that's already at wrap-up phase may be about to land, and compacting it over a small overage just costs a needless pause.

Known limitation: this only catches workers idling *between* turns. A single marathon turn offers no idle window until it ends. See `coordinator-watch.sh`'s header comment for the full knob list (`WORKER_AUTO_COMPACT`, `WORKER_COMPACT_THRESHOLD_TOKENS`, `WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS`, timeouts, `WORKER_COMPACT_NUDGE_PROMPT`, etc.) and `worker_compact_pass()`'s implementation comments for the rest of the design rationale.

## Triage Workflow

> **Tip:** the triage cycle ends with you merging the READY PRs — which routinely means resolving conflicts because main moved while workers ran. [`VCS/git-github.md`](./VCS/git-github.md) is a focused crib sheet for that step, especially the "resolving conflicts in a PR" section.

A pattern that recurs whenever a swarm of workers has been running for a while: their tmux session dies (reboot, accidental kill, ssh hang-up), but their worktrees + branches + queue state survive on disk. You come back to N abandoned worktrees and need to decide, per worktree, whether to merge / abandon / continue.

The four-tool kit is built for exactly this:

| Helper | Used for |
|---|---|
| `llm-start.sh "<prompt>"` | Wake the coordinator with a custom prompt |
| `provision-worker.sh <issue>` | Create a fresh worktree + queue + listener |
| `requeue.sh <issue\|wt-path> <brief>` | Drop a follow-up brief into an existing worker's queue |
| `kill-worktree.sh <issue>` | Remove worktree, branch, and tmux window |

### The triage cycle

1. **Wake the coordinator** with a read-only triage prompt → get a markdown table of verdicts.
2. **Sanity-check the verdicts yourself** (30 seconds of `git log` per worktree).
3. **Act on each verdict** using the helper scripts (commands below).
4. **Revive listeners** for any worktrees that need a follow-up worker invocation.

### Read-only triage prompt

Use `COORDINATOR_CMD=claude` for this — claude streams tool calls cleanly to the pane and isn't subject to the `$(...)` block that gemini's `run_shell_command` enforces.

```bash
cd /opt/work/myproject
COORDINATOR_CMD=claude $LLM_SWARM_DIR/llm-start.sh "$(cat <<'EOF'
Triage the existing worker worktrees. READ-ONLY — do NOT push, do NOT
open PRs, do NOT merge, do NOT close issues, do NOT remove worktrees,
do NOT provision new workers.

For each ../wt-issue-* worktree relative to this project:

1. git -C <wt> log --oneline master..HEAD          (commits made)
2. git -C <wt> diff --stat master..HEAD            (scope of changes)
3. cat <wt>/.swarm/tasks/done/*.json | tail -n 1   (latest outcome)
4. gh issue view <N>                               (the issue)

Decide one verdict per worktree:

- READY:        work matches issue, looks correct, recommend pushing + PR.
- NEEDS_REVIEW: work was done but you have a concern (scope creep,
                missing tests, conflicts with PRs that landed on master
                while the worker ran). Flag the specific concern.
- PARTIAL:      real attempt that didn't complete. Recommend a
                follow-up brief outlining what's missing.
- ABANDON:      work is wrong / off-target / superseded by a merged PR.
                Recommend deletion (do NOT execute deletion).

Output ONE markdown table:

  issue | branch | commits | files-touched | verdict | one-sentence reasoning

After the table, list any worktrees with NO .swarm/tasks/done/*.json
(older pre-v2 worktrees) — verdict relies on git log + diff alone for those.
EOF
)"
tmux -L swarm-$(basename $PWD) a -t llm-$(basename $PWD)
```

(Or run `scripts/list-swarms.sh` for a ready-to-paste attach command with the right socket.)

### Acting on each verdict

#### READY → push + open PR

If you trust the verdict, this is one push + one `gh pr create` per worktree:

```bash
WT=/opt/work/myproject/../wt-issue-N
BRANCH=$(git -C "$WT" branch --show-current)
git -C "$WT" push -u origin "$BRANCH"
gh -R <owner>/<repo> pr create \
    --base master --head "$BRANCH" \
    --title "[swarm] <short summary> (closes #N)" \
    --body-file "$WT/.swarm/tasks/done/<id>.md"   # the original brief is fine as PR body
```

If the coordinator's READY list is short, do them by hand. If it's long, you can ask the coordinator to do this in a follow-up wake — just give it the explicit "for each READY in the table, push and PR" prompt (the *permissive* triage variant).

#### NEEDS_REVIEW → surgical re-do brief

The worker's branch contains a mix of valuable new work AND stale changes that conflict with master (because master moved while the worker ran). Drop a brief telling a fresh worker to reset and re-apply only the salvageable parts:

```bash
cat <<'BRIEF' | $LLM_SWARM_DIR/scripts/requeue.sh N -
## Surgical re-do for issue #N

Your earlier work added <X valuable thing> AND a rewrite of <Y> that
has since been merged via PR #M.

Reset this branch to current origin/master and keep ONLY the X work.
DO NOT touch Y.

Steps:
1. git fetch origin
2. git reset --hard origin/master
3. Re-apply only the X work.
4. Run the test suite to verify against current master.
5. Push and PR titled "[swarm] <new title>".

If X doesn't compile/pass against current master (APIs changed, etc.),
STOP and report what broke — don't try to "fix" surrounding code.
BRIEF
```

`requeue.sh` also prints a hint if no listener tmux window is currently polling — see [Reviving listeners](#reviving-listeners-after-a-tmux-session-is-killed) below.

#### PARTIAL → follow-up brief listing what's missing

Same shape as NEEDS_REVIEW, but the brief just enumerates the remaining scope:

```bash
cat <<'BRIEF' | $LLM_SWARM_DIR/scripts/requeue.sh N -
## Follow-up to your prior work on issue #N

You completed <subset>. The issue scope was <full set> — <remainder> remains:

- <item 1>
- <item 2>
- ...

Same conventions as last time. Stop and ask if any item has unusual
setup. When done, push and open a PR titled "[swarm] <full-scope title>".
BRIEF
```

#### ABANDON → clean removal

```bash
# single
$LLM_SWARM_DIR/scripts/kill-worktree.sh N

# batch
for issue in <list>; do
    $LLM_SWARM_DIR/scripts/kill-worktree.sh "$issue"
done
```

`kill-worktree.sh` prints `<commits ahead, M uncommitted>` before deletion so a worktree with unexpected work doesn't get silently dropped.

### Reviving listeners after a tmux session is killed

When the tmux session dies, worktrees survive but listeners don't. To pick up where you left off — remembering that swarm sessions live on the **per-project socket** (`-L swarm-<project>`), so bare `tmux` commands against your default server won't see them:

```bash
cd /opt/work/myproject
SOCKET="swarm-$(basename $PWD)"
SESSION="llm-$(basename $PWD)"

# 1. Recreate the session if needed (status-only prompt — read-only).
#    A leftover ORPHAN socket file from the dead server is fine: llm-start.sh
#    targets the socket itself, and tmux unlinks a stale socket on server start.
tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null || \
    NON_INTERACTIVE=1 $LLM_SWARM_DIR/llm-start.sh \
        "Status check ONLY — list worktrees and recent outcomes."

# 2. Spawn a listener window per worktree you'll act on
for issue in <list>; do
    WT=$(dirname $PWD)/wt-issue-$issue
    [ -d "$WT" ] || continue
    tmux -L "$SOCKET" list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "iss-$issue" || \
        tmux -L "$SOCKET" new-window -d -t "$SESSION" -n "iss-$issue" \
            "$LLM_SWARM_DIR/sandbox.sh $WT listener"
done

# 3. Verify
tmux -L "$SOCKET" list-windows -t "$SESSION"
```

Now `requeue.sh <issue> -` drops will be picked up within ~2 seconds.