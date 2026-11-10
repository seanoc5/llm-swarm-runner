#!/usr/bin/env bash
#
# test-no-awk-exit-pipe.sh — issue #746. `producer | awk '... exit ...'`
# under `set -o pipefail` races: awk quits on its first match, the producer
# can take SIGPIPE, and pipefail turns that 141 into a silent script abort
# (swarm-merge.sh died with exit 141 and no output before any gate ran).
# Same class as #648. Two checks:
#   1. no script pipes into an awk program that calls `exit` (read to the
#      end with a done-flag instead);
#   2. swarm-merge.sh's main_worktree never yields 141 in a many-worktree repo.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"

# 1. Static scan. `awk 'NR>1 {exit}' "$0"` (file arg, no pipe) is fine, so only
# flag awk invocations that follow a pipe on the same line.
hits="$(grep -nE '\|[[:space:]]*awk[^|]*[{; ]exit[ ;}]' "$SCRIPTS"/*.sh | grep -v 'exit-ok' || true)"
[ -z "$hits" ] || red "piped awk with early exit (SIGPIPE race under pipefail):
$hits"
green "no 'producer | awk ... exit' pipes in scripts/"

# 2. Behavioural loop on the real function.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/main"
git -C "$TMP/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
for i in $(seq 1 20); do git -C "$TMP/main" worktree add -q -b "b$i" "$TMP/wt-$i"; done
eval "$(awk '/^main_worktree\(\)/,/^}/' "$SCRIPTS/swarm-merge.sh")"
cd "$TMP/main"
want="$(cd "$TMP/main" && pwd -P)"
for n in $(seq 1 300); do
  got="$(main_worktree)" || red "main_worktree failed (exit $?) on iteration $n"
  [ "$(cd "$got" && pwd -P)" = "$want" ] || red "wrong main worktree: $got"
done
green "main_worktree x300 with 21 worktrees: no 141, correct path"
