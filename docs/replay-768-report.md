# Replay report: does a fresh work run triage as well as the resident coordinator? (issue #768)

Measured 2026-11-05 on Opus 5.5 (`claude-opus-5-5`). Tool: `scripts/replay-work-run.sh`
(plus `replay-gh-fixtures.sh`, `replay-resident-actions.sh`). Raw outputs: `docs/replay-768/`.

## Bottom line

Not a clean pass. A fresh run read about 54% of the resident's cache tokens on the same wakes
(inside the ADR's 60% line), but it cost 1.5x to 1.9x more dollars per wake, and its actions
differed from the resident's on all 3 wakes, but materially on only 1 (R1: it missed follow-up
issues and fix-brief holds the resident handled). A1's hold-versus-lift difference is not a
triage difference: the stubbed reviews never ran and PR diffs were unavailable, so the run had
no verdict to act on. R2c's empty second slot is a fixture gap. The replay also cannot tell
whether operator-notes plus last-digest would have closed the R1 gaps, because every replayed
run was a first run with no digest. Recommendation: do not switch any swarm to `COORD_MODE=split`
on this evidence; first run the split on a real swarm for a few days and re-check stop condition
(a) with real digests.

## The three replays

Each replay is one wake: a fresh `claude -p` run on a copy of the inbox the resident had at
that moment, GitHub rewound to that moment, every write recorded and not sent.

- **R1** this repo, 2026-11-01 19:12Z, 4 inbox items.
- **R2c** this repo, 2026-11-01 21:16Z, 3 items. Two earlier attempts are discarded: R2 guessed
  3 live worker windows when the resident had 2 free slots; R2b (right windows) showed 15 live
  host containers to the run, because `docker` was not yet stubbed (found by the PR self-review).
  The stub was added and R2b re-run as R2c.
- **A1** fand-app (app swarm; a private repo, so only counts and action kinds are kept in
  `docs/replay-768/a1/`), 2026-11-02 07:44Z, 1 item. Inbox rebuilt from the resident
  transcript because that archive is not on this host.

## Cost against the baseline

Resident figures are summed from its transcript for the same wake. Dollar figures for the
resident are estimates: I fitted one rate to the fresh runs (all land within 3% of each other
at about $3.6 per million "input-equivalent" tokens, with cache read at 0.1x, 1h cache write at
2x, output at 5x) and applied it to the resident's counts.

| Wake | Fresh cache-read | Resident cache-read | Ratio | Fresh $ | Resident $ (est.) |
|---|---|---|---|---|---|
| R1 | 720k | 1,255k | 57% | 1.23 | 0.72 |
| R2c | 439k | 888k | 49% | 0.88 | 0.46 |
| A1 | 747k | 1,415k | 53% | 1.17 | 0.77 |
| all | 635k avg | 1,186k avg | 54% | 1.09 avg | 0.65 avg |

Fresh runs write 5.7x to 9x more cache (65k to 85k tokens vs 9k to 15k) and produce 2x to 5x the
output, because each starts from nothing and writes a full digest. Against the "about 1M per
wake" figure the ADR uses, 635k is 64%.

## Missed items and extra actions

- **R1 missed:** follow-up issues for the caveats on merged PRs #675 and #676 (it saw both as
  "confirmed merged, nothing pending"); fix-brief holds on PRs #684 and #685 (it recorded the
  review caveats but left both as "your call" items).
- **R1 extra:** reviews of #681, #677, #678; follow-up issues for #684/#685 caveats instead;
  a corrected hold comment on #681 (the old one lacked the marker `pr-ready.sh` looks for).
- **R2c missed:** starting issue #576 (it asked for #592 only). It surfaced #576 as a decision
  for the operator, and left the second slot empty because the other candidate issues' bodies
  were missing from the fixtures. That part is a fixture gap, not a triage fault. **Extra:** one
  stale-text edit to PR #696's body.
