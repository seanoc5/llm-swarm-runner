#!/usr/bin/env bash
#
# test-shape-next-line-rule.sh — issue #635: the prompts carry the single
# "**Next:** <who> — <action> — waiting on <trigger>" rule and its trigger
# check. Deliberately minimal greps; the behaviour is tested in
# test-pr-ready.sh, test-ready-sweep.sh and test-shape-stale-wait-note.sh.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for f in worker.md worker-bare.md; do
    grep -q 'single who-acts line' "$ROOT/prompts/$f" || red "$f: missing the Next-line rule"
    grep -q 'gh pr view N --json state,mergedAt\|gh pr view N$' "$ROOT/prompts/$f" || red "$f: missing the trigger check"
    grep -q '^\*\*Next:\*\* <who> — <action> — waiting on' "$ROOT/prompts/$f" || red "$f: handoff template lacks a Next line"
    green "$f carries the Next rule, trigger check and handoff line"
done

C="$ROOT/prompts/coordinator.md"
grep -q '^   > \*\*Next:\*\* <worker iss-N | coordinator | operator>' "$C" || red "coordinator.md: HOLD banner lacks a Next line"
grep -q 'run `gh pr view N --json state,mergedAt`: if N already merged' "$C" || red "coordinator.md: missing the trigger check"
grep -q "quote the PR's \*\*Next:\*\* line" "$C" || red "coordinator.md: digest doesn't quote the Next line"
green "coordinator.md: HOLD Next line, trigger check, digest quoting"

green "ALL TESTS PASSED"
