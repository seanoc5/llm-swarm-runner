#!/usr/bin/env bash
#
# test-shape-ci-handoff.sh — issue #572: workers do not wait on CI after their
# final push; they post a `ci-handoff:` outbox note and end terminal, and the
# coordinator waits (ci-wait.sh) and readies (pr-ready.sh). This pins both
# halves so a prompt edit cannot leave one side without the other.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$ROOT/prompts"
NOTE='ci-handoff: PR #'

for f in worker.md worker-bare.md; do
    grep -qF "$NOTE" "$P/$f" || red "$f lacks the 'ci-handoff:' note shape"
    grep -q 'never `blocked` for CI' "$P/$f" || red "$f lacks 'never blocked for CI'"
    grep -qF 'head=<full sha> risk=' "$P/$f" || red "$f ci-handoff lacks head SHA + risk"
    # No worker instruction to run ci-wait.sh remains (only prohibitions).
    if grep -n 'ci-wait\.sh' "$P/$f" | grep -vi 'no `ci-wait.sh`' >/dev/null; then
        red "$f still mentions ci-wait.sh outside a prohibition"
    fi
    green "$f: ci-handoff worker side present, no ci-wait instruction"
done

for f in coordinator.md coordinator-work.md; do
    grep -qF 'ci-handoff: PR #N head=<sha> risk=<r>' "$P/$f" || red "$f lacks ci-handoff handling"
    grep -q 'ci-wait\.sh N' "$P/$f" || red "$f ci-handoff does not run ci-wait.sh"
    grep -q 'pr-ready\.sh N' "$P/$f" || red "$f ci-handoff does not run pr-ready.sh"
    grep -q 'Never ready on remembered CI' "$P/$f" || red "$f lost the #473 never-remembered-CI rule"
    green "$f: coordinator waits with ci-wait.sh and readies with pr-ready.sh"
done