- **A1 not comparable:** the resident measured a data-copy step on real data before readying
  its PR; a fresh run has no such data. The fresh run kept the held PR on hold and requested
  reviews, where the resident lifted the hold and readied it. That is not a triage difference:
  the stubbed reviews returned no verdict (A1's own digest says so) and PR diffs were
  unavailable (the stub `gh pr diff` fails), so the run had nothing to lift the hold on. It
  filed 4 follow-ups where the resident filed 3; I did not check whether the fourth was a
  duplicate, and the run could not either.
- **Fixture artefacts, not triage misses:** A1's "lost its hold banner" and "stayed draft"
  items came from fixtures (GitHub keeps no history of PR bodies or draft state; I forced a
  draft flag wrongly). Digests contain lines like "this was a replay"; I did not hide it.

## Pass/fail against the ADR's stop conditions

- **(a) Fresh runs miss things the resident caught that operator-notes plus last-digest do not
  close:** NOT PASSED, inconclusive. Misses exist on every wake, but the replay supplied no
  digest or notes, so it tests the worst case. Next step is a real trial, not more replays.
- **(b) Fresh-run tokens above about 60% of today's per-wake figure:** passes on matched wakes
  (57%, 49%, 53%; 54% overall), fails against the round 1M figure (64%). Dollars are worse (1.5x
  to 1.9x). Splitting only pays if it also cuts wake count, which this does not test.
- **(c) #743 alone brings wake turns well under 50% of session tokens, no wake incident for a
  month:** cannot be replayed; needs a month of data.

## What was and was not touched

No real merge, dispatch, comment, issue or label was made. The run gets no GitHub token and no
MCP servers, its clone has no remote, and `gh`, `tmux`, `docker`, `swarm-merge.sh`, `requeue.sh`,
`provision-worker.sh`, `sideline-worker.sh` and similar are recorder stubs (`actions.tsv` lists
every recorded call). One early run (discarded) saw future git history and noticed the replay;
fixed by `--asof`. Gap found in review: until the docker stub, a run could read live containers
and, via an unstubbed script, stop one. R2b read them (two direct `docker ps` calls, 15 containers; nothing was
stopped, its action log has no docker call). R1 and A1 predate the stub; their run logs show no
direct docker command, but scripts they called could have read container state, so for them
"nothing was stopped" rests on the logs, not on a stub. The docker stub first let
`docker container stop` (and `image`, `network`, `volume`, `system` writes) exit silently
without recording it; that is fixed and tested, but R2c ran on the earlier stub, so a
`docker container stop` in R2c would not be in its action log. Its run log shows no such call.

**Isolation is partial, and the three measured runs had less of it.** The harness removes the
GitHub token and MCP servers and has no git remote, but R1, R2c and A1 ran with
`env -i HOME="$HOME"`, i.e. the real home directory, under `--dangerously-skip-permissions`.
That left the real `~/.config/gh/hosts.yml` (the logged-in `gh` credentials), `~/.ssh` and the
global `CLAUDE.md` reachable, and the real `gh` at `/usr/bin/gh` would have used that login.
I read their tool-call logs (15, 17 and 10 Bash calls for A1, R1, R2c): none names
`/usr/bin/gh`, `hosts.yml`, `~/.ssh` or `~/.config`; the only real-home paths are the run's own
saved tool results under `~/.claude/projects` and a `which gh` that resolved to the stub. Scripts
they called could have read more, so "nothing was reached" rests on the logs, not on a barrier. The harness now sets HOME to a scratch directory
holding only the claude.ai login key (not the MCP tokens kept in the same file, removed again
after the run) and a bare gitconfig, so `gh`, `git` and `ssh` find no credentials by default; a
test plants file canaries (gh hosts file, ssh key, MCP token, global CLAUDE.md) and checks none
is reachable through HOME. Still not a sandbox: the run is the same unix user, so an absolute
path to the real home or `/usr/bin/gh` with a token found elsewhere still works. The new HOME
was not used for any measured run; the numbers above come from the real-HOME runs, and the
global `CLAUDE.md` the old runs loaded is not loaded now.

## Limits

Three wakes, one run each; no repeat to measure run-to-run noise. Fixtures are approximate (PR
bodies, drafts and review comments are today's values unless noted; fand-app check runs were
unreadable by the token, so the run saw no CI data there; issue bodies were missing for most
open issues). The stub `gh pr list` and `gh issue list` honour only `--state open|all`: they
ignore `--search`, `--head`, `--base`, `--label`, `--author` and `--assignee`, and
`--state closed` returns an empty list (so a run asking for recently closed PRs or issues sees
none). `gh pr diff` always fails, so no run saw a diff. Old worker outcome files are reaped, so outcomes
are stand-ins. **Rewound fixtures can leak future CI:** when every check on a PR finished after the --asof
time, the rewind keeps the original check list instead of emptying it, so the run sees checks
that had not finished at the wake. R1 woke at 19:12Z but saw #681's checks finishing 19:17-19:26Z,
so its CI-dependent choices (e.g. merging on green) are not a clean test of what the resident knew. Chat-only operator instructions are invisible to a fresh run. R1 and A1 ran
before the docker stub, so any host-capacity figure in their digests may reflect live containers.
Total replay spend, all six runs including three discarded: about $6.72.
