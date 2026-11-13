# Issue #680 audit: approval items with no concrete action, and items repeated without a re-check

*Read this before tuning `scripts/lint-coordinator-reply.sh`'s `pointer` and
`no-command` rules, or when asking whether a coordinator's Needs-you list can
be trusted across digests.*

Audit date 2026-11-13. Window: coordinator replies from 2026-10-30 to
2026-11-12 in the fand-app, fand-etl and corpusminder-spring swarms.

## Bottom line

- The incident reproduces as a pattern, not a one-off. In fand-app the "make
  those three edits yourself" item (unblock #1810) was shown in 24 replies
  between 2026-11-01 17:10 and 18:30 UTC. None of them named a file or a line.
- The lint that existed on master (back-references plus run/click items with no
  command) did not flag it. The new `pointer` rule does.
- Across the three swarms, 5.3% to 8.6% of item appearances now trip the lint
  (6.2% to 6.9% before). Carried-over items (shown in 3+ replies) are 11% to 18%
  of distinct items, and only 1 to 7 per swarm said anything about being
  re-checked.

## Method

Source: Claude Code session transcripts of the coordinator checkouts under
`~/.claude/projects/` (fand-app, fand-etl, corpusminder-spring), assistant text
blocks dated 2026-10-30 or later that contain "Pending your approval", a
`- **A1**` style bullet, or "Needs you". An item is a `- **X1**` bullet plus its
continuation lines, or a "Pending your approval:" line plus continuation. Each
item appearance was run through the master lint and through the new lint
(`--only backref,no-command,pointer`). A distinct item is a (session, first 70
normalized characters) pair. "Carried" is a distinct item that appears in 3 or
more replies of one session.

## Results

| | fand-app | fand-etl | corpusminder |
|---|---|---|---|
| Sessions / replies with items | 12 / 510 | 7 / 803 | 10 / 788 |
| Item appearances / distinct items | 1246 / 572 | 2305 / 1284 | 2112 / 1230 |
| Old lint hits (master) | 78 (6.3%) | 142 (6.2%) | 145 (6.9%) |
| New lint hits (this PR) | 107 (8.6%) | 135 (5.9%) | 112 (5.3%) |
| ...of which `pointer` / `no-command` / `backref` | 37 / 47 / 25 | 23 / 88 / 25 | 19 / 60 / 37 |
| Hits only the new lint catches | 41 | 24 | 18 |
| Action-verb items with no command, path, URL or #N (broad scan) | 54 of 749 (7.2%) | 192 of 1163 (16.5%) | 150 of 1433 (10.5%) |
| Carried in 3+ replies (distinct items) | 100 (17.5%) | 164 (12.8%) | 135 (11.0%) |
| ...identical text in 3+ replies | 82 | 115 | 81 |
| ...with a "verified / re-checked" marker in the text | 4 | 7 | 1 |
| Longest carry | 38 replies | 38 replies | 44 replies |

Reading the numbers:

- **Pattern 1 (no concrete action).** `pointer` is the new catch: 37, 23 and 19
  appearances. In fand-app it fires on the exact incident. `no-command` is noisy:
  by a text check, 38 of 47 (fand-app), 41 of 88 (fand-etl) and 31 of 60
  (corpusminder) of those hits are decision-shaped items ("recommend yes",
  "(yes/no)", "Default if silent") where the verb (start, open, run) is
  incidental. That noise was already in the master rule; this PR exempts
  yes/no items from the run/start/open verbs but keeps `edit` and `apply`
  strict. Tuning the rest is a follow-up.
- **New hit rate is lower than old for fand-etl and corpusminder** because the
  payload test is wider now: a file path with an extension, `file:line` or a
  quoted phrase also counts as the item's payload.
- **Pattern 2 (repeated without a re-check).** 82, 115 and 81 items repeated
  word for word in 3+ replies. The text proxy for a re-check ("verified",
  "re-checked", "as of <time>") appears in 4, 7 and 1 carried items. A
  coordinator may have re-checked silently with tool calls; the proxy cannot
  see that. What the operator sees is the same sentence with no time on it.
- **Pattern 3 (capsule shrinks).** Not measured separately; the incident item
  shows it (the first statement already omitted the files).

## Examples (verbatim, three per swarm)

"Old" and "new" are the master lint and the lint in this PR.

### fand-app

- **F1, the incident (2026-11-01 17:34 UTC, 24 appearances).** Old: no hit.
  New: `pointer`.
  > Pending your approval:
  > - **A1:** how to unblock #1810 (adopt the shared UI library). Workers are barred from editing CI workflow files, and #1810 needs a one-line submodule setting in three of them. My recommendation is that you make those three edits yourself or allow a one-time exception (~70% confidence; blast radius: CI checkout for every PR). If you say nothing, #1810 stays parked. (yes/no)
