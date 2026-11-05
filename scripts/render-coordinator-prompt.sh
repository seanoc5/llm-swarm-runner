#!/usr/bin/env bash
# render-coordinator-prompt.sh — print a coordinator system prompt with
# {{LLM_SWARM_DIR}} substituted (issue #767, ADR 0006 section 6).
#
# Usage: render-coordinator-prompt.sh <resident|work|chat>
#   resident  prompts/coordinator.md (the one-session coordinator, unchanged)
#   work      prompts/coordinator-work.md + prompts/coordinator-shared.md
#             (non-interactive run: triage, dispatch, opt-in automerges)
#   chat      prompts/coordinator-chat.md + prompts/coordinator-shared.md
#             (the conversation session only the operator types into)
# The shared rules live in one file and follow the mode-specific prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
P="$LLM_SWARM_DIR/prompts"

case "${1:-}" in
    resident) files=("$P/coordinator.md") ;;
    work)     files=("$P/coordinator-work.md" "$P/coordinator-shared.md") ;;
    chat)     files=("$P/coordinator-chat.md" "$P/coordinator-shared.md") ;;
    *) echo "usage: render-coordinator-prompt.sh <resident|work|chat>" >&2; exit 2 ;;
esac

for f in "${files[@]}"; do
    [ -r "$f" ] || { echo "render-coordinator-prompt.sh: cannot read $f" >&2; exit 1; }
done

first=1
for f in "${files[@]}"; do
    [ "$first" = 1 ] || printf '\n---\n\n'
    first=0
    sed "s|{{LLM_SWARM_DIR}}|$LLM_SWARM_DIR|g" "$f"
done
