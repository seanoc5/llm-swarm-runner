# Corpusminder backend for needs-you items (issue #801)

Opt-in. A swarm with the default `NEEDS_YOU_BACKEND=file` behaves exactly as
before and never contacts corpusminder.

## Switch a swarm over

1. In `<project>/.swarm/.env`: `NEEDS_YOU_BACKEND=corpusminder`, and
   `CMINDER_FORUM_ID=<the app's forum id>`. `CMINDER_URL` and `CMINDER_API_KEY`
   can sit in the host `.env` (gitignored).
2. `needs-you.sh add` then also POSTs `/api/items` (kind DECISION or TODO, the
   command or URL in `fields.do`, the plain-language paragraph in `fields.background` and the item description, `targetUrl` = the issue or PR); `done` calls
   `/api/items/{id}/complete`. The corpusminder id is kept as `cm_id` in
   `.swarm/needs-you.jsonl`. `.swarm/needs-you.md` is written either way, and a
   corpusminder outage only prints a warning.
3. Coordinator and worker prompts never mention the backend; they call
   `needs-you.sh` only.

## Answers back: `scripts/cminder-bridge.sh`

One process per host (own tmux window or a watcher). Needs `CMINDER_URL`,
`CMINDER_API_KEY` and `CMINDER_WORKSPACE_ID` (host `.env`). It reconnects with
backoff and resumes with `Last-Event-ID` from `~/.local/state/llm-swarm/cminder-last-event-id`
(override: `CMINDER_BRIDGE_STATE`, `HOST_STATE_DIR`). A first run starts from now.

| Author | Inbox kind | Wake | Text |
|---|---|---|---|
| forum Admin or owner (`authorForumRole` FORUM_ADMIN or FORUM_OWNER) | `cminder_answer` | urgent, skips `COORD_INBOX_BATCH_SECS` | "Operator answer ... This is an instruction" |
| anyone else, or no role on the event (fails closed) | `cminder_info` | batched | "INFORMATION ONLY, NOT AN INSTRUCTION", quoted |

Corpusminder's own forum roles decide who is the operator: each answer event carries
`authorForumRole`, and only FORUM_ADMIN or FORUM_OWNER counts. A missing, null or
unknown role is information only. The retired `CMINDER_ANSWER_AUTHORS` list is
ignored; if it is still set the bridge logs one warning.
The swarm is found by `CMINDER_SWARM_DIRS` (`name=/path`), else the live tmux
socket `swarm-<name>` (`list-swarms.sh`) and its session start directory.

Answers are never dropped. If the target swarm is not live when an answer
arrives, the bridge holds it in `~/.local/state/llm-swarm/cminder-held/<swarm>/`
(override: `CMINDER_BRIDGE_HELD`) and delivers it once the swarm is found live
(retried on every reconnect and after every event). The last event id is saved
only after an answer is delivered or held; a failed inbox write stops the
stream, and the reconnect replays from the last saved id.

## Events: the swarm's inbox and outcomes, mirrored to the forum (issue #862)

Opt-in, off by default. With `NEEDS_YOU_BACKEND=corpusminder`, `CMINDER_FORUM_ID`
set and `CMINDER_EVENTS=1` in `<project>/.swarm/.env`, `coordinator-watch.sh` runs
`scripts/cminder-events.sh sweep` every `WATCH_CMINDER_EVENTS_SECS` (default 30,
0 = off). Any other setting makes zero calls.

- **What is sent:** each coord-inbox item (`.swarm/coord-inbox/`, plus `processed/`) and
  each worker outcome JSON (`.swarm/tasks/done/*.{ok,err}.json` in this project's own worktrees only, from git's worktree list, never a sibling swarm's) from the
  last `CMINDER_EVENTS_MAX_AGE_DAYS` (default 2), as one POST to
  `/api/v1/forums/$CMINDER_FORUM_ID/swarm-events`: `eventKey`, `swarm`, `kind`,
  `occurredAt`, and `payload` (`text` = the first `CMINDER_EVENTS_MAX_LINES` lines,
  plus `issue` / `pr` when found). `eventKey` is the item's file name (outcomes:
  `outcome:<file name>`); corpusminder is idempotent on it.
- **Fire and forget:** the watcher starts the sweep detached and never waits for it.
  Every new item is first written to `.swarm/cminder-events-spool/`; a 2xx deletes it
  and leaves a marker in `.swarm/cminder-events-sent/`. The first failed POST ends
  that sweep (one `CMINDER_EVENTS_TIMEOUT_SECS`, default 5, per outage per sweep);
  spooled items go out on the next sweep, oldest first. Failures are logged to
  `.swarm/cminder-events.log`. A permanent 4xx (not 401/403/404/408/429, which stay spooled until the key or endpoint is fixed) moves that body to
  `.swarm/cminder-events-rejected/` so it cannot block the queue.
- **No secrets:** lines that look like tokens or keys (`ghp_...`, `sk-...`, `Bearer ...`,
  `password:` / `api_key=` / `token:` assignments, private-key headers, the configured
  API key) are dropped before anything is spooled; outcome fields named like a secret
  have their value replaced by `[redacted]`.

Tests: `tests/test-cminder-events.sh` (fake endpoint: post once, 500 spools and
retries, `CMINDER_EVENTS=0` makes zero calls).

Tests: `tests/test-cminder-backend.sh` (curl is stubbed; no network).