- **F2, a fix that is not stated (2026-11-07 19:13 UTC).** Old: no hit. New: `no-command`.
  > - **A10** New: let me write the git-hook fix for #1547 myself? The pre-push check currently rejects the branch that renumbers a clashing migration, which pushes people toward skipping the check. Workers can't edit hooks, so I'd write the fix and send the PR to you to merge. Recommended, medium confidence; affects local pushes only, and a revert is one small PR. Default: stays blocked.
- **F3, a clean item, repeated (2026-11-02 06:39 to 06:56 UTC, 6+ replies).** Old and
  new: no hit. It names its command and its expected result, so carrying it
  costs nothing but screen space; this is the shape the lint wants.
  > - **A2** Redeploy minti9's fand-app and run the natural-capital refresh so it shows corrected totals? I recommend yes, with high confidence; it affects only minti9, the dev instance. Command, run on minti9: `/opt/work/sysadmin/deploy-app.sh minti9 fand-app`. Expected result: the app restarts on V255, and USA 2020 natural capital shows about $11.6tn. Say yes and I'll run it.

### fand-etl

- **E1, option with no text (2026-11-12 08:17 to 10:07 UTC, 13 appearances).** Old: no hit. New: `pointer`.
  > Pending your approval:
  > - A1, minerals-total gate: option a recommended, ~80% confidence, affects only the minerals and NC checks.
  > - A2, merge #2381 after CI: recommended, ~85%; cross-border 1950-89 values, on shared databases only at the next reload.
  > - A3, the nine cells: option a recommended, ~70%; nine cells.
- **E2, carried 19 times without a check (2026-11-02 03:36 to 06:42 UTC, 6 distinct wordings).** Old and
  new: `no-command` (a decision; the hit is noise, the repetition is the finding).
  > - **A7** File an llm-swarm-runner issue so workers run the docs-map test before opening a PR. Recommended yes. (yes/no)
- **E3, carried 9 times (2026-10-31 00:55 UTC).** Old and new: `no-command` (decision-shaped).
  > - **A3** Promote fand-etl's own CW calculation, which uses GDP like John's page instead of the workbook's GNI. That would close the UK 1955-85 gap. Default if you say nothing: CW stays on the workbook. (Not recommended tonight: #1846, which changes how CW fills 2024/25, is still open, and CW's promotion hasn't been checked against its full checklist. Confidence medium; blast radius is every CW-derived figure.)

### corpusminder-spring

- **C1, "run them" (2026-11-12 06:17 to 08:26 UTC, 8 appearances).** Old: no hit. New: `pointer`.
  > Pending your approval: A3, merge #2311 (yes/no). I recommend it, medium-high confidence; blast radius is personal-OAuth MCP callers only. A1 and A2 are already approved and just need you to run them.
- **C2, merge item with no command or URL (2026-11-09 00:57 to 02:01 UTC, 3 appearances).** Old and new: `no-command`.
  > - **X1** PR #2080: API for creating forums, topics and questions. Merge recommended (medium confidence). Default if you don't answer: stays open.
- **C3, decision-shaped hit (2026-11-10 13:03 UTC).** Old and new: `no-command` (noise: "start" is in "start defaulting").
  > - **A3** #2148: when searches start defaulting to forum-visible, should the searches you already saved stay private? I recommend yes, high confidence: nothing you made before becomes visible to others.

## What changed in response (this PR)

- `lint-coordinator-reply.sh`: `pointer` rule; "Pending your approval" lines are
  items; `edit` and `apply` join the verb list; a path, `file:line` or quoted
  phrase counts as a payload. Fixtures in `tests/fixtures/reply-lint/`.
- `needs-you.sh`: `--claim`, `verify <label>`, and a "verified <time>" or
  "(unverified since <time>)" line on every rendered item
  (`NEEDS_YOU_STALE_HOURS`, default 6).
- `prompts/coordinator.md`: state the claim, re-check before a re-digest, name
  the change. The prompt is shared by every coordinator, fand-app included.

## Not done, and why

- The lint cannot know a claim is wrong (the incident's "three files" claim was
  false: only `ci.yml` builds with Gradle). `verify` only makes the missing
  re-check visible. Whether the coordinator actually re-reads the source is
  still on the coordinator.
- `no-command` still flags decisions whose verb is incidental ("start
  defaulting"). Tuning it needs a labelled sample, not another regex round.
- The "verified" proxy is text only. A tool-call based check (did the
  coordinator run `gh pr view` or `grep` between two digests?) would be more
  honest but needs the transcript at lint time.
