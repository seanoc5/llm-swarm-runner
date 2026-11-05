# Replay report: does a fresh work run triage as well as the resident coordinator? (issue #768)

Measured 2026-11-05 on Opus 5.5 (`claude-opus-5-5`). Tool: `scripts/replay-work-run.sh`
(plus `replay-gh-fixtures.sh`, `replay-resident-actions.sh`). Raw outputs: `docs/replay-768/`.

## Bottom line

Not a clean pass. A fresh run read about 57% of the resident's cache tokens on the same wakes
(inside the ADR's 60% line), but it cost 1.5x to 2.6x more dollars per wake, and it missed or
changed decisions the resident made on 2 of 3 wakes. The replay cannot tell whether
operator-notes plus last-digest would have closed those gaps, because every replayed run was a
first run with no digest. Recommendation: do not switch any swarm to `COORD_MODE=split` on this
evidence; first run the split on a real swarm for a few days and re-check stop condition (a)
with real digests.

## The three replays

Each replay is one wake: a fresh `claude -p` run on a copy of the inbox the resident had at
that moment, GitHub rewound to that moment, every write recorded and not sent.

- **R1** this repo, 2026-11-01 19:12Z, 4 inbox items.
- **R2b** this repo, 2026-11-01 21:16Z, 3 items. (R2, a first attempt with a wrong guess of
  live worker windows, is discarded: it was capped at 3/3 workers when the resident had 2 free.)
- **A1** fand-app (app swarm), 2026-11-02 07:44Z, 1 item. Inbox rebuilt from the resident
  transcript because that archive is not on this host.

## Cost against the baseline

Resident figures are summed from its transcript for the same wake. Dollar figures for the
resident are estimates: I fitted one rate to the three fresh runs (all land within 3% of each
other at about $3.6 per million "input-equivalent" tokens, with cache read at 0.1x, 1h cache
write at 2x, output at 5x) and applied it to the resident's counts.

| Wake | Fresh cache-read | Resident cache-read | Ratio | Fresh $ | Resident $ (est.) |
|---|---|---|---|---|---|
| R1 | 720k | 1,255k | 57% | 1.23 | 0.72 |
| R2b | 576k | 888k | 65% | 1.18 | 0.46 |
| A1 | 747k | 1,415k | 53% | 1.17 | 0.77 |
| all | 681k avg | 1,186k avg | 57% | 1.19 avg | 0.65 avg |

Fresh runs write 5.7x to 9x more cache (about 80k vs 9k to 15k tokens) and produce 2x to 5x the
output, because each starts from nothing and writes a full digest. Against the "about 1M per
wake" figure the ADR uses, 681k is 68%.

## Missed items and extra actions

- **R1 missed:** follow-up issues for the caveats on merged PRs #675 and #676 (it saw both as
  "confirmed merged, nothing pending"); fix-brief holds on PRs #684 and #685 (it recorded the
  review caveats but left both as "your call" items).
- **R1 extra:** reviews of #681, #677, #678; follow-up issues for #684/#685 caveats instead;
  a corrected hold comment on #681 (the old one lacked the marker `pr-ready.sh` looks for).
- **R2b missed:** starting issue #576 (it started #592 only; cause not established, possibly
  the fixtures, which are approximate). **Extra:** filed one follow-up (gawk requirement, from
  PR #684) and ran a stale-body edit on #696.
- **A1 missed:** the resident measured the publish copy step on real data before readying #1911;
  a fresh run has no such data. **A1 differs:** it kept #1911 on hold and re-ran reviews, where
  the resident lifted the hold and readied it. It filed 4 follow-ups where the resident filed 3.
- **Fixture artefacts, not triage misses:** A1's "#1911 lost its hold banner" and "#1912 stayed
  draft" came from fixtures (GitHub keeps no history of PR bodies or draft state; I forced
  `--drafts 1912` wrongly). R1/A1 digests say "this was a replay" in places; I did not hide it.

## Pass/fail against the ADR's stop conditions

- **(a) Fresh runs miss things the resident caught that operator-notes plus last-digest do not
  close:** NOT PASSED, inconclusive. Misses exist on every wake, but the replay supplied no
  digest or notes, so it tests the worst case. Next step is a real trial, not more replays.
- **(b) Fresh-run tokens above about 60% of today's per-wake figure:** borderline. 57% on
  matched wakes (pass), 65% on R2b (fail), 68% against the round 1M figure (fail). Dollars are
  worse (1.5x to 2.6x). Splitting only pays if it also cuts wake count, which this does not test.
- **(c) #743 alone brings wake turns well under 50% of session tokens, no wake incident for a
  month:** cannot be replayed; needs a month of data.

## What was and was not touched

No real merge, dispatch, comment, issue or label was made. The run gets no GitHub token and no
MCP servers, its clone has no remote, and `gh`, `tmux`, `swarm-merge.sh`, `requeue.sh`,
`provision-worker.sh` and similar are recorder stubs (`actions.tsv` lists every recorded call).
One early run (discarded) saw future git history and noticed the replay; fixed by `--asof`.

## Limits

Three wakes, one run each; no repeat to measure run-to-run noise. Fixtures are approximate (PR
bodies, drafts and review comments are today's values unless noted; fand-app check runs were
unreadable by the token, so the run saw no CI data there). The stub `gh` ignores `--search`.
Old worker outcome files are reaped, so outcomes are stand-ins. Chat-only operator instructions
are invisible to a fresh run. Total replay spend, all five runs including two discarded: about
$5.84.
