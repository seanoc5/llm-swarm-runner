#!/usr/bin/env bash
#
# test-shape-workflow-path-filter.sh — Non-LLM unit tests for
# scripts/_workflow-path-filter.py (issue #639), the stdlib-only YAML
# line-scanner that decides whether a single workflow file's
# `pull_request` trigger would fire for a given set of changed files.
# Exercised directly here (no `gh` involved) — the gh-stubbed integration
# coverage lives in test-pr-ready.sh (Tests 15b-15d) and
# test-shape-ci-wait.sh (Tests 8b-8d).
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$SCRIPT_DIR/../scripts/_workflow-path-filter.py"
[ -f "$FILTER" ] || red "not found: $FILTER"
command -v python3 >/dev/null 2>&1 || red "python3 required"

TEST_DIR=$(mktemp -d -t workflow-path-filter-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

PASS=0
WF="$TEST_DIR/workflow.yml"
FILES="$TEST_DIR/files.txt"

run() {  # run <expected-verdict> <description>
    local expected="$1" desc="$2" got
    got="$(python3 "$FILTER" "$WF" "$FILES")"
    if [ "$got" = "$expected" ]; then
        green "$desc (-> $got)"
        PASS=$((PASS + 1))
    else
        red "$desc: expected '$expected', got '$got'"
    fi
}

# ─────────────── Test 1: paths-ignore, every changed file matches → excluded ───────────────

heading "Test 1: paths-ignore covers every changed file -> excluded"
cat > "$WF" <<'EOF'
name: build
on:
  pull_request:
    paths-ignore:
      - 'docs/**'
      - '**.md'
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
EOF
printf 'docs/foo.md\nREADME.md\n' > "$FILES"
run excluded "all changed files under paths-ignore patterns"

# ─────────────── Test 2: paths-ignore, one changed file falls outside it → triggers ───────

heading "Test 2: one changed file falls outside every paths-ignore pattern -> triggers"
printf 'docs/foo.md\nsrc/main.py\n' > "$FILES"
run triggers "a non-ignored changed file forces a real trigger"

# ─────────────── Test 3: no path filter at all → always triggers ──────────────────────────

heading "Test 3: pull_request trigger with no paths/paths-ignore at all -> always triggers"
cat > "$WF" <<'EOF'
name: tests
"on":
  pull_request:
  push:
    branches: [master]
EOF
printf 'docs/foo.md\n' > "$FILES"
run triggers "an unfiltered pull_request trigger always applies, even to a docs-only change"

# ─────────────── Test 4: paths allowlist, no changed file matches → excluded ──────────────

heading "Test 4: paths allowlist that matches none of the changed files -> excluded"
cat > "$WF" <<'EOF'
name: api
on:
  pull_request:
    paths:
      - 'src/**'
      - 'api/*.py'
EOF
printf 'docs/foo.md\nREADME.md\n' > "$FILES"
run excluded "none of the changed files match the paths allowlist"

# ─────────────── Test 5: paths allowlist, one changed file matches → triggers ─────────────

heading "Test 5: paths allowlist with at least one matching changed file -> triggers"
printf 'docs/foo.md\nsrc/app.py\n' > "$FILES"
run triggers "one changed file under the paths allowlist is enough to trigger"

# ─────────────── Test 6: no pull_request trigger at all → no-trigger ──────────────────────

heading "Test 6: workflow has no pull_request trigger at all -> no-trigger"
cat > "$WF" <<'EOF'
name: nightly
on:
  schedule:
    - cron: '0 3 * * *'
EOF
printf 'anything.txt\n' > "$FILES"
run no-trigger "a push/schedule-only workflow is irrelevant to any PR"

# ─────────────── Test 7: flow-form "on: [push, pull_request]" → always triggers ───────────

heading "Test 7: flow-form 'on: [push, pull_request]' (no paths filter possible) -> triggers"
cat > "$WF" <<'EOF'
name: flow
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
EOF
printf 'docs/foo.md\n' > "$FILES"
run triggers "a flow-form on: list with pull_request always triggers"

# ─────────────── Test 8: scalar-form "on: pull_request" → always triggers ─────────────────

heading "Test 8: scalar-form 'on: pull_request' -> triggers"
cat > "$WF" <<'EOF'
name: scalar
on: pull_request
jobs:
  build:
    runs-on: ubuntu-latest
EOF
printf 'docs/foo.md\n' > "$FILES"
run triggers "a bare scalar on: pull_request always triggers"

# ─────────────── Test 9: push-only workflow (pull_request absent from a block on:) ────────

heading "Test 9: block-form on: with only push -> no-trigger"
cat > "$WF" <<'EOF'
name: push-only
on:
  push:
    branches: [main]
EOF
printf 'docs/foo.md\n' > "$FILES"
run no-trigger "push-only block-form on: has no pull_request key at all"

# ─────────────── Test 10: inline flow map on pull_request: itself -> unknown (not a guess) ─

heading "Test 10: pull_request: { types: [opened] } (inline flow map) -> triggers (no paths mentioned)"
cat > "$WF" <<'EOF'
name: inline
on:
  pull_request: { types: [opened, synchronize] }
EOF
printf 'docs/foo.md\n' > "$FILES"
run triggers "an inline flow map with no 'paths' substring is read as unrestricted"

heading "Test 10b: an inline flow map that DOES mention paths -> unknown, never guessed"
cat > "$WF" <<'EOF'
name: inline-paths
on:
  pull_request: { paths: ['docs/**'] }
EOF
printf 'docs/foo.md\n' > "$FILES"
run unknown "an inline flow map mentioning paths is deliberately not parsed — fails toward unknown"

# ─────────────── Test 11: not a recognizable workflow file at all -> unknown ──────────────

heading "Test 11: no top-level 'on:' key at all -> unknown"
cat > "$WF" <<'EOF'
this is not a workflow file
EOF
printf 'docs/foo.md\n' > "$FILES"
run unknown "a file with no top-level on: key can't be read as a workflow trigger"

# ─────────────── Test 12: multi-line flow list -> unknown, not silently empty ─────────────

heading "Test 12: a paths-ignore flow list split across lines -> unknown, not guessed as empty"
cat > "$WF" <<'EOF'
name: multiline-flow
on:
  pull_request:
    paths-ignore: [
      'docs/**'
    ]
EOF
printf 'docs/foo.md\n' > "$FILES"
run unknown "an unclosed single-line flow list is not parsed into a (wrongly empty) pattern list"

# ─────────────── Test 13: ** pattern matches across directories ───────────────────────────

heading "Test 13: '**.md' matches a deeply nested markdown file, not just the root"
cat > "$WF" <<'EOF'
name: deep
on:
  pull_request:
    paths-ignore:
      - '**.md'
EOF
printf 'docs/nested/deep/guide.md\n' > "$FILES"
run excluded "'**.md' excludes a markdown file several directories deep"

# ─────────────── Test 14: negation pattern -> unknown, not guessed ────────────────────────

heading "Test 14: a paths-ignore list containing a '!' negation -> unknown, not guessed"
cat > "$WF" <<'EOF'
name: negated
on:
  pull_request:
    paths-ignore:
      - 'docs/**'
      - '!docs/keep.md'
EOF
printf 'docs/keep.md\n' > "$FILES"
run unknown "a '!' re-inclusion pattern is order-sensitive and deliberately not parsed"

# ─────────────── Test 15: trailing comment on the "on:" line is stripped ──────────────────

heading "Test 15: a trailing comment on 'on:' doesn't get read as an inline value"
cat > "$WF" <<'EOF'
name: commented
on:  # run on PR and push
  pull_request:
    paths-ignore:
      - 'docs/**'
  push:
    branches: [main]
EOF
printf 'docs/foo.md\n' > "$FILES"
run excluded "the comment after 'on:' must not be read as a flow/scalar trigger value"

# ─────────────── Test 16: pull_request_target is recognized like pull_request ─────────────

heading "Test 16: block-form 'pull_request_target:' is recognized, not read as no-trigger"
cat > "$WF" <<'EOF'
name: target
on:
  pull_request_target:
    paths-ignore:
      - 'docs/**'
EOF
printf 'docs/foo.md\n' > "$FILES"
run excluded "pull_request_target uses the same paths-ignore syntax as pull_request"

printf 'docs/foo.md\nsrc/main.py\n' > "$FILES"
run triggers "pull_request_target still triggers when a changed file falls outside paths-ignore"

heading "Results: $PASS checks passed"
green "All checks passed."
