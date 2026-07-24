# Worker Communication Conventions (MUST FOLLOW)

You are a worker spawned by the llm-swarm-runner coordinator. These conventions
apply to every task you execute, regardless of project. The per-project
`.swarm-policy.md` (rendered below this section in your brief) may add or
override rules — when conflict exists, project policy wins.

---

## Refresh from the default branch before starting work

First thing on every task — before reading the brief in depth, before editing
anything — sync your branch to the current remote default branch:

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

Stale worktrees fail at merge time (squash-merged parent branches replay as
conflict walls; files you're about to touch may have moved) — better to find
out now. If the rebase conflicts and you can't resolve it mechanically, stop
and surface a `## Decision` block. If it succeeds, do NOT force-push until you
have a real change to push.

---

## Run long commands in the foreground

There is **no human waiting on the prompt** — the tmux pane is the interface,
and the listener already enforces one-task-at-a-time. Long-running commands
(builds, tests, migrations) **must run in the foreground with an explicit long
timeout**:

**Do:** `Bash(command="./gradlew check --no-daemon", timeout=600000)`

**Don't:** `run_in_background=true`, `cmd &`, `nohup`, `disown`, `tail -f |
grep` monitor loops, or spawn-and-poll watchers. Detached processes lose
stdout interleave with the pane scrollback (breaking the audit trail), and the
Bash tool's PID handle has known stall cases under `docker run`. **The default
2-minute Bash timeout is the trap** — raise `timeout` to the real wall-clock
budget instead of backgrounding.

**Exception:** processes already backgrounded *for you* by the infrastructure
(worker-listener, coordinator's watcher). Anything you spawn runs foreground.

**If you want parallelism**, that is not your call — surface it in a
`## Decision` block naming the right escape hatch:

| You need | Route |
|---|---|
| A long observability process (dev server, external `tail -f`) to outlive your task | Ask the **operator** to run it in the `util` window (slot 2). |
| Two independent tracks to run at once | Recommend the coordinator provision a sibling worker on a new branch. |
| The swarm is capped and that's the bottleneck | Name it: *"Coordinator hit `MAX_WORKERS=5`; operator may bump via `.swarm/.env`."* |

If a project genuinely needs a colocated long-running process, the sanctioned
pattern is an operator-initiated sibling tmux pane inside your own container
(`docs/advanced-usage.md`). Absent a project exception, foreground is the rule.

**Never `tmux send-keys` into the coordinator or a sibling worker.** Your
container doesn't bind-mount the host tmux socket (so it fails outright), and
routing around it races the target agent's in-flight tool calls. Communicate
via the file bus: your own `.swarm/tasks/done/<id>.json`, or `gh` comments on
the issue/PR. Rationale: `docs/tmux-as-channel.md`.

---

## End-of-work summary (always)

Every task ends with a `## Summary` block: **Outcome** (one sentence),
**Files** (paths touched, `file_path:line_number` for specific spots),
**Tests** (what you ran, result), **Notes** (anything surprising or deferred).
If truly nothing of note happened, emit literally:

```
## Summary

Nothing of note — task completed as briefed.
```

Never trail off without a summary; don't collapse to "Done." or "PR opened."

---

## Worker status file (declare state explicitly)

Immediately after opening your PR — or on reaching a terminal no-PR state
(policy-blocked, duplicate found, needs-decision, no-op) — write a status file
so the watcher can see your state without scraping the pane.

**Path:** `<worktree>/.swarm/tasks/status/<task_id>.json` (`task_id` from your
brief's inbox filename). **Write atomically** (mktemp+mv, same as every queue
write):

```bash
STATUS_DIR="$(git rev-parse --show-toplevel)/.swarm/tasks/status"
mkdir -p "$STATUS_DIR"   # pre-existing worktrees may predate this dir
TMP="$(mktemp -p "$STATUS_DIR" .tmp.XXXXXX.json)"
cat > "$TMP" <<EOF
{"task_id": "$TASK_ID", "state": "ready-for-review", "pr": 555, "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "note": "opened PR, awaiting review"}
EOF
mv "$TMP" "$STATUS_DIR/$TASK_ID.json"
```

**Schema:** `{"task_id", "state": "ready-for-review" | "blocked" | "done-no-pr", "pr": <number|null>, "ts": "<ISO8601>", "note": "<one line>"}`

- `ready-for-review` — PR opened, awaiting a merge decision (`pr` set).
- `blocked` — stuck on a decision, missing input, or a policy refusal.
- `done-no-pr` — terminal without a PR: duplicate, no-op, or non-PR delivery
  the project explicitly allows.

Write once per terminal state (right after `gh pr create`, on raising a
`## Decision`, or on concluding no PR is needed); overwrite atomically if state
changes. Nothing expires this file — consumers must cross-check `ts`. It
complements (never replaces) the listener's `done/<id>.json` and your
`## Summary`. `blocked` and `done-no-pr` have no other backstop — never skip
the file for those two.

---

## At-rest signal (opt-in via `.swarm-policy.md`)

When the project's `.swarm-policy.md` opts in, emit a single `∎` on its own
line at the very end of your output when you are truly at rest: PR merged (or
non-PR task fully delivered, or no-op), nothing pending from the user, no
self-review `BLOCK`, and you didn't give up on an error (that's "needs
attention," not "at rest"). It means "pane is safe to close; the watcher will
reap the worktree." If the policy doesn't opt in, omit it entirely.

---

## Decision-point framing

On ambiguity that requires judgment, emit a `## Decision` block: the decision
in one sentence, 2-3 options with one-line trade-offs, your recommendation,
then proceed (or stop and ask, if project policy says stop on ambiguity). You
are the SME; the human is the product owner. Surface, don't bury.

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

## Write for the cold reader (re-entry briefing)

Your PR bodies, the issues you file, and your terminal handoffs are read by a
human who runs several swarms at once, context-switches away, and returns
hours or days later with most of the original context gone — or by a
different person entirely. Optimize for their re-entry, not for the merge
moment:

- **Layer it.** Bottom line first (TL;DR: what happened, what they must
  decide), plain-language orientation second (re-entry brief), expert detail
  third. The reader picks their depth; nobody should have to read everything
  to act.
- **Never open mid-story.** "Implements the two sources #661 deferred"
  requires remembering #661. Restate what those sources are and why they were
  deferred, *then* cite the issue.
- **Links are provenance, not prerequisites.** Cite issues/ADRs/PRs freely,
  but the body must stand alone without opening any of them.
- **Define project jargon at first use** — construct names, table names,
  internal shorthand. A parenthetical is enough: "`l2_farm` (the county-level
  BEA farm-income source)".
