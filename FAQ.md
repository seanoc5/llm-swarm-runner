# FAQ

A few starter questions about the llm-swarm-runner. See the [README](./README.md) and
[docs/architecture.md](./docs/architecture.md) for the long version.

### What does the swarm coordinator do?

The coordinator is a one-shot triage agent: it wakes, reads project state (via `git` and
`gh`), provisions any worker agents needed for open issues, and exits. Workers then run
asynchronously in their own dockerized git worktrees, and the event-driven watcher
(`coordinator-watch.sh`) re-wakes the coordinator whenever a worker finishes so the swarm
stays topped up.

### How do I add a new worker?

Workers are provisioned by [`scripts/provision-worker.sh`](./scripts/provision-worker.sh),
which the coordinator invokes automatically when it dispatches an issue. You don't usually
call it by hand — start the swarm with `./llm-start.sh` and let the coordinator decide how
many workers to spin up (bounded by `MAX_WORKERS` and `MAX_TMUX_WINDOWS`).

### Where do worker outcomes get written?

Each worker writes its outcome JSON into its worktree's `.swarm/tasks/done/` directory.
The watcher monitors those paths across all live workers; when a new outcome appears it
debounces (`DEBOUNCE_SECS`) and wakes the coordinator to triage what's next.
