# Demo script — August 2026 refresh ("the self-healing swarm")

Companion to [`demo-recording.md`](./demo-recording.md) (capture mechanics —
SSR setup, rects, post-processing). This file is the *content*: shot list,
narration beats, and the evidence artifacts for Segment B. Target total
runtime **4–5 minutes**.

Framing rule (from [ADR 0004](./adr/0004-positioning-vs-native-claude-code-swarms.md)):
open by conceding native swarms exist and are simpler in-session; this demo
shows the *process layer* — durable queue, human gates, and what those buy
when things break. Never claim model-selection or cost advantages.

## Segment A — the scripted core (~90s)

The existing `demo-driver.sh` flow, unchanged in structure (see
demo-recording.md pre-flight; demo-fodder issues #152/#155 are open):

1. `llm-start.sh` against this repo — coordinator triages, reports
   `OPEN/AVAILABLE/ALIVE/WINDOWS`.
2. Worker dispatched into its worktree window; brief lands via task queue.
3. Cut between coordinator pane and worker pane while the worker codes.
4. Worker opens a 🟢 low-risk PR — pause on the PR body: BLUF screen,
   folded appendix, `BLIND_MERGE_RISK` marker.
5. Merge via the reply verb; watcher reaps the window; PR list closes the loop.

Narration beat: "issues in, risk-rated PRs out — nothing here lives in a
context window."

## Segment B — the incident (~2.5 min, the differentiator)

True story, 2026-08-10 → 2026-08-13, all artifacts public in this repo.
Show, don't claim:

1. **Symptom** (screenshot or live pane): a worker pane with repeated
   `/compact` → "Not enough messages to compact", statusline `ctx: 0/1M`.
2. **Evidence trail** (terminal): `grep 'issue=64' .swarm/events.log` in the
   civicstrata project — `worker.compact` at 151k/217k, both ending
   `worker.compact.timeout phase=start`, then the 600s backoff skips doing
   their job. Narration: "structured event log, not vibes."
3. **Root cause** (browser or `gh issue view 266`): Claude Code 2.1.x
   removed the "(esc to interrupt)" spinner hint the busy-detector anchored
   on — verified by `strings` on the CLI binary and a live TUI experiment,
   all written into issue #266 with the patch.
4. **The swarm fixes the swarm**: PR #268 — a worker applied the verified
   patch; merged same day. Then the operator-visible part: six watcher
   processes across six project swarms respawned in place, each picking up
   the fix (`respawn-pane` on each `util.1`).
5. **Defense in depth**: issue #265 — the *next* failure of this class
   degrades to a no-op instead of queueing stale commands.

Narration beat: "the queue, the diagnosis, and the fix all lived in git and
GitHub — three different Claude sessions handled this incident and none of
them needed the others' memory."

## Segment C — honest close + CTA (~30s)

- Concede the cons on screen (from ADR 0004): infrastructure cost, TUI
  brittleness — "this exact incident is the failure class native swarms
  don't have."
- CTA (tiered, per the announcement post): "Knowing Claude Code has swarms
  built in — would you run this? What would stop you from setting it up
  tonight? Repo link below; issues and brutal comments both welcome."

## Recording checklist deltas vs. demo-recording.md

- [ ] Segment B needs the civicstrata project's `.swarm/events.log` intact —
      record before any log rotation/cleanup.
- [ ] Pre-open `gh issue view 266` / PR #268 in the browser to avoid live
      network stalls on camera.
- [ ] Segment A still uses the demo-labeled fodder issues; confirm #152/#155
      remain open before the take.
