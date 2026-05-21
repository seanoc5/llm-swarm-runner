# Security Considerations

> **TL;DR:** Agents are treated as **trusted-but-fallible**, not adversarial. The container limits blast radius from honest mistakes (typos, hallucinated `rm -rf`) but is **not** a security boundary against a hostile/compromised agent — `--network host`, `~/.claude` rw, and Docker-out-of-Docker mean a sufficiently-capable hostile agent can escape. See below for the full risk model.

When giving an autonomous AI tool access to your filesystem, security must be a primary concern. This document outlines the security boundaries and risks associated with `llm-swarm-runner`.

## Core Security Model

*   **Runs as your host UID/GID:** The sandbox runs processes using your exact User ID and Group ID. This ensures file permissions inside and outside the container match perfectly, but it also means the agent has the exact same file-level access rights as you do for any mounted directories.
*   **Containment via Mounts:** The blast radius is limited strictly to the directories you bind-mount. By default, this is only the `$PROJECT_DIR`. The agent cannot accidentally `rm -rf /` your host machine.

## Known Risks and Caveats

### `--dangerously-skip-permissions` / `--yolo`
Claude Code and Gemini CLI run in auto-approve mode inside the sandbox. This is the primary reason the sandbox exists. However, review what the agent is doing periodically. The sandbox does not prevent destructive file operations (like deleting all your source files) *within the mounted project directory*.

### Network Host Mode (`--network host`)
The container shares the host network stack. This is incredibly convenient for local development (e.g., the agent can connect to `localhost:5432` to query your local Postgres database), but it means the container is not network-isolated. 
*   **Risk:** An agent could theoretically attempt to interact with other local services running on your machine.
*   **Suitability:** This is appropriate for a local dev tool running trusted code on your workstation. It is **not** suitable for running entirely untrusted workloads or internet-facing services.

### Docker-outside-of-Docker (DooD)
Mounting `/var/run/docker.sock` gives the container full Docker daemon access. This is inherent to the DooD pattern and unavoidable if you need Testcontainers or the ability to build Docker images inside the sandbox.
*   **Risk:** Anyone with access to the Docker socket can theoretically achieve root access to the host machine by spinning up a privileged container. 

### Read-Only Credentials
*   **SSH keys:** Mounted `ro` (read-only). The agent can use them to sign commits or push to GitHub, but it cannot modify them.
*   **Exfiltration:** While credentials cannot be modified, an actively malicious agent *could* theoretically read them and exfiltrate them via the network. You must trust the LLM provider (Anthropic, Google) you are using.

### Tmux Scrollback Exposure
The swarm runs every agent inside a tmux pane on a per-repo socket at `/tmp/tmux-<uid>/swarm-<repo>`. The socket inherits the standard tmux `srwxrwx---` mode — readable by your UID only, which matches the single-user-workstation threat model the rest of this doc assumes.

*   **What's exposed:** every line every agent prints — coordinator reasoning, worker tool calls, error messages, and anything claude/gemini echoes from `gh`, `git`, `cat`, etc. — lives in pane scrollback for the life of the session (50000 lines by default; see [`examples/tmux.conf.example`](../examples/tmux.conf.example)). `remain-on-exit failed` keeps that scrollback readable after the agent dies. Anyone who can `tmux -L swarm-<repo> attach` (i.e. anyone on the host with your UID, plus root) can read all of it.
*   **Visibility is asymmetric.** The coordinator runs **host-native** and has unrestricted access to the swarm's tmux socket — it can `capture-pane` any worker. **Workers cannot read each other's tmux panes** (their containers don't bind-mount the host tmux socket — see [`sandbox.sh`](../sandbox.sh) mounts). Workers *can* still observe each other through `/var/run/docker.sock` (`docker exec`, `docker logs`) — that's a separate concern covered under [DooD](#docker-outside-of-docker-dood) above and has a larger blast radius than tmux visibility.
*   **Practical consequence:** if a worker `echo`s a secret (an API key from `.env`, a token from `gh auth token`, a DB password from environment), that secret is now in pane scrollback on the host until the tmux server exits — including after `git secrets` or `git filter-repo` would have scrubbed it from the repo. If you share the host (sudo, ssh-as-other-user, root-running services), assume tmux scrollback is one of the things they can read.
*   **Mitigation if needed:** lower `history-limit`, disable `remain-on-exit`, or kill swarm tmux servers (`tmux -L swarm-<repo> kill-server`) when you walk away. For most single-user workstations this is left as-is because the diagnostic value of the scrollback (see [overview → "Tmux as substrate"](./llm-swarm-runner-overview.md#tmux-as-substrate-not-just-a-ui)) outweighs the exposure.