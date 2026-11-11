# Risk floor and the optional 🟢 review

**What it is.** The 🟢/🟡/🔴 rating on a PR (the `BLIND_MERGE_RISK` marker) is the authoring worker's own call, and a 🟢 PR can merge unattended with only the coordinator's diff read behind it. `scripts/risk-floor.sh <PR#>` is a deterministic check (no AI) that prints the lowest colour the diff allows and the rule that set it. Issue #731.

```
$ scripts/risk-floor.sh 123
floor: medium
rule: migrations — touches a database migration (src/main/resources/db/migration/V9__x.sql)
note: scope — changed files under no path the brief/issue mentions (scripts/other.sh); advisory, no bump
```

`--apply` also enforces it: when the body's marker is below the floor it rewrites the marker (and the footer colour) and posts one comment per head commit naming the rules. Exit 10 means "bumped".

## Where it runs

- `pr-ready.sh` — for a 🟢 PR, before the review step. A bump makes the PR a 🟡 for the rest of the run, so it goes through self-review like any 🟡. If `risk-floor.sh` itself fails, the PR is treated as 🟡 for that run (fail toward review; the marker is left alone).
- `swarm-merge.sh --auto-low` — Gate 1b, right after the marker gate. A bump refuses the merge (the PR is now an ordinary 🟡 for the operator); a script failure also refuses (fail closed).

## Rules

All raise the floor to 🟡. Patterns are extended regexes on the repo-relative path.

| Rule | Fires when | Setting |
|---|---|---|
| `migrations` | a changed path matches Flyway `db/migration/`, Alembic `alembic/versions/`, or `migrations/*.sql\|py` | `RISK_FLOOR_MIGRATION_RE` |
| `sensitive` | a changed path is a Gradle/pyproject/pom file, a Dockerfile, a compose file, a GitHub workflow, or a `*Security*Config*` / `*Auth*Config*` class | `RISK_FLOOR_SENSITIVE_RE` |
| `lines` | additions + deletions exceed the limit (default 300) | `RISK_FLOOR_MAX_LINES` |
| `tests` | a test file is deleted, a line like `@Disabled`, `@pytest.mark.skip`, `it.skip(` is added to one, or GitHub refuses to serve the diff (very large PR; the check can't run, so it raises the floor instead of erroring) | `RISK_FLOOR_TEST_RE`, `RISK_FLOOR_SKIP_RE` |
| `scope` | **advisory only, never bumps.** A changed file under no path the brief or issue text mentions. Skipped when no text is available. | — |

`RISK_FLOOR_DISABLE="tests lines"` switches individual rules off; `RISK_FLOOR=0` switches the whole check off. Set them per project in `<project>/.swarm/.env` (defaults in `.env.example`).

`scope` text comes from `RISK_FLOOR_BRIEF` (a file), else the worker's brief for `$TASK_ID`, else the issue the PR body closes.

## Optional 🟢 review

`GREEN_REVIEW=1` (default `0`) makes `pr-ready.sh` run the same self-review for a 🟢 PR that it runs for 🟡, using `GREEN_REVIEW_MODEL` (default `haiku`). BLOCK refuses to ready; caveats are posted but don't block. It shares the 🟡 machinery, so `WORKER_SELF_REVIEW=0` and `WORKER_SELF_REVIEW_MAX_ROUNDS` still apply. With the setting off, behaviour is unchanged.

## Trying new rules on history

`scripts/risk-floor-dryrun.sh <owner/repo> [count]` runs the floor (read-only, no `--apply`) over the last merged 🟢 PRs and lists which would have been bumped. Run it before tightening a pattern.

## Tests

`tests/test-risk-floor.sh` (each rule fires / doesn't, the bump path), `tests/test-pr-ready.sh` Tests 44-52 (bump routing, `GREEN_REVIEW`), `tests/test-shape-coordinator-authorship.sh` Test 7b (Gate 1b).
