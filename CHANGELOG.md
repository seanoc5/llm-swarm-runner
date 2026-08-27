# Changelog

This file is a best-effort, occasionally-updated log of notable changes — it
is not kept current with every commit. `git log` and PR titles are the
authoritative history; no versioned release has been tagged yet, so there's
nothing here to hold to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
against. Entries below follow the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
style when they are written.

## [Unreleased]

### Fixed
- The worker-finished coordinator wake channel, silently dead since ~2026-07-20: default interactive workers never exit claude, so `worker-listener.sh` never wrote the `done/*.ok.json` that is `coord.wake`'s only completion trigger — completions were detected (and reaped) by the wake-less pr-poll/check-on-done backstops while the coordinator kept reporting them in flight. `coordinator-watch.sh` now synthesizes the outcome file (`"synthesized": true`, atomic mv, `WATCH_SYNTH_OUTCOME=1` to disable with 0) the moment check-on-done wins its claim, so the whole existing inotify → `on_outcome` → autoclose → debounced-wake pipeline fires again; `prompts/coordinator.md` additionally forbids asserting in-flight status from memory — verify live windows/PR state first, and treat a vanished "in-flight" worker as a missed wake. (#314)

### Changed
- Worker end-of-task output: the `## Summary` + `## Decision` + `## Next` triad is now a single terminal `## Handoff` block (**What** / **Decide** when a decision is open / **Action** with PR link + risk), emitted last in the pane — bottom line at the end, since the operator reads panes bottom-up and triages on the GitHub PR page. Mid-task `## Decision`/`## Note` blocks and the PR-body skeleton are unchanged. (#280)

### Removed
- The four-level `WORKER_VERBOSITY` dial (`verbose`/`normal`/`concise`/`spartan`, ADR 0002) and its plumbing: `provision-worker.sh -v/--verbosity` flag, env resolution chain, per-brief `## Worker verbosity` injection, and the `sandbox.sh`/`llm-start.sh` passthrough entries. Workers now speak with one baked-in voice (`prompts/worker.md` § "Worker voice"): status at milestones, options only at genuine decision points. (#279)

### Added
- `scripts/reap-orphan-worktrees.sh` — bulk-reap stale `wt-issue-*` worktrees whose work is preserved elsewhere. Iterates directories (unlike `kill-finished-workers.sh`, which iterates live `iss-*` tmux windows), so it catches worktrees that outlived their tmux session. Default safety predicate: at least `--min-age-days N` old (default 2; overridable via `REAP_MIN_AGE_DAYS`), clean tree, and PR finalized (MERGED or CLOSED). Stricter `--merged-only` and offline `--no-pr-check` modes available.

Many notable changes have landed since the entry above without a changelog
update — worker-side auto-compact, the context-first PR-body skeleton,
`self-review-pr.sh` / `review-scoreboard.sh` / `stale-pr-nudges.sh` /
`swarm-scoreboard.sh`, and various watcher autoclose fixes among them. See
`git log --oneline` for the full, current record.
