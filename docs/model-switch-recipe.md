# Switching a swarm's Claude model — generalized recipe

**Lede:** Yes, it is mostly one config file per swarm — `<project>/.swarm/.env`. Two
things make it more than a one-liner: there are **two** independent model knobs per
swarm (the coordinator and the workers, which deliberately run different tiers), and a
brand-new model can be gated behind a **Claude Code version floor** that the config
file knows nothing about. Get the version floor wrong and the swarm launches, then the
coordinator dies on its first API call with an HTTP 400.

This recipe generalizes any source→target Claude model switch for one swarm. The worked
example at the bottom is the 2026-09-23 corpusminder-spring switch (Fable 5 → Opus 5.5).

---

## 1. The two knobs, and where they come from

| Knob | Env var | Built-in default | Set in code at |
|---|---|---|---|
| Coordinator (the long-lived planner; one per swarm) | `COORDINATOR_MODEL` | `claude-fable-5` | `llm-start.sh` (`COORD_MODEL_DEFAULT`) and `scripts/coordinator-claude.sh` (`MODEL=`) |
| Workers (N parallel sandboxed sessions) | `WORKER_MODEL` | `claude-sonnet-5` | `scripts/worker-listener.sh` (`MODEL=` fallback) |

They are separate on purpose: one coordinator at a top-tier model is cheap, `MAX_WORKERS`
workers at a top-tier model is not. **Switching "the swarm's model" almost always means
the coordinator only.** Escalate workers per-issue instead (§5).

### Precedence (highest wins) — `scripts/_load-env.sh`

1. shell env (anything already exported, incl. `tmux new-session -e` values)
2. `<project>/.swarm/.env` — **per-project durable override; this is the file you edit**
3. `<sandbox>/.env` — this machine's defaults (gitignored)
4. `<sandbox>/.env.example` — shipped defaults (tracked)

`.swarm/.env` is gitignored and host-local, so the switch is not a PR — but it is also
not backed up. Record it in the project's issue tracker or here if it matters.

---

## 2. The recipe

### Step 0 — Establish the *actual* current model (don't trust recollection)

An absent `COORDINATOR_MODEL` line means the swarm is on the built-in default, which is
**not** necessarily the newest model in the `/model` picker. The picker (an interactive
Claude Code feature) and the swarm default (a shell variable) drift independently.

```bash
P=/opt/work/springboot/corpusminder-spring          # the project dir

grep -iE 'COORDINATOR_MODEL|WORKER_MODEL' "$P/.swarm/.env" /opt/work/llm-swarm-runner/.env
env | grep -E 'COORDINATOR_MODEL|WORKER_MODEL'      # shell overrides win over the file
tmux show-environment -t "llm-$(basename "$P")" 2>/dev/null | grep -i model
```

Cross-check against what actually billed, per project dir:

```bash
jq -r '.projects["'"$P"'"].lastModelUsage | keys[]' ~/.claude.json
```

### Step 1 — Verify the target model ID against the live API, not memory

Model IDs are not guessable and date suffixes are a stale-training-data trap.

```bash
curl -s 'https://api.anthropic.com/v1/models?limit=100' \
  -H "x-api-key: $ANTHROPIC_API_KEY" -H 'anthropic-version: 2023-06-01' \
| jq -r '.data[] | "\(.id)\t\(.display_name)"'
```

Then pull the target's capabilities — context window matters for the coordinator, because
`AUTO_COMPACT_THRESHOLD_TOKENS` is tuned to it:

```bash
curl -s "https://api.anthropic.com/v1/models/<target-id>" \
  -H "x-api-key: $ANTHROPIC_API_KEY" -H 'anthropic-version: 2023-06-01' \
| jq -c '{id,display_name,max_input_tokens,max_tokens}'
```

### Step 2 — Check the Claude Code version floor (the step that is easy to miss)

A model can be live on the API and still be refused by the installed CLI. Probe it
directly — one cheap call, unambiguous answer:

```bash
cd "$(mktemp -d)" && claude --model <target-id> -p 'Reply with exactly: OK'
```

A refusal looks like this (this is the real 2026-09-23 output for `claude-opus-5-5` on
CLI 2.1.257):

```
[claude-code:unrecognized_model] {"model":"claude-opus-5-5","query_source":"sdk"}
API Error: 400 Claude Code 2.1.257 does not support this model; version 2.1.280 or
newer is required. Run 'claude update', ... then try again.
```

