#!/usr/bin/env bash
#
# protected-paths-check.sh — does a PR touch a path the unattended 🔴 merge
# (swarm-merge.sh --auto-high, issue #1011) must never merge on its own?
#
# Usage: protected-paths-check.sh <PR#>
#
# Rules come from scripts/protected-paths.txt plus, when present,
# <project>/.swarm/protected-paths.txt (extends, never removes). Override the
# two locations with PROTECTED_PATHS_FILE / PROTECTED_PATHS_EXTRA (tests).
#
# Exit codes:
#   0   clean: no changed path is protected, no data-dropping migration
#   10  protected: each hit printed as `protected: <kind> — <path or line>`
#   1   usage / gh / rules-file error — callers must fail closed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR="${1:-}"
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "usage: protected-paths-check.sh <PR#>" >&2; exit 1; }

RULES="${PROTECTED_PATHS_FILE:-$SCRIPT_DIR/protected-paths.txt}"
[ -r "$RULES" ] || { echo "ERROR: protected-paths file not readable: $RULES" >&2; exit 1; }
EXTRA="${PROTECTED_PATHS_EXTRA:-}"
if [ -z "$EXTRA" ]; then
  MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '!d && /^worktree / { print $2; d=1 }')"
  [ -z "$MAIN_WT" ] || EXTRA="$MAIN_WT/.swarm/protected-paths.txt"
fi

# kind -> newline-joined regexes
rules_of() {   # rules_of <kind>
  local f
  for f in "$RULES" "$EXTRA"; do
    [ -n "$f" ] && [ -r "$f" ] || continue
    sed -nE "s/^$1:[[:space:]]*(.+)$/\1/p" "$f"
  done
}
PATH_RES="$(rules_of path)"
MIG_RES="$(rules_of migration)"
DEST_RES="$(rules_of destructive)"
[ -n "$PATH_RES" ] || { echo "ERROR: $RULES has no 'path:' rules — refusing to treat everything as clean" >&2; exit 1; }

FILES="$(gh pr diff "$PR" --name-only 2>/dev/null)" \
  || { echo "ERROR: couldn't list PR #$PR's changed files" >&2; exit 1; }
[ -n "$FILES" ] || { echo "ERROR: PR #$PR lists no changed files" >&2; exit 1; }

HITS=0
while IFS= read -r re; do
  [ -n "$re" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "protected: path — $f (rule: $re)"; HITS=$((HITS+1))
  done < <(grep -E -i -- "$re" <<<"$FILES" || true)
done <<<"$PATH_RES"

# Data-dropping migrations: scan only the ADDED lines of migration files.
MIG_FILES=""
while IFS= read -r re; do
  [ -n "$re" ] || continue
  MIG_FILES+="$(grep -E -i -- "$re" <<<"$FILES" || true)"$'\n'
done <<<"$MIG_RES"
MIG_FILES="$(sed '/^$/d' <<<"$MIG_FILES" | sort -u)"
if [ -n "$MIG_FILES" ] && [ -n "$DEST_RES" ]; then
  DIFF="$(gh pr diff "$PR" 2>/dev/null)" || { echo "ERROR: couldn't read PR #$PR's diff" >&2; exit 1; }
  # per-file added lines: awk tracks the current `+++ b/<path>`
  ADDED="$(awk '/^\+\+\+ /{f=$2; sub(/^b\//,"",f); next} /^\+/{print f "\t" substr($0,2)}' <<<"$DIFF")"
  while IFS= read -r mf; do
    [ -n "$mf" ] || continue
    LINES="$(awk -F'\t' -v f="$mf" '$1==f{ $1=""; print substr($0,2) }' <<<"$ADDED")"
    while IFS= read -r re; do
      [ -n "$re" ] || continue
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        echo "protected: data-dropping migration — $mf: ${l:0:120}"; HITS=$((HITS+1))
      done < <(grep -E -i -- "$re" <<<"$LINES" || true)
    done <<<"$DEST_RES"
  done <<<"$MIG_FILES"
fi

[ "$HITS" = 0 ] && { echo "protected-paths: clean (PR #$PR)"; exit 0; }
exit 10
