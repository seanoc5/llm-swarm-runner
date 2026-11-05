## Run digest — 2026-11-05T21:29Z (woke for: outcome x3, activity x1)
No PR merged and no worker started: all 5 worker slots are held by open PRs, and the only automerge enabled (low risk) has no eligible PR. 5 PRs wait on you; A1 is the one ready to merge.

**A. Needs you (ranked by risk × age):**
- **A1** 🟡 PR #679 (readiness script refuses stray flags) — "The readiness script now refuses a flag written after the PR number, instead of ignoring it and readying the PR unreviewed." Coordinator review APPROVE, 5/5 CI lanes green on f6b9bf8. Recommend merge, ~90% confident. `merge PR 679` in the conversation session. Default if silent: stays open and keeps its worker slot. https://github.com/seanoc5/llm-swarm-runner/pull/679
- **A2** 🟡 PR #685 (project overrides reach new workers) — "Per-project overrides now reach new workers on a fresh swarm, and the regression the review found is fixed." Review APPROVE_WITH_CAVEATS, but its complaint (stale-pr-nudges.sh skips the loader) is what the body says was fixed, so it may describe an older head; unverified. Recommend reading stale-pr-nudges.sh on 61668bf, then `merge PR 685`; ~60% confident. Decide item, your call: running swarms keep the old value, so restart each tmux server or unset the key per socket. Its Next line says lift a hold, but no hold exists (not draft, no banner, no hold comment). Default if silent: stays open. https://github.com/seanoc5/llm-swarm-runner/pull/685
- **A3** 🟡 PR #684 (stacked PRs: retarget on merge, no false "pending") — "Merging a parent PR now retargets its stacked children (and tells them to rebase) before the branch is deleted." Review APPROVE_WITH_CAVEATS says no test runs the retarget loop, but the body says a fake-gh test was added, so it may describe an older head; unverified. The worker review's mixed path/base message caveat (on 42bcb61) is not addressed in the body. Never run against live GitHub. Worker's full suite: 97 of 101 passed, 3 failed, 1 not re-run; host causes are the worker's claim, unverified, and 1 failure is unexplained. Recommend reading the diff, then `merge PR 684`; ~60% confident. Default if silent: stays open. https://github.com/seanoc5/llm-swarm-runner/pull/684
- **A4** 🟡 PR #678 (night queue and capacity wakes) — no risk rating, treated as medium (policy violation). Last coordinator review (APPROVE_WITH_CAVEATS) is on old head 0dab564; 4 of 5 CI lanes reported. Recommend not merging until reviewed on 3388cf5. Default if silent: stays open. https://github.com/seanoc5/llm-swarm-runner/pull/678
- **A5** 🟡 PR #677 (daily "what merged" digest) — no risk rating, treated as medium (policy violation). Last coordinator review (APPROVE_WITH_CAVEATS) is on old head 07d6821; 4 of 5 CI lanes reported; posting needs per-app API keys. Recommend not merging until reviewed on aedea1b. Default if silent: stays open. https://github.com/seanoc5/llm-swarm-runner/pull/677

**What surprised me:**
- This was a replay: gh answers came from fixtures, and PR diffs were unavailable. Reviews on 679, 684 and 685 returned recorded verdicts; reviews on 681, 677 and 678 did not run. Their comments did not appear on the PRs when re-read.
- Not actually run: stale-PR nudges, reaping, and both requeue briefs (recorded only). The open-PR migration check failed (exit 5, jq error). Default-branch migration check on master: exit 4, no migration files.
- The two follow-up issues returned placeholder number #9999, so their real numbers are unknown.
- PR #681 body describes a fix, yet gh shows the head still at 446f127, where the hold was placed; CI finished after that commit (19:17–19:26Z), so the commit data may be stale. Hold kept. Its original hold comment lacked the marker pr-ready.sh looks for, so I posted a marked one.
- available-issues.sh returned stop-labelled issues here because the stub ignores --search; I removed those by hand. Issue view fixtures were missing for 37 of 47 issues, so open-PR links came from PR titles and bodies.

**Moved since last run:** First run: no previous digest. Inbox: 4 items triaged and archived (#674, #660 and #670 finished ok, each with an open PR; #675 and #676 confirmed merged, nothing pending on them). Filed 2 follow-ups: gawk requirement (from PR #684), codex test timing (from PR #685). Queued briefs: iss-671 (confirm the fix is pushed), iss-673 (confirm shard 0/4, re-run pr-ready on 191911c). No PRs nudged.

**In flight:**
- iss-671 — PR #681, draft, coordinator hold, 5/5 CI lanes reported. Next: worker confirms the fix commit. `tmux kill-window -t iss-671`
- iss-673 — PR #683, draft, stale CI-failed banner on 12dab4a; head 191911c has 4 of 5 lanes green and no review. Next: worker re-runs pr-ready. `tmux kill-window -t iss-673`
- iss-674 — PR #679, open, waiting on A1. `tmux kill-window -t iss-674`
- iss-660 — PR #685, open, waiting on A2. `tmux kill-window -t iss-660`
- iss-670 — PR #684, open, waiting on A3. `tmux kill-window -t iss-670`

**Backlog:** OPEN=55 AVAILABLE=37 ALIVE=5/5 WINDOWS=7/10. Capped on MAX_WORKERS, so nothing was provisioned; merging A1–A3 frees 3 slots. AVAILABLE excludes 8 stop-labelled, 5 with open PRs, #663 (PR #678 covers it), and 4 epics or carve issues (#249, #283, #450, #488). No night-ok issues. ROADMAP=2.