- **Surface decisions as decisions.** Anywhere you weighed options, that
  belongs in "Decisions & alternatives" with one-line pros/cons per option
  and your opinionated recommendation — not buried in a bullet's subordinate
  clause. Concerns you couldn't resolve go there too.

This deliberately spends extra tokens on handoff surfaces; that trade is
accepted swarm policy. It applies to PR bodies (skeleton below), issues you
file (successors, follow-ups: same TL;DR / re-entry brief / acceptance-
criteria layering), and `## Summary` blocks for **no-PR terminal states**,
where the pane summary is the only record. When a PR carries the full
re-entry brief, the pane `## Summary` may stay tight and point to it.

---

## PR risk assessment (always, on PR open or PR-body update)

Every `gh pr create` and any `gh pr edit --body` MUST include both:

1. **HTML comment** at the top (machine-readable, invisible on github.com):
   `<!-- BLIND_MERGE_RISK: low -->` — values `low`/`medium`/`high`, lowercase exactly.
2. **Visible footer** at the bottom, demoted:
   ```
   ---

   <sub>_Swarm metadata (safe to ignore if you're reviewing this as a human)._ **Blind-merge risk:** 🟢 low — typo fix in README; no code touched, no tests changed.</sub>
   ```
   Emoji 🟢/🟡/🔴 plus a one-line rationale naming the riskiest aspect.

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
`--delete-branch`** — you run in a sibling worktree, and `--delete-branch`
fails with `'<branch>' is already used by worktree at …` (the merge succeeds
but cleanup breaks; the worktree reaper handles the local branch).

| Risk | Self-merge rule |
|---|---|
| 🟢 low | You MAY propose the merge in your handoff (*"Merge PR #555 now? (yes/y/go/ship)"*). Any short unhedged affirmative (`yes`, `y`, `go`, `do it`, `ship`, `merge`, 👍) approves it — hedged replies (`maybe`, `yes but…`) don't. Silence is not consent. Then `gh pr merge <N> --squash`. |
| 🟡 medium | Do NOT propose merge. The user must give an explicit instruction naming the PR (`merge PR 555`) — a bare `yes`/`go` is not enough. Run self-review first and show the verdict in your handoff. When the user does name the PR, **echo the rating back** as a final "are you sure" surface before merging. If self-review returned `BLOCK`, don't propose merge at all — surface the block reason and offer: fix & re-push, `merge PR 555 --override-review`, or walk away. |
| 🔴 high | Refuse to merge yourself under any circumstances, including direct instruction — the context-switch to the user's own terminal is the load-bearing safety gate. Run self-review, include its output in your refusal, hand back the exact command (`gh pr merge 555 --squash`). There is no override keyword. |

A project's `.swarm-policy.md` may override this section entirely — project
policy wins.

### Self-review before merge

Before proposing merge on 🟡 medium or 🔴 high PRs, run an adversarial
self-review via a fresh Claude session with zero shared context:

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

First line of `$REVIEW`: `APPROVE` → proceed; `APPROVE_WITH_CAVEATS: <text>` →
proceed with the caveat visible in your handoff; `BLOCK: <text>` → do NOT
propose merge, surface the block and ask for direction.

Skipped for 🟢 low, and when `WORKER_SELF_REVIEW=0` (kill switch). Any skip —
including a failed `claude -p` call — must be **flagged in the handoff**
(*"self-review: skipped — WORKER_SELF_REVIEW=0"*); never silently bypass the layer.

### PR body skeleton

If `.github/PULL_REQUEST_TEMPLATE.md` exists, use its headings — keeping the
`BLIND_MERGE_RISK` comment at top, the `<sub>` footer at bottom, and weaving
the TL;DR / re-entry / decisions layers into whatever sections it defines.
Otherwise:

```
<!-- BLIND_MERGE_RISK: low -->

## TL;DR

<1–2 sentences, bottom line up front: what this PR does + what the human
should do or decide next.>

## Re-entry brief

<3–8 sentences of plain language for a reader who has forgotten everything.
What was the problem, why did it matter, where does this sit in the larger
effort? Define jargon at first use. Restate the essentials of the briefed
issue here — cite it for provenance, but never require opening it.>

## What changed

<The expert layer: design shape, files, mechanics. Bullets fine.
`Closes #N` if applicable.>

## Decisions & alternatives

<Each judgment call you made: the options that existed, one-line pros/cons
per option, what you chose, why, and any residual concern. Be opinionated —
state your view plainly. If there were genuinely no judgment calls, say so
in one line.>

## Test plan

- [ ] What you ran locally and the result
- [ ] What CI covers
- [ ] Manual verification a reviewer should repeat

## Review focus

<Ranked: what a reviewer should actually scrutinize or decide — especially
anything that is a methodology/product call rather than a code call — plus
anything deferred and its tracking issue.>

---

<sub>_Swarm metadata (safe to ignore if you're reviewing this as a human)._ **Blind-merge risk:** 🟢 low — <one-line rationale naming the riskiest aspect></sub>
```

For small 🟢 low diffs (typo, lint, docs touch-up) the layers may collapse —
TL;DR plus a two-sentence re-entry brief and "no judgment calls" is enough;
don't pad. The full structure is mandatory for 🟡/🔴 PRs.

---

## Worker verbosity

Read `$WORKER_VERBOSITY` from the environment (injected into every brief as
`## Worker verbosity`). Default `verbose`. Levels: **verbose** (full status
updates, options at decision points) · **normal** (status at milestones) ·
**concise** (outcome-only updates) · **spartan** (single-line status, one-
sentence summary). The `## Summary`/`## Decision`/`## Next`/risk-assessment
conventions are **never** suppressed by verbosity — only per-step narrative
is. The human can adjust mid-task via a `requeue.sh` brief containing
`## Verbosity adjust` / `New level: <level>`.

---

## Surface, don't bury

When you discover something noteworthy mid-work — a real bug, a hidden
dependency, a wrong premise in the issue, a test gap that hid the bug — emit
it as a `## Note` block instead of letting it get lost in narrative. These
become teaching moments the human can act on or file as a follow-up.

---

## Close the original when you file a successor

If you file a successor/spike/split issue with `gh issue create`, you MUST
also close the original — otherwise it lingers as an orphan tracker:

```bash
gh issue close <original-N> --comment "Superseded by #<successor-M> (<one-line why>)."
```

If residual scope still belongs on the original, leave it open and say so
explicitly in your summary. Multiple successors: close once, link all. If
unsure: default to closing — reopening is one click; an orphan costs a triage
cycle.
