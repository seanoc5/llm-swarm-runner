# Advanced Usage & Configuration

This document covers advanced workflows, custom mounts, and manual Git worktree setups.

## Contents

- [Git Worktrees](#git-worktrees)
  - [Manual Multi-worktree tmux setup](#manual-multi-worktree-tmux-setup)
  - [Creating worktrees manually](#creating-worktrees-manually)
- [Custom Configuration](#custom-configuration)
  - [Per-project Environment (.sandbox-env)](#per-project-environment-sandbox-env)
  - [Extra Mounts](#extra-mounts)
- [Docker Integrations](#docker-integrations)
  - [Testcontainers / Docker CLI](#testcontainers--docker-cli)
  - [Rebuilding the Image](#rebuilding-the-image)
- [Worker Escape Hatch (Ctrl-Z opens a sibling bash pane)](#worker-escape-hatch-ctrl-z-opens-a-sibling-bash-pane)
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

**Mounts apply only to newly-spawned workers.** In-flight `iss-*` containers were started with whatever `EXTRA_MOUNTS` was set when *they* spawned — they don't see edits to `.swarm/.env` after the fact. To pick up changes: `tmux kill-window -t llm-<project>:iss-N`, then re-provision the issue. Restarting the whole coordinator session (`tmux kill-session -t llm-<project>` then a fresh `llm-start.sh`) is the heavier-hammer equivalent.

**Verify mounts landed.** After a worker spawns, inspect the running container:

```bash
docker inspect swarm-llm-<project>-iss-<N> \
    --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' \
    | grep -v ' -> /home\| -> /var/run'
```

The non-`/home`-or-docker-socket lines should be exactly the host paths you put in `EXTRA_MOUNTS`. If a path is missing, the propagation broke somewhere between `.swarm/.env` and the `docker run` invocation — check `tmux show-env -t llm-<project> -g EXTRA_MOUNTS` to see what the tmux session has, and `tmux capture-pane -t llm-<project>:iss-<N> -pS -100` to see what the listener invocation looked like.

## Docker Integrations

### Testcontainers / Docker CLI

The host Docker socket (`/var/run/docker.sock`) is mounted automatically when present. `entrypoint.sh` adds the sandbox user to the docker group at startup (using `DOCKER_GID`) to silence permission errors. `TESTCONTAINERS_HOST_OVERRIDE=localhost` is set automatically so Testcontainers resolves mapped ports correctly with `--network host`.

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

The managed block lives between sentinel markers (`# >>> llm-swarm-runner ctrl-z binding (managed) >>>` / `<<<`) so re-running the script is idempotent — it rewrites the block in place rather than appending duplicates. A timestamped backup of `~/.tmux.conf` is taken before any write. If you have a previous manually-pasted copy of the binding outside the managed block, the script warns about it (tmux's last-binding-wins keeps the managed one effective, but you may want to delete the stray).

### Install (manual)

If you prefer to edit `~/.tmux.conf` by hand, paste the block below — also included in [`examples/tmux.conf.example`](../examples/tmux.conf.example):

> ⚠️ **You MUST edit the absolute path below to match where you cloned `llm-swarm-runner`.** If the path is wrong, the sibling pane will appear and immediately die with `bash: line 1: …/tmux-worker-shell.sh: No such file or directory` (exit 127). The install script above sidesteps this by baking in `$SCRIPT_DIR` at install time.

```tmux
# Worker (iss-*) Ctrl-Z escape hatch.
# In any iss-* window, Ctrl-Z splits a sibling pane that docker-execs
# into the same worker container as a login shell. claude keeps running.
# In any other window, Ctrl-Z falls through to normal behavior.
#
# >>> EDIT THIS PATH to match your clone of llm-swarm-runner <<<
bind-key -n C-z if-shell -F '#{m:iss-*,#{window_name}}' \
    'split-window -h "/opt/work/llm-swarm-runner/scripts/tmux-worker-shell.sh"' \
    'send-keys C-z'
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
tmux a -t llm-$(basename $PWD)
```

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

When the tmux session dies, worktrees survive but listeners don't. To pick up where you left off:

```bash
cd /opt/work/myproject

# 1. Recreate the session if needed (status-only prompt — read-only)
tmux has-session -t "llm-$(basename $PWD)" 2>/dev/null || \
    NON_INTERACTIVE=1 $LLM_SWARM_DIR/llm-start.sh \
        "Status check ONLY — list worktrees and recent outcomes."

# 2. Spawn a listener window per worktree you'll act on
for issue in <list>; do
    WT=$(dirname $PWD)/wt-issue-$issue
    [ -d "$WT" ] || continue
    SESSION="llm-$(basename $PWD)"
    tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "iss-$issue" || \
        tmux new-window -d -t "$SESSION" -n "iss-$issue" \
            "$LLM_SWARM_DIR/sandbox.sh $WT listener"
done

# 3. Verify
tmux list-windows -t "llm-$(basename $PWD)"
```

Now `requeue.sh <issue> -` drops will be picked up within ~2 seconds.