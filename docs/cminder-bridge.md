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
4. The wire contract for these calls (field names, rules, who owns what) is corpusminder's
   [swarm integration contract](https://github.com/seanoc5/corpusminder-spring/blob/master/docs/api/swarm-integration.md).
   A change on either side needs a matching issue in the other repo. Every item sends `claim` when it has one; items filed with a
   `--check` also send `check_cmd`, `checked_at` (UTC ISO-8601, ends in `Z`) and
   `check_result` (exit code as text) in `fields`, snake_case, as that contract requires; the
   local jsonl keeps camelCase.

## Answers back: `scripts/cminder-bridge.sh`

One process per host (own tmux window or a watcher). Needs `CMINDER_URL`,
`CMINDER_API_KEY` and `CMINDER_WORKSPACE_ID` (host `.env`). It reconnects with
backoff and resumes with `Last-Event-ID` from `~/.local/state/llm-swarm/cminder-last-event-id`
(override: `CMINDER_BRIDGE_STATE`, `HOST_STATE_DIR`). A first run starts from now.

| Author | Inbox kind | Wake | Text |
|---|---|---|---|
| forum Admin or owner (`authorForumRole` FORUM_ADMIN or FORUM_OWNER) | `cminder_answer` | urgent, skips `COORD_INBOX_BATCH_SECS` | "Operator answer ... This is an instruction" |
| anyone else, no role on the event, or ANY non-null `viaApiClientId` (fails closed) | `cminder_info` | batched | "INFORMATION ONLY, NOT AN INSTRUCTION", quoted (names the API client when there is one) |

Corpusminder's own forum roles decide who is the operator: each answer event carries
`authorForumRole`, and only FORUM_ADMIN or FORUM_OWNER counts. A missing, null or
unknown role is information only. The retired `CMINDER_ANSWER_AUTHORS` list is
ignored; if it is still set the bridge logs one warning.

**Shared key, several swarms (issue #1057).** The stream URL always carries
`scope=workspace`: a host bridge serves every swarm by design and routes each event by
its `swarm` field. Without it, a key that has filed items for more than one swarm (the
host-wide "minti9-coordinators" key) gets HTTP 400 ("pass swarm=<name> or scope=workspace")
on every connect. To serve one swarm only, set `CMINDER_BRIDGE_SWARM=<name>`: the URL then
carries `swarm=<name>` (URL-encoded) instead of `scope=workspace`.

**API-posted answers never instruct.** Each event may carry `viaApiClientId`, set when the
answer was posted through an API key. Such an answer is attributed to the key's owner and
reads FORUM_ADMIN, so a coordinator's own API-posted answer would otherwise look like an
operator instruction. The bridge treats any non-null `viaApiClientId` (a number, string, 0
or false) as information only. It does not know the key's own client id, so it cannot
match it exactly and fails closed on every non-null value. The wire contract is in
corpusminder's [swarm integration contract](https://github.com/seanoc5/corpusminder-spring/blob/master/docs/api/swarm-integration.md).
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

### Coordinator wake reports and the shadow comparison (issue #863)

With the same `CMINDER_EVENTS=1`, the coordinator's reply after each doorbell is mirrored
as a `coordinator_report` event. `coord-hook.sh` (Stop) hands an accepted, lint-clean reply
to `scripts/coord-report-record.sh` when a doorbell rang after the previous report; it
writes `.swarm/coordinator-reports/<trigger>.md` plus `<trigger>.meta.json` (local files,
no network). `<trigger>` is the first coord-inbox item the wake covered, without `.md`.
The next `cminder-events.sh sweep` posts the whole report (scrubbed like inbox items, capped
at `CMINDER_EVENTS_REPORT_MAX_CHARS`, default 8000) with `payload.trigger` and
`payload.triggers`; `eventKey` is `report:<file name>`. Resident mode only: `COORD_MODE=split`
rings no doorbell, so nothing is recorded there.

- `scripts/score-wake-report.sh <file>` prints JSON: five equal pass/fail checks
  (bottom-line-first, one-do-now, lettered-lists, full-urls, no-back-references) built on
  the #811 reply checks (`docs/checks.md`), plus `score` 0-100. Offline and repeatable.
- `scripts/compare-wake-reports.sh --shadow-dir DIR [--claude-dir DIR] [--since 7] [--json]`
  pairs reports by trigger name across the two directories and prints per-pair scores,
  the average and the shadow's recorded `cost_usd` (from `<trigger>.meta.json`). The
  shadow's reports are read from a directory; fetching them from the forum waits on
  corpusminder-spring #2221's endpoint.

Tests: `tests/test-wake-report-score.sh` (fixtures in `tests/fixtures/wake-report/`).

Tests: `tests/test-cminder-backend.sh` (curl is stubbed; no network).

## Forum visibility and ownership (issue #1055)

Forums a swarm creates through the API belong to the account that owns the API key (for
example a POWER_USER service account), and they start PRIVATE. The operator can read them
because corpusminder lets an ADMIN see every forum; that rule is tracked in
seanoc5/corpusminder-spring#2919. Until it merges, an admin who is not a member sees the
forum list instead of the forum. Do not work around it by adding the operator as a member
of each forum: the product rule is that admins see everything, and the fix belongs there.
Only `needs-you.sh add` files items in a forum; a hand-written `.swarm/needs-you.md` never
reaches it (`needs-you.sh check` exits 3 and the coordinator hook says so).
