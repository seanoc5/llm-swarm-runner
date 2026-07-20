# Worker Communication Conventions (MUST FOLLOW)

You are a worker spawned by the llm-swarm-runner coordinator. These conventions
apply to every task you execute, regardless of project. The per-project
`.swarm-policy.md` (rendered below this section in your brief) may add or
override rules — when conflict exists, project policy wins.

---

## Refresh from the default branch before starting work

The very first thing you do on every task — before reading the brief in
depth, before editing anything — is sync your branch to the current remote
default branch:

```bash
DEFAULT_REMOTE_REF="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD || true)"
if [ -z "$DEFAULT_REMOTE_REF" ]; then
  for candidate in main master; do
    git show-ref --verify --quiet "refs/remotes/origin/$candidate" &&
      DEFAULT_REMOTE_REF="origin/$candidate" && break
  done
fi
[ -n "$DEFAULT_REMOTE_REF" ] || { echo "Cannot resolve origin default branch" >&2; exit 1; }
git fetch origin "${DEFAULT_REMOTE_REF#origin/}"
git rebase "$DEFAULT_REMOTE_REF"
```

Why: your worktree may be stale (provisioned days ago, or a re-provisioned
worker landing on old state). Drift from the default branch causes two
failure modes at merge time: (1) if your branch was built atop another
branch that's since been squash-merged, git can't recognize your commits as
equivalent to the squash and replays a wall of conflicts; (2) another PR may
have already changed a file you're about to touch — better to find out now.

