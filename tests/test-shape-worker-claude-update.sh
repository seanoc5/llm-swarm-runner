#!/usr/bin/env bash
#
# test-shape-worker-claude-update.sh — one update model for the Claude Code
# that workers run (#742): the ~/.npm-global mount is read-only, in-worker
# auto-update is off, and the single writer script exists. Without these a
# worker's auto-updater rewrote the shared mount (2.1.322 -> 2.1.323 on
# 2026-11-12) while the Dockerfile claimed a different pinned version.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -qF -- '-v "$HOME/.npm-global:/home/sandbox/.npm-global:ro"' "$ROOT/sandbox.sh" \
    || red "sandbox.sh no longer mounts ~/.npm-global read-only"
green "sandbox.sh: ~/.npm-global mounted ro"

grep -qF -- '-e "DISABLE_AUTOUPDATER=1"' "$ROOT/sandbox.sh" \
    || red "sandbox.sh no longer sets DISABLE_AUTOUPDATER=1 for workers"
green "sandbox.sh: in-worker auto-update disabled"

[ -x "$ROOT/scripts/update-worker-claude.sh" ] \
    || red "scripts/update-worker-claude.sh missing or not executable"
bash -n "$ROOT/scripts/update-worker-claude.sh" || red "update-worker-claude.sh has a syntax error"
green "update-worker-claude.sh present and parses"

grep -q '^ARG CLAUDE_CODE_VERSION=latest$' "$ROOT/Dockerfile" \
    || red "Dockerfile CLAUDE_CODE_VERSION is no longer the 'latest' fallback; update its header and docs/model-switch-recipe.md together"
green "Dockerfile: claude-code fallback is the latest ARG"
