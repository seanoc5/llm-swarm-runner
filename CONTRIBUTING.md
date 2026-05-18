# Contributing

Thanks for your interest in llm-swarm-runner! See [README.md](./README.md) for a project overview.

## How to file an issue

Open an issue at https://github.com/seanoc5/llm-swarm-runner/issues. Include what you tried, what you expected, and what actually happened. Logs and your OS / Docker / `gh` versions help a lot.

## How to submit a PR

1. Fork and branch off `master` (e.g. `fix/issue-NNN` or `feat/short-slug`).
2. Keep the change focused — one logical change per PR.
3. Reference the issue in the PR body (`Closes #NNN`).
4. Make sure any shell scripts you touch pass `shellcheck` and any tests under `tests/` still pass.

## Code style

Whitespace and line endings are governed by [`.editorconfig`](./.editorconfig) — please use an editor that honors it. Shell scripts use 4-space indentation; Markdown uses 2-space indentation. Keep commits small and messages descriptive.
