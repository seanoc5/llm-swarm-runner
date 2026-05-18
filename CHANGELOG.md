# Changelog

All notable changes to llm-swarm-runner will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `scripts/reap-orphan-worktrees.sh` — bulk-reap stale `wt-issue-*` worktrees whose work is preserved elsewhere. Iterates directories (unlike `kill-finished-workers.sh`, which iterates live `iss-*` tmux windows), so it catches worktrees that outlived their tmux session. Default safety predicate: at least `--min-age-days N` old (default 2; overridable via `REAP_MIN_AGE_DAYS`), clean tree, and PR finalized (MERGED or CLOSED). Stricter `--merged-only` and offline `--no-pr-check` modes available.
