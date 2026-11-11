# Deterministic checks (#811, ADR 0007)

Regex/script lints of swarm text, behind one input and output format.
Naive on purpose; corpusminder is expected to ingest this output and grow it.

```
scripts/checks/run.sh <kind> <file|->
```

Kinds: `brief`, `pr-screen`, `reply`, `needs-you`. The runner runs every
executable `scripts/checks/<kind>/*.sh` (each takes one file argument) and
concatenates their output.

## Output: JSON lines (stable)

One object per finding, nothing printed when clean:

```json
{"check":"two-endings","severity":"error","line":0,"match":"two-endings: 1 nothing-line(s), 1 Do now, 0 Pending your approval","message":"reply has more than one closing line; end with exactly one"}
```

- `check`: stable id (also the fixture dir name). `severity`: `warn` or `error`.
- `line`: 1-based line of `match` in the input, `0` when unknown or whole-text.
- `match`: offending text (may be empty). `message`: what to do about it.
- Exit: `0` clean, `1` findings, `2` usage/IO error or a crashed check.
- Add fields only; never rename or remove these five.

## Registered checks

- `brief` (warn, wraps `lint-brief.sh`): no-done-definition, check-cannot-fail, no-named-files, underspecified.
- `pr-screen` (error, wraps `lint-pr-screen.sh`): identifiers-above-fold, bottom-line-budget, surprise-budget, your-move-budget, recommendation-in-table, screen-too-long.
- `reply` and `needs-you` (error, wrap `lint-coordinator-reply.sh`): backref, no-command, two-endings, stale-window (set `CHECKS_PROJECT=DIR`), issue-merged (#716; needs `gh`, has no fixture dir because it calls GitHub; `tests/test-reply-lint.sh` covers it with a stub).

`check-coordinator-authorship.sh` is a PR-merge gate on git history, not text, so it is not behind this runner.

## Adding a check

1. Put a real failing example at `test-fixtures/checks/<id>/fail.txt`, a corrected one at `pass.txt`, and the kind in `kind`.
2. Add `scripts/checks/<kind>/<name>.sh` printing JSON lines (`source scripts/checks/_lib.sh`, call `emit`).
3. `tests/test-checks.sh` checks every fixture dir automatically.