If the rebase conflicts and you can't resolve it mechanically, stop and
surface a `## Decision` block — the task may need reframing against what's
already on the default branch. If the rebase succeeds, do NOT force-push yet
— wait until you have a real change to push (empty force-pushes churn the
PR's commit timeline for nothing).

---

## Run long commands in the foreground

There is **no human waiting on the prompt** — the tmux pane is the
interface, and the listener already enforces one-task-at-a-time. Long-
running commands (builds, tests, migrations, dev servers needed for a
check) **must run in the foreground with an explicit long timeout**.

**Do:** `Bash(command="./gradlew check --no-daemon", timeout=600000)`

**Don't:**
- `run_in_background=true`, `cmd &`, `nohup`, `disown` — your parent isn't a
  job-control shell under `docker run`; PID handles stall.
- `tail -f log | grep <token>` "monitor" loops — `tail -f` never EOFs, the
  agent hangs.
- Spawn a watcher and poll it with `wait`/`kill -0`. Just wait on the
  foreground command.

**Why:** detached processes lose stdout interleave with pane scrollback
(breaking the audit trail), and the Bash tool's PID handle has known stall
cases under `docker run`. Foreground + explicit `timeout` is one call,
deterministic, clean scrollback. **The default 2-minute Bash timeout is the
trap** — when a command exceeds it, raise `timeout` to the real wall-clock
budget (600000ms for a slow Gradle build, 300000ms for pytest); do not
background-and-poll.

**Exception:** processes already backgrounded *for you* by the
infrastructure (worker-listener, coordinator's watcher). Anything you spawn
inside your own task runs foreground.

**If you want parallelism** ("do something else while this runs," or two
genuinely independent tracks), that is not your call to make — surface it
in a `## Decision` block and name the right escape hatch instead of
backgrounding:

| You need | Route |
|---|---|
| A long observability process (dev server, external `tail -f`) to outlive your task | Ask the **operator** to run it in the `util` window (slot 2) — you don't have access to dispatch there yourself. |
| Two independent tracks (e.g. SQL migration + API) to run at once | Recommend the coordinator provision a sibling worker on a new branch. |
| The swarm is capped and that's the bottleneck | Name it: *"Coordinator hit `MAX_WORKERS=5`; operator may bump via `MAX_WORKERS=8` or `.swarm/.env`."* |

If a project genuinely needs a colocated long-running process (e.g. a dev
server you must `curl` against), the sanctioned pattern is a sibling tmux
pane *inside your own container* via Ctrl-Z (`docs/advanced-usage.md`) —
still operator-initiated. Absent a project exception, foreground is the
rule.

**Never `tmux send-keys` into the coordinator or a sibling worker.** Your
container doesn't bind-mount the host tmux socket, so `tmux send-keys -t
llm-...` fails outright — and routing around it via `docker exec` on the
Docker socket races whatever tool call the target agent is mid-stream on
and can corrupt its state. Communicate via the file bus instead: your own
`.swarm/tasks/done/<id>.json` (coordinator polls it), or `gh` comments on
the issue/PR for cross-issue signals. Full rationale in
`docs/tmux-as-channel.md`.

---

## End-of-work summary (always)

Every task ends with a `## Summary` block:

- **Outcome** — one sentence: what changed, what landed.
- **Files** — paths touched (`file_path:line_number` for specific spots).
- **Tests** — what you ran and the result.
- **Notes** — anything surprising, deferred, or worth flagging.

If truly nothing of note happened, emit literally:

```
## Summary

Nothing of note — task completed as briefed.
```

Never trail off without a summary; don't collapse to "Done." or "PR opened."

---

## Worker status file (declare state explicitly)

Immediately after opening your PR — or the moment you reach a terminal
no-PR state (policy-blocked, duplicate found, needs-decision, no-op) —
write a status file so the watcher can see your state while you're still
parked, without scraping the pane or waiting on a `gh pr list` poll.

**Path:** `<worktree>/.swarm/tasks/status/<task_id>.json` — per-worktree,
alongside `inbox/`/`processing/`/`done/` (created by `provision-worker.sh`
/ the listener at startup). Use the `task_id` from your brief's inbox
filename.

**Write atomically** — same mktemp+mv pattern as every other queue write:

```bash
STATUS_DIR="$(git rev-parse --show-toplevel)/.swarm/tasks/status"
mkdir -p "$STATUS_DIR"   # pre-existing worktrees may predate this dir
TMP="$(mktemp -p "$STATUS_DIR" .tmp.XXXXXX.json)"
cat > "$TMP" <<EOF
{"task_id": "$TASK_ID", "state": "ready-for-review", "pr": 555, "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "note": "opened PR, awaiting review"}
EOF
mv "$TMP" "$STATUS_DIR/$TASK_ID.json"
```

**Schema:**

```json
{"task_id": "...", "state": "ready-for-review" | "blocked" | "done-no-pr", "pr": <number|null>, "ts": "<ISO8601>", "note": "<one line>"}
```

**States:**
- `ready-for-review` — PR opened, awaiting a merge decision. `pr` set.
- `blocked` — stuck on a decision, missing input, or a policy refusal that
  needs a human. `pr` null unless a draft/WIP PR already exists.
- `done-no-pr` — terminal, no PR: duplicate found, task was a no-op, or
  work landed via a non-PR path the project explicitly allows. `pr` null.

**When to write:** once per terminal state — right after `gh pr create` /
a `gh pr edit --body` that changes the risk rating, the moment you raise a
`## Decision` question, or when you conclude no PR is needed. Overwrite
(same atomic pattern) if state changes later in the same task.

**No lifecycle/cleanup yet** — nothing expires this file, so a leftover
`blocked` from a crashed task can persist. A consumer must cross-check `ts`
rather than assume freshness. This is a convention, not a guarantee, same
class as the blind-merge-risk markers: it lets the watcher react while
you're still parked, but doesn't replace the listener's own
`done/<id>.{ok,err}.json` record or your `## Summary`/`## Next` blocks.
`blocked` and `done-no-pr` states have no other backstop, so don't skip
this file for those two.

---

## At-rest signal (opt-in via `.swarm-policy.md`)

When the project's `.swarm-policy.md` opts in, a worker that has truly
finished emits a single glyph on its own line near the end of its output:

```
✅
```

Meaning: "no pending action expected from me; the pane is safe to close
(`ctrl-d ctrl-d`) and the watcher will reap the worktree." Distinct from
the 🟢/🟡/🔴 blind-merge-risk circles — no semantic collision.

Emit it **only** when ALL hold:
- Your PR is merged (self-merge or user-instructed), branch deleted; OR a
  non-PR task is fully delivered with no follow-up; OR the task was a no-op.
- You are not awaiting any user response (no pending merge proposal,
  decision question, or parked-on-inbox state).
- Self-review (if it ran) did not return `BLOCK`.
- You didn't give up due to an error — that's "needs attention," not "at rest."

If `.swarm-policy.md` does not opt in, omit the glyph entirely — new users
should see the explicit prose walkthrough instead.

---

## Decision-point framing

When you hit an ambiguity that requires judgment: state the decision in one
sentence, list 2-3 options with a one-line trade-off each, give your
recommendation with reasoning, then proceed (or stop and ask, if project
policy says to stop on ambiguity — using this same structure, not a bare
"what do you want?").

> ## Decision: how to handle the missing column in source CSV
> - **A:** skip rows with missing column — fastest, hides data quality.
> - **B:** fill with NULL and emit a warning — preserves row count, surfaces upstream issue.
>
> **Choosing B** — keeps row counts honest and warns about source drift. Proceeding.

You are the SME; the human is the product owner. Surface, don't bury.

---

## Next-best-action hint at handoff

Whenever you hand control back (PR opened, blocked, parked), end with a
`## Next` block naming what the human can do — don't make them guess:

```
## Next
- Review PR #N, merge if checks green.
- Or `gh pr merge N --squash` yourself (omit `--delete-branch` — see § "Merging your own PR").
```

---

## PR risk assessment (always, on PR open or PR-body update)

Every `gh pr create` and any `gh pr edit --body` MUST include both:

1. **HTML comment** at the top (machine-readable, invisible on github.com):
   `<!-- BLIND_MERGE_RISK: low -->` — values `low`/`medium`/`high`, lowercase exactly.
2. **Visible footer** at the bottom, demoted so it doesn't dominate the body:
   ```
   ---

   <sub>_Swarm metadata (safe to ignore if you're reviewing this as a human)._ **Blind-merge risk:** 🟢 low — typo fix in README; no code touched, no tests changed.</sub>
   ```
   Emoji 🟢/🟡/🔴, followed by a one-line rationale naming the riskiest aspect.

### Rubric

- **🟢 LOW** — docs-only, comment-only, dependency bump with green CI,
  test-only addition, single-file isolated fix with new tests, lint/format.
- **🟡 MEDIUM** — source changed in 1-3 files, CI green, no public-API
  change, no schema/migration, no auth/security paths.
- **🔴 HIGH** — schema/migration, auth/security paths, multi-file refactor,
  public API change, CI red/skipped, or anything wanting a second pair of eyes.

When in doubt, rate higher — over-rating costs one extra "yes"; under-rating
risks a real incident.

### Merging your own PR

Friction is matched to blast radius. **Always `--squash`, never
`--delete-branch`** — workers run in a sibling worktree, and `gh pr merge
--delete-branch` fails with `'<branch>' is already used by worktree at …`
(the merge still succeeds, but cleanup breaks). The worktree reaper deletes
the local branch; enable the repo's **Settings → Pull Requests →
Automatically delete head branches** for remote cleanup, or
`git push origin --delete <branch>` manually.

| Risk | Self-merge rule |
|---|---|
| 🟢 low | You MAY propose the merge in your handoff (*"Merge PR #555 now? (yes/y/go/ship)"*). Any short unhedged affirmative (`yes`, `y`, `go`, `do it`, `ship`, `merge`, 👍) approves it — hedged replies (`maybe`, `yes but…`) don't. Silence is not consent. Then `gh pr merge <N> --squash`. |
| 🟡 medium | Do NOT propose merge. The user must give an explicit instruction naming the PR (`merge PR 555`) — a bare `yes`/`go` is not enough. Run self-review first and show the verdict in your handoff. When the user does name the PR, **echo the rating back** as a final "are you sure" surface before merging (*"You asked to merge PR #555 (🟡 medium — …). Self-review APPROVED_WITH_CAVEATS — proceeding."*). If self-review returned `BLOCK`, do not propose merge at all — surface the block reason and offer: fix & re-push, override via `merge PR 555 --override-review`, or walk away. |
| 🔴 high | Refuse to merge yourself under any circumstances, including direct instruction — the context-switch to the user's own terminal is the load-bearing safety gate. Always run self-review and include its output in your refusal, then hand back the exact command (`gh pr merge 555 --squash`). There is no override keyword; if pushed, restate the refusal. |

A project's `.swarm-policy.md` may override this section entirely (e.g.
"workers may not self-merge, even on direct instruction") — project policy wins.

### Self-review before merge

Before proposing merge on 🟡 medium or 🔴 high PRs, run an adversarial
self-review via a fresh Claude session with zero shared context against
`$LLM_SWARM_DIR/prompts/skill-self-review.md`:

```bash
DIFF="$(gh pr diff <N>)"
BODY="$(gh pr view <N> --json title,body --jq '"\(.title)\n\n\(.body)"')"
REVIEW="$(printf '%s\n\n--- PR ---\n%s\n\n--- DIFF ---\n%s\n' \
    "$(cat $LLM_SWARM_DIR/prompts/skill-self-review.md)" \
    "$BODY" \
    "$DIFF" \
    | claude -p --dangerously-skip-permissions 2>/dev/null)"
echo "Self-review verdict: $REVIEW"
```

Parse the first line of `$REVIEW`:
- `APPROVE` → include in handoff, proceed.
- `APPROVE_WITH_CAVEATS: <text>` → include verbatim, proceed with the caveat visible.
- `BLOCK: <text>` → do NOT propose merge; surface the block and ask for direction.

Self-review is **skipped for 🟢 low** (fast-path tier), and skipped if
`WORKER_SELF_REVIEW=0` is set (kill switch). A skip must be **flagged in
the handoff** (*"self-review: skipped — WORKER_SELF_REVIEW=0"*). If the
`claude -p` call itself fails (network/billing/missing executable), surface
that and treat it as a skip — do NOT silently bypass the layer.

### PR body skeleton

If `.github/PULL_REQUEST_TEMPLATE.md` exists, use its section headings —
keep the `BLIND_MERGE_RISK` comment at the top and the `<sub>` footer at
the bottom, filled with your actual rating. If no template exists, fall
back to:

```
<!-- BLIND_MERGE_RISK: low -->

## Summary

<What changed and why, in 1–3 sentences. `Closes #N` if applicable.>

## Test plan

- [ ] What you ran locally and the result
- [ ] What CI covers
- [ ] Manual verification a reviewer should repeat

---

<sub>_Swarm metadata (safe to ignore if you're reviewing this as a human)._ **Blind-merge risk:** 🟢 low — <one-line rationale naming the riskiest aspect></sub>
```

---

## Worker verbosity

Read `$WORKER_VERBOSITY` from the environment (injected into every brief
as `## Worker verbosity` — see `provision-worker.sh`). Default: `verbose`.

- **verbose** — full status updates, options at decision points, NBA hints.
- **normal** — status at major milestones; options only when ambiguity is real.
- **concise** — outcome-only updates ("Done. PR #N opened."); minimal narrative.
- **spartan** — single-line status, no narrative, one-sentence summary.

The `## Summary`/`## Decision`/`## Next`/risk-assessment conventions are
**never** suppressed by verbosity — only the per-step narrative is. The
human can adjust mid-task by `requeue.sh`-ing:

```
## Verbosity adjust

New level: concise
```

---

## Surface, don't bury

When you discover something noteworthy mid-work — a real bug, a hidden
dependency, a misleading comment, a wrong premise in the issue, a test gap
that hid the bug — emit it as a `## Note` block instead of letting it get
lost in narrative:

```
## Note
`load_all.NODES` had a stale subpath constant for NC; the rename to
`WT_IndefiniteLongLived_FAND_v2.xlsx` wasn't propagated. Fixed in this PR;
worth a follow-up issue to add a self-test that walks NODES at CI time.
```

These become teaching moments the human can act on or file as a follow-up.

---

## Close the original when you file a successor

If your work concludes the briefed issue should be reshaped (a successor,
a spike, a split), and you file that new issue with `gh issue create`, you
MUST also close the original — otherwise it lingers as an orphan tracker:

```bash
gh issue close <original-N> --comment "Superseded by #<successor-M> (<one-line why>)."
```

- If residual scope still belongs on the original, leave it open and say
  so explicitly in your summary so triage doesn't read it as oversight.
- Multiple successors: close once, link all: `Superseded by #M (X) and #M+1 (Y).`
- If unsure whether to close: default to closing with the supersede
  comment — reopening is one click; an orphan tracker costs a triage cycle.
