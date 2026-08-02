# Troubleshooting

## Quick fixes

| Symptom | Quick fix | Details |
|---|---|---|
| `permission denied` on `/var/run/docker.sock` | `sudo usermod -aG docker $USER`, then re-login (or `newgrp docker`) | [↓](#permission-denied-on-varrundockersock) |
| `gh: HTTP 401` in sandbox | Confirm `gh auth status` works on host; rebuild image if the token isn't propagating | [↓](#gh-http-401) |
| Worker isn't picking up briefs | Start a listener window: `tmux new-window … sandbox.sh <wt> listener` | [↓](#worker-isnt-picking-up-briefs) |
| Tasks stuck in `processing/` | `mv <wt>/.swarm/tasks/processing/<id>.md <wt>/.swarm/tasks/inbox/` | [↓](#tasks-stuck-in-processing) |
| Ctrl-Z suspended claude inside a worker | `docker exec swarm-<session>-iss-N bash -c 'pkill -CONT -f claude'` | [↓](#ctrl-z-accidentally-suspended-claude-inside-a-worker) |
| `Ripgrep is not available` warning from gemini | Run `./scripts/setup.sh` on the host once | [↓](#ripgrep-fallback-warning-from-gemini) |
| Swarm vanished after a Docker update/restart | Just re-run `llm-start.sh` — the leftover socket is handled automatically | [↓](#docker-daemon-restarted--swarm-died-socket-left-behind) |

---

Common issues and their resolutions. If you hit something not covered here, please open an issue against the repo so we can add it.

> **Tip:** for general tmux usage (attach/detach, multi-client handling, capturing pane scrollback for diagnosis, killing dead panes), see [`tmux-cheatsheet.md`](./tmux-cheatsheet.md). Many of the diagnostic commands referenced below assume familiarity with `tmux capture-pane -p -S -N` and `tmux list-windows`.

## Contents

- [Auth & Plan Availability](#auth--plan-availability)
  - [Is my Claude Max plan still active?](#is-my-claude-max-plan-still-active)
  - [Claude API key — get / validate](#claude-api-key--get--validate)
  - [Is my Gemini plan / quota healthy?](#is-my-gemini-plan--quota-healthy)
  - [Gemini API key — get / validate](#gemini-api-key--get--validate)
  - [Coordinator picks the wrong billing path](#coordinator-picks-the-wrong-billing-path)
  - [`gh: HTTP 401`](#gh-http-401)
- [Sandbox & Docker](#sandbox--docker)
  - [`docker: command not found` or daemon not running](#docker-command-not-found-or-daemon-not-running)
  - [`permission denied` on `/var/run/docker.sock`](#permission-denied-on-varrundockersock)
  - [`groups: cannot find name for group ID NNN`](#groups-cannot-find-name-for-group-id-nnn)
  - [Image build fails / out of date](#image-build-fails--out-of-date)
  - [Disk space exhausted (worktrees + image layers)](#disk-space-exhausted-worktrees--image-layers)
- [Networking](#networking)
  - [Host service not reachable from sandbox](#host-service-not-reachable-from-sandbox)
  - [`psql` connects but `pg_isready -h localhost` fails](#psql-connects-but-pg_isready--h-localhost-fails)
- [Git & SSH](#git--ssh)
  - [`git commit` fails with signing error](#git-commit-fails-with-signing-error)
  - [Worktree mounts but `git status` errors](#worktree-mounts-but-git-status-errors)
- [Coordinator & Workers](#coordinator--workers)
  - [Coordinator pane shows old/stale output](#coordinator-pane-shows-oldstale-output)
  - [Worker isn't picking up briefs](#worker-isnt-picking-up-briefs)
  - [Tasks stuck in `processing/`](#tasks-stuck-in-processing)
  - [Ctrl-Z accidentally suspended claude inside a worker](#ctrl-z-accidentally-suspended-claude-inside-a-worker)
  - [Gemini `run_shell_command` rejects `$(...)`](#gemini-run_shell_command-rejects-)
  - [Ripgrep fallback warning from gemini](#ripgrep-fallback-warning-from-gemini)
- [Host Sysadmin Issues](#host-sysadmin-issues)
  - [OOM kills (host or container)](#oom-kills-host-or-container)
  - [GPU lockups / `Xid` errors](#gpu-lockups--xid-errors)
  - [Docker daemon restarted — swarm died, socket left behind](#docker-daemon-restarted--swarm-died-socket-left-behind)
  - [tmux session vanished](#tmux-session-vanished)
- [Placeholders](#placeholders)

---

## Auth & Plan Availability

### Is my Claude Max plan still active?

Claude Code uses your Max OAuth session when `ANTHROPIC_API_KEY` is **unset**. To check:

```bash
# Inside or outside the sandbox
claude /status        # in a running claude session — shows account + plan
```

Or visit https://claude.ai/settings/billing on the web. If your plan is expired or paused, claude falls back to API billing (if `ANTHROPIC_API_KEY` is set) or fails outright.

`llm-start.sh` strips `ANTHROPIC_API_KEY` from the coordinator env when `COORDINATOR_CMD=claude` so the OAuth session is always used. Workers inherit the same behavior via `sandbox.sh`.

### Claude API key — get / validate

- Get a key: https://console.anthropic.com/settings/keys
- Validate quickly:
  ```bash
  curl -s https://api.anthropic.com/v1/messages \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
      | jq '.content[0].text // .error'
  ```
  A non-error response means the key works. `401` = invalid; `429` = rate-limited; `400 credit_balance` = out of credits.

### Is my Gemini plan / quota healthy?

Free tier and AI Pro plans both hit `generativelanguage.googleapis.com`. Symptoms of a quota issue:

- `429 RESOURCE_EXHAUSTED` in coordinator output
- `/tmp/gemini-*-error-*.json` files containing nested `RESOURCE_EXHAUSTED`

Check usage at https://aistudio.google.com/app/apikey (per-key) or https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com/quotas (project-wide). The `coordinator-error-tail.sh` helper decodes recent error files:

```bash
$LLM_SWARM_DIR/scripts/coordinator-error-tail.sh
```

### Gemini API key — get / validate

- Get a key: https://aistudio.google.com/app/apikey
- Validate quickly:
  ```bash
  curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=$GEMINI_API_KEY" \
      | jq '.models[0].name // .error'
  ```
  A model name means the key works. `400 API_KEY_INVALID` = bad key; `403 PERMISSION_DENIED` = key disabled or restricted.

`llm-start.sh` searches for `GEMINI_API_KEY` in (in order): the project `.env`, `~/.gemini/.env`, `$LLM_SWARM_DIR/.env`, `/opt/work/sysadmin/.env`, then any paths supplied via `LLM_ENV_FILES=path1:path2:...`.

### Coordinator picks the wrong billing path

| Symptom                                               | Likely cause                                       | Fix                                              |
|-------------------------------------------------------|----------------------------------------------------|--------------------------------------------------|
| Claude coordinator burning API credits unexpectedly   | `ANTHROPIC_API_KEY` set in env at launch time      | Confirm `llm-start.sh` is the caller (it strips it). If you launched `claude` directly, run `env -u ANTHROPIC_API_KEY claude ...`. |
| Gemini fails with no API key error                    | Key not in any of the 4 search paths               | Put it in `~/.gemini/.env` as `GEMINI_API_KEY=...` |
| Claude Max session expired mid-run                    | OAuth token TTL elapsed                             | Run `claude /login` on the host once             |

### `gh: HTTP 401`

The host `gh` token was not forwarded. Check that `gh auth status` works on your host machine. The token is read at sandbox startup via `gh auth token` and passed in via `-e GH_TOKEN`. If it works on the host but fails in the sandbox, rebuild the image — older entrypoints didn't propagate it.

---

## Sandbox & Docker

### `docker: command not found` or daemon not running

```bash
systemctl status docker        # is the daemon running?
sudo systemctl start docker    # if not
docker info                    # full daemon health check
```

If you see `Cannot connect to the Docker daemon`, the daemon is stopped or your user isn't in the `docker` group (next entry).

### `permission denied` on `/var/run/docker.sock`

Your user isn't in the `docker` group on the host:

```bash
groups                          # check current groups
sudo usermod -aG docker $USER   # add yourself
# Log out + back in (or run `newgrp docker`) for the change to take effect
```

Inside the sandbox, `entrypoint.sh` re-aligns the in-container docker group to the host's GID via the `DOCKER_GID` env var, so DooD works without further setup.

### `groups: cannot find name for group ID NNN`

Harmless warning on first start — `entrypoint.sh` suppresses it by registering the docker group. If it persists, rebuild the image:
```bash
docker build -t llm-swarm-runner:latest .
```

### Image build fails / out of date

The Dockerfile pins specific versions of node, claude-code, gemini-cli, codex, promptfoo, deno, and uv via `ARG`. If a build fails because a pinned version was yanked from npm/PyPI, bump the relevant `ARG` at the top of the Dockerfile and rebuild:

```bash
docker build --no-cache -t llm-swarm-runner:latest .
```

After a clean rebuild, also re-run `./scripts/setup.sh` on the host (the gemini ripgrep symlink lives in the host npm cache, not the image).

### Disk space exhausted (worktrees + image layers)

Multi-agent runs accumulate worktrees and stopped containers fast.

```bash
df -h /                                 # is the disk full?
docker system df                        # docker's contribution
docker system prune -a --volumes        # nuke unused images/containers/volumes (DESTRUCTIVE)
git -C /opt/work/myproject worktree list
git -C /opt/work/myproject worktree prune
```

For per-issue worktrees created by the swarm, use `kill-worktree.sh <issue>` instead of `git worktree remove` directly — it also cleans up the tmux window and branch.

---

## Networking

### Host service not reachable from sandbox
On Linux, `--network host` means `localhost` inside the container is the host. Confirm the service is actually listening on the host:
```bash
ss -tlnp | grep <port>
```
*Note: On macOS/Windows, `--network host` does not work with Docker Desktop — you must use `host.docker.internal` instead of `localhost`.*

### `psql` connects but `pg_isready -h localhost` fails
`pg_isready` without `-h` uses the Unix socket by default. Specify `-h localhost` to force TCP, which is what `--network host` provides.

---

## Git & SSH

> **Tip:** for general git skills relevant to swarm work — resolving merge conflicts in worker PRs, recovery recipes, when to merge vs. rebase — see [`VCS/git-github.md`](./VCS/git-github.md). The entries below are about plumbing failures (signing, mounts, auth); the VCS doc is about *using* git well.

### `git commit` fails with signing error
Verify `~/.ssh/id_rsa.pub` (or whatever `user.signingkey` points to) exists on the host. The path must be the literal value in `.gitconfig` — the container mounts `~/.ssh` at that exact path.

### Worktree mounts but `git status` errors

A worktree's `.git` is a file pointing back to the main repo. `sandbox.sh` detects this and mounts the main repo's `.git/` directory too. If it's failing:

```bash
cat /path/to/worktree/.git    # should be: gitdir: /path/to/main/.git/worktrees/<name>
ls /path/to/main/.git/worktrees/
```

If the path inside the `gitdir:` line doesn't exist on the host (e.g., the main repo moved), recreate the worktree.

---

## Coordinator & Workers

### Coordinator pane shows old/stale output

`llm-start.sh` re-uses an existing tmux session if one exists for the project. If Window 1 still shows the previous run's output, check whether anything is actually running:

```bash
tmux list-panes -t llm-<projbase>:1 -F '#{pane_current_command}'
```

If it shows `bash` (idle), you can re-invoke `llm-start.sh` and it will run a new prompt in that pane. If it shows `claude` or `gemini`, the prior coordinator is still alive — wait for it or kill the window.

### Worker isn't picking up briefs

Most common cause: no listener tmux window. `requeue.sh` warns about this — re-read its output. To start one:

```bash
tmux new-window -d -t llm-<projbase> -n iss-N \
    "$LLM_SWARM_DIR/sandbox.sh /path/to/worktree listener"
```

Other causes:
- Brief was written non-atomically (file starts with `.tmp.` — listener intentionally skips those)
- Listener is in headless mode and crashed silently — check `tmux capture-pane -p -t llm-<projbase>:iss-N`

### Tasks stuck in `processing/`

A task in `<wt>/.swarm/tasks/processing/` with no matching `done/` outcome means the worker died mid-run (container kill, `claude` crash, host reboot). To recover:

```bash
# Move it back to inbox so a fresh listener picks it up
mv <wt>/.swarm/tasks/processing/<id>.md <wt>/.swarm/tasks/inbox/
```

Or just write a fresh brief via `requeue.sh` — old briefs in `processing/` are not auto-retried.

### Ctrl-Z accidentally suspended claude inside a worker

Symptom: in an `iss-*` window you see something like:

```
Claude Code has been suspended. Run `fg` to bring Claude Code back.
Note: ctrl + z now suspends Claude Code, ctrl + _ undoes input.
```

…and `fg` does nothing useful. This means the tmux Ctrl-Z escape hatch binding (see [Advanced Usage → Worker Escape Hatch](./advanced-usage.md#worker-escape-hatch-ctrl-z-opens-a-sibling-bash-pane)) is **not loaded in the running tmux server** — Ctrl-Z passed straight through to claude in the container, which SIGSTOPped itself. Since the foreground process in the window is `docker run` (not a host shell), there's no job-control parent to type `fg` into.

> **The escape hatch is not a "drop to subshell".** Because each swarm uses a per-repo tmux socket (`tmux -L swarm-<repo>`), running `tmux source-file ~/.tmux.conf` on the default socket does **not** reload the binding on the swarm's actual server. Re-source on each running swarm socket too:
>
> ```bash
> for s in /tmp/tmux-$(id -u)/swarm-*; do
>     tmux -L "$(basename "$s")" source-file ~/.tmux.conf
> done
> ```
>
> Also note: if the path in the binding is wrong, Ctrl-Z creates a sibling pane that **dies instantly with `bash: line 1: …/tmux-worker-shell.sh: No such file or directory` (exit 127)**. Kill the dead pane and fix the path in `~/.tmux.conf`, then re-source on the swarm socket(s).

Verify the binding is missing:

```bash
tmux list-keys -T root | grep C-z      # empty → binding not loaded
```

Recover the suspended claude:

```bash
docker exec swarm-<session>-iss-N bash -c 'pkill -CONT -f claude'
# example: docker exec swarm-llm-fand-poc-iss-162 bash -c 'pkill -CONT -f claude'
```

Then install / reload the binding so this doesn't recur:

```bash
# Easiest: let the installer bake the right path in and reload every swarm socket.
./scripts/install-tmux-binding.sh

# Or, if you've already added the block manually, just reload on every socket:
tmux source-file ~/.tmux.conf
for s in /tmp/tmux-$(id -u)/swarm-*; do
    tmux -L "$(basename "$s")" source-file ~/.tmux.conf
done
tmux list-keys -T root | grep C-z      # should now show a binding
```

Common reason this happens: the binding was added to `~/.tmux.conf` *after* the current tmux server was started. tmux does not auto-reload config; `source-file` (or `Prefix-r` if you have the reload binding from the example config) picks up new bindings without restarting the server.

### Gemini `run_shell_command` rejects `$(...)`

Gemini-CLI's tool layer blocks command substitution as a safety guardrail. The coordinator system prompt tells gemini to invoke `provision-worker.sh <issue>` (a single command, no `$()`), which encapsulates all the substitutions internally. If you see gemini failing with `Operation cancelled` while trying to compose `$(git rev-parse ...)`, that's the cause — re-prompt it to use the helper script.

### Ripgrep fallback warning from gemini

```
Ripgrep is not available. Falling back to GrepTool.
```

The npm `@google/gemini-cli` package ships without its bundled ripgrep binary. Run `./scripts/setup.sh` on the host once after install and after every gemini-cli upgrade — it symlinks the system `rg` into the path gemini looks for.

---

## Host Sysadmin Issues

### OOM kills (host or container)

```bash
journalctl --since "1 hour ago" | grep -iE 'oom|killed process'
dmesg | grep -i 'killed process' | tail -20
```

If a *container* was killed: the host ran out of RAM/swap. Containers with `--network host` and no memory limit will use whatever's available, so a runaway worker can OOM the whole box. Check `free -h` and look at `/var/log/system-monitor.log` if you have the monitor service installed (see the main README in `/opt/work/sysadmin/`).

If the *host* OOM-killed something important, the swap and swappiness fixes documented in `/opt/work/sysadmin/README.md` apply.

### GPU lockups / `Xid` errors

Out of scope for the sandbox itself, but workers can trigger this if they invoke local LLM inference (ollama). See `/opt/work/sysadmin/README.md` — root cause was NVIDIA Xid 31 MMU faults compounded by VRAM exhaustion. The fix bundle is already applied on minti9.

### Docker daemon restarted — swarm died, socket left behind

**Symptom:** a swarm that was running yesterday is simply gone — no session, no worker windows — but its socket file still sits in `/tmp/tmux-$(id -u)/` (e.g. `swarm-myproject`), and `scripts/list-swarms.sh` reports it as `ORPHAN`. Worker containers all show `Exited` around the same timestamp in `docker ps -a`.

**Cause:** a Docker **daemon** restart (package upgrade, snap refresh, `systemctl restart docker`) stops every running container even though the host itself never rebooted. Swarm worker windows are container-backed panes, so they exit; once a session's last window closes, that swarm's per-project tmux server exits too — and tmux leaves the socket file of an exited server behind. Any swarm you relaunched afterwards looks fine; the ones you didn't become orphans.

**Confirm what happened:**

```bash
scripts/list-swarms.sh                     # LIVE vs ORPHAN per swarm socket
uptime -s                                  # host boot time — rules a reboot in or out
ps -o lstart= -p "$(pgrep -xo dockerd)"    # when the docker daemon (re)started
docker ps -a                               # workers all Exited near that time = daemon restart
```

If `uptime -s` is well before the swarm died but dockerd's start time matches the moment it vanished, it was a daemon restart, not a reboot.

**Recovery:** the stale socket file is harmless and needs no manual cleanup. `llm-start.sh` handles it end-to-end: its `tmux has-session` probe fails exactly as if no session existed, and the `tmux new-session` that follows detects the dead socket, unlinks it (tmux does this itself, under a lock), and starts a fresh server.

```bash
cd /opt/work/myproject
$LLM_SWARM_DIR/llm-start.sh "<your prompt>"   # just relaunch — stale socket auto-replaced
scripts/list-swarms.sh --prune                # optional: rm orphan socket files (cosmetic only)
```

Then deal with what the dead swarm left behind:

- **Worktrees** (`../wt-issue-*`) survive with any in-flight work. Check them for unpushed commits or open PRs before cleaning up; `scripts/reap-orphan-worktrees.sh` removes the ones whose work is preserved elsewhere.
- **Support containers** (project test DBs, compose services) died in the same restart and are *not* restarted by `llm-start.sh` — bring them up again if worker checks depend on them.
- **Listeners** don't come back on their own — see [Reviving listeners after a tmux session is killed](./advanced-usage.md#reviving-listeners-after-a-tmux-session-is-killed).

### tmux session vanished

Orphaned worktrees survive — only the session and listeners are gone. A common cause is a Docker daemon restart taking out every container-backed window — see [the previous entry](#docker-daemon-restarted--swarm-died-socket-left-behind). Recovery procedure is documented in `advanced-usage.md` → [Reviving listeners after a tmux session is killed](./advanced-usage.md#reviving-listeners-after-a-tmux-session-is-killed).

---

## Placeholders

Issues we expect to be rare. If you hit one, please open an issue and we'll expand the entry.

- **[placeholder] Worker uses wrong git identity** — workers inherit `~/.gitconfig` from the host. If commits land under the wrong name/email, check the host's global config.
- **[placeholder] Testcontainers can't reach mapped ports** — `TESTCONTAINERS_HOST_OVERRIDE=localhost` is set automatically. If it's still failing, the port may be claimed by another worker (per-worktree port offsets via `.env` in compose projects help).
- **Testcontainers fails with "client version 1.32 is too old"** — Docker Engine 25+ rejects API versions below 1.40, but Testcontainers' shaded docker-java client defaults to 1.32. `sandbox.sh` now sets `_JAVA_OPTIONS=-Dapi.version=1.45` automatically whenever the Docker socket is mounted, which fixes this for the majority of projects. If you still see the error, your project may be clobbering `_JAVA_OPTIONS` from its `build.gradle.kts` (or from a parent `init.gradle`); either bump it there, or — preferred — add a project-level pin on the test JVM: `tasks.withType<Test> { systemProperty("api.version", "1.45") }`. The shaded `org.testcontainers.shaded.com.github.dockerjava.core.DefaultDockerClientConfig` reads this system property at client init.
- **[placeholder] OpenBrain MCP not visible to worker** — worker inherits `~/.gemini` (ro) for shared MCP config. If worker's `claude` doesn't see it, confirm the MCP is configured in the user-level (not project-local) claude config.
- **[placeholder] `EXTRA_MOUNTS` path with spaces** — not currently quoted-safe in `sandbox.sh`. Avoid spaces in mount paths for now.
- **[placeholder] Coordinator wakes itself in a loop** — `coordinator-watch.sh` has a 30s debounce, but a misconfigured prompt that *creates* `done/*.json` files could in theory loop. Use `DRY_RUN=1` to inspect first.
- **[placeholder] Worker on a feature branch that was force-pushed** — git inside the container will see a divergent history. Recover by deleting the worktree (`kill-worktree.sh`) and re-provisioning.
