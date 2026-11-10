#!/usr/bin/env bash
#
# test-shape-sandbox-claude-hooks.sh — global hooks in ~/.claude/settings.json
# use the host's absolute home path, so sandbox.sh must expose
# ~/.claude/hooks read-only at that same path inside the container (#837).
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -qF -- '-v "$HOME/.claude/hooks:$HOME/.claude/hooks:ro"' "$ROOT/sandbox.sh" \
    || red "sandbox.sh no longer binds ~/.claude/hooks read-only at the host path"
green "sandbox.sh: ~/.claude/hooks bound ro at host path"

# Runtime check: every registered hook command under $HOME/.claude/hooks
# exists on the host (the bind mount then makes it exist in the container).
settings="$HOME/.claude/settings.json"
if [ -f "$settings" ] && command -v jq >/dev/null; then
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        case "$cmd" in
            "$HOME/.claude/hooks/"*) [ -e "${cmd%% *}" ] || red "registered hook missing on host: $cmd" ;;
        esac
    done < <(jq -r '.. | objects | select(.type? == "command") | .command' "$settings")
    green "registered ~/.claude/hooks commands exist"
else
    green "no settings.json/jq; runtime check skipped"
fi