The picker cache in `~/.claude.json` records the same floor ahead of time — a disabled
entry with a `cc-update-required-*` placeholder value:

```bash
jq -r '.additionalModelOptionsCache[] | "\(.value)\t\(.label)\t\(.description)"' ~/.claude.json
```

If a floor applies, compare it against the release channels before promising anything —
**`claude update` follows `stable`, which can sit below the floor:**

```bash
B=https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases
for ch in stable latest; do printf '%-8s %s\n' "$ch" "$(curl -s "$B/$ch")"; done
claude --version
```

| Situation | Action |
|---|---|
| installed ≥ floor | nothing to do, continue |
| `stable` ≥ floor | `claude update` |
| only `latest` ≥ floor | `claude install latest` (or `claude install <exact version>`) — **a channel decision, not a version bump; it is Sean's call, not the agent's** |
| neither channel ≥ floor | **stop.** Leave the `.env` line commented out with the floor noted. Writing it live breaks the next launch. |

Rollback is `claude install <old version>`; prior builds stay on disk under
`~/.local/share/claude/versions/`.

### Step 3 — Edit the one config file

```bash
$EDITOR "$P/.swarm/.env"
```

Add or change the coordinator line, with a dated comment saying why (every other knob in
these files carries one — it is how the reasoning survives):

```ini
# 2026-09-23: coordinator Fable 5 → Opus 5.5. <one-line reason>.
# Floor: Claude Code >= 2.1.280 (2.1.257 returns HTTP 400 unrecognized_model).
COORDINATOR_MODEL=claude-opus-5-5

# Workers stay on the claude-sonnet-5 default (cost: MAX_WORKERS in parallel).
# Escalate one hard issue per-invocation instead — see §5.
#WORKER_MODEL=
```

Notes on the value itself:

- **No date suffixes.** `claude-opus-5-5`, never `claude-opus-5-5-2026xxxx`.
- **`[1m]` suffix:** only needed for models whose 1M window is opt-in. Current
  top-tier IDs default to 1M, so plain is right. If you do use a bracketed ID at a
  shell, single-quote it (`'claude-opus-4-7[1m]'`) to stop glob expansion. In `.env`
  it is parsed literally — no quoting needed.
- **No inline comments.** `_load-env.sh` keeps everything after `=` literally, so
  `COORDINATOR_MODEL=claude-opus-5-5  # new` sets the model to `claude-opus-5-5  # new`.
  Comments go on their own line.

### Step 4 — Restart the swarm (there is no hot-swap)

The coordinator's model is fixed by the `--model` flag at process start, and
`WORKER_MODEL` is baked into the tmux session environment at `tmux new-session -e`.
Editing `.env` under a live swarm changes nothing.

**Swarms live on a per-project tmux socket** (`swarm-<project>`, see `llm-start.sh`
`SWARM_SOCKET`), so a bare `tmux ls` on the default socket shows nothing and will
convince you the swarm is down when it isn't. Always pass `-L`:

```bash
S="swarm-$(basename "$P")"; N="llm-$(basename "$P")"
tmux -L "$S" ls                                  # is it even running?
pgrep -a -f 'claude --model' | grep "$(basename "$P")"   # …and on which model
# drain: let in-flight workers finish and their PRs merge, then
tmux -L "$S" kill-session -t "$N"
cd "$P" && /opt/work/llm-swarm-runner/llm-start.sh
```

`pgrep` output lists the workers too (`--model claude-sonnet-5`); the coordinator is
the one whose `/proc/<pid>/cwd` is the project root rather than a worktree.

Before killing, check for undelivered briefs — `llm-start.sh` warns about stranded
worktrees on the next launch, but it is cheaper to notice now:

```bash
find "$P"/../*-worktrees/*/.swarm/tasks/{inbox,processing} -maxdepth 1 -type f 2>/dev/null
```

### Step 5 — Verify the switch actually took

```bash
# the flag the coordinator process was launched with
pgrep -a -f 'claude --model' | grep -i "$(basename "$P")"
tmux show-environment -t "llm-$(basename "$P")" | grep -i model
```

Then confirm it *billed* on the new model after the first real coordinator turn:

```bash
jq -r '.projects["'"$P"'"].lastModelUsage | to_entries[] | "\(.key)\t$\(.value.costUSD)"' ~/.claude.json
```

For workers, the scoreboard is the honest answer — it aggregates per (agent, model):

```bash
/opt/work/llm-swarm-runner/scripts/swarm-scoreboard.sh
```

### Step 6 — Re-tune what the model choice invalidates

- **`AUTO_COMPACT_THRESHOLD_TOKENS`** — set per swarm to ~25% of the coordinator's
  window (250000 for a 1M-window coordinator). Moving to a *smaller*-window model
  without lowering this means compaction never fires before the hard limit.
- **Prompt cache** — caches are model-scoped. The first few coordinator turns after a
  switch pay full input price; a low `cache_read_input_tokens` right after a switch is
  expected, not a bug.
- **Cost per worker-hour** — a `WORKER_MODEL` change multiplies by `MAX_WORKERS`. A
  `COORDINATOR_MODEL` change does not.
- **Prompting** — `prompts/coordinator.md` was tuned against the old model. A newer
  model is usually *less* tolerant of over-prescriptive instructions, not more.

---

## 3. Escalating one worker without switching the swarm

Per-invocation, when the coordinator provisions a worker for a hard issue:

```bash
WORKER_MODEL=claude-opus-5 /opt/work/llm-swarm-runner/scripts/provision-worker.sh <args>
```

`tmux setenv -t <session> WORKER_MODEL <id>` is **not** a reliable hot-patch:
`provision-worker.sh` runs from the coordinator's existing pane and inherits that pane's
environment, which a later `setenv` does not update.

---

## 4. Rollback

| What | How |
|---|---|
| Model | Comment out / restore the `COORDINATOR_MODEL` line in `.swarm/.env`, restart the session (§ Step 4) |
| Claude Code version | `claude install <previous version>` — old builds persist in `~/.local/share/claude/versions/` |

Both are independent; a bad model switch does not require downgrading the CLI.

---

## 5. Worked example — corpusminder-spring, 2026-09-24

| | Before | After |
|---|---|---|
| Coordinator | `claude-fable-5` (built-in default; **no line in `.swarm/.env`**) | `claude-opus-5-5` |
| Workers | `claude-sonnet-5` (built-in default) | unchanged |
| Claude Code | 2.1.257 | 2.1.281 (floor was 2.1.280) |

What was done: `claude install latest` → 2.1.281, re-probed the model with the API key
stripped (the coordinator's own Claude Max OAuth path) → `OK`, then set
`COORDINATOR_MODEL=claude-opus-5-5` in `/opt/work/springboot/corpusminder-spring/.swarm/.env`.
The swarm *was* live the whole time (up since 2026-09-17 on socket
`swarm-corpusminder-spring`; a bare `tmux ls` had hidden it — Step 4's `-L` note exists
because of this), so its Fable 5 coordinator keeps running until the session is
restarted; the new model lands at the next `llm-start.sh`.

Findings worth keeping:

1. The swarm was **not** on Fable 5.1, despite Fable 5.1 being the ID offered in the
   interactive `/model` picker. `.swarm/.env` had no model line at all, so the swarm ran
   the `llm-start.sh` default (`claude-fable-5`), and `~/.claude.json` usage for that
   project dir confirmed `claude-fable-5` billing. **Step 0 exists because of this.**
2. `claude-opus-5-5` was live on the API (1M input / 128K output) but refused by CLI
   2.1.257 with HTTP 400.
3. `stable` was 2.1.273 — *below* the 2.1.280 floor. Only `latest` (2.1.281) cleared it,
   so `claude update` alone would not have been enough. The CLI upgrade is machine-wide,
   not per-swarm: coordinator and workers both invoke the `claude` on `PATH`.
4. Claude Max OAuth entitlement covered the new model — worth probing with
   `env -u ANTHROPIC_API_KEY`, because `COORDINATOR_USE_API_KEY=0` (the default) strips
   the API key, so an API-key-only probe would not have proven the coordinator's path.

---

## Related

- `docs/llm-swarm-runner-overview.md` — full coordinator/worker env var tables
- `.env.example` — shipped defaults and the per-knob rationale comments
- `scripts/_load-env.sh` — the precedence chain, authoritative
- `scripts/swarm-scoreboard.sh` — per-(agent, model) pass rates, for judging a switch
