# Changelog

This file is a best-effort, occasionally-updated log of notable changes — it
is not kept current with every commit. `git log` and PR titles are the
authoritative history; no versioned release has been tagged yet, so there's
nothing here to hold to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
against. Entries below follow the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
style when they are written.

## [Unreleased]

### Added
- `scripts/reap-orphan-worktrees.sh` — bulk-reap stale `wt-issue-*` worktrees whose work is preserved elsewhere. Iterates directories (unlike `kill-finished-workers.sh`, which iterates live `iss-*` tmux windows), so it catches worktrees that outlived their tmux session. Default safety predicate: at least `--min-age-days N` old (default 2; overridable via `REAP_MIN_AGE_DAYS`), clean tree, and PR finalized (MERGED or CLOSED). Stricter `--merged-only` and offline `--no-pr-check` modes available.

Many notable changes have landed since the entry above without a changelog
update — worker-side auto-compact, the context-first PR-body skeleton,
`self-review-pr.sh` / `review-scoreboard.sh` / `stale-pr-nudges.sh` /
`swarm-scoreboard.sh`, and various watcher autoclose fixes among them. See
`git log --oneline` for the full, current record.
