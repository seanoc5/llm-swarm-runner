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

# issue #644 round-4: every call now takes a head-branch argument, used only
# to evaluate a `push` trigger's branches/branches-ignore filter. Most of the
# tests below are about pull_request path filtering, or about a push trigger
# with no branch filter at all, so a default that doesn't collide with any
# of the literal "main"/"master" branches filters in this file's push
# fixtures keeps those tests about what they say they're about; tests that
# are specifically about the branch filter pass their own head branch.
DEFAULT_HEAD_BRANCH="feature/change"

run() {  # run <expected-verdict> <description> [head-branch] [base-branch]
    local expected="$1" desc="$2" head="${3:-$DEFAULT_HEAD_BRANCH}" got
    local base_args=()
    [ -n "${4:-}" ] && base_args=("$4")
    got="$(python3 "$FILTER" "$WF" "$FILES" "$head" "${base_args[@]}")"
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
    paths-ignore:
      - 'docs/**'
      - '**.md'
jobs:
  build:
    runs-on: ubuntu-latest
EOF
printf 'docs/foo.md\nREADME.md\n' > "$FILES"
# DEFAULT_HEAD_BRANCH ("feature/change") doesn't match the push trigger's
# `branches: [main]`, so push's own verdict is "no-trigger" (issue #644
# round-4: its paths-ignore is never even looked at) — pull_request's
# confident path exclusion is what actually drives "excluded" here.
run excluded "pull_request's paths-ignore confidently excludes every changed file (push doesn't apply to this head branch at all)"

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

# ─── Test 9/9b/9c: push-only workflow (no pull_request key at all) — issue ───
# #644 third follow-up: a same-repo PR's branch push fires a push-only
# workflow too, and that run lands on the exact commit `gh pr checks`
# reads, so this must never be read as "no-trigger" when its branch filter
# allows this head branch. issue #644 round-4: a push trigger's OWN path
# filter is never evaluated at all (it applies to the push's own diff, not
# this PR's changed files) — so a push-only workflow is "triggers" or
# "no-trigger" purely off its branch filter, never "excluded".

heading "Test 9: block-form on: with only push, branch filter matches, no path filter at all -> triggers"
cat > "$WF" <<'EOF'
name: push-only
on:
  push:
    branches: [main]
EOF
printf 'docs/foo.md\n' > "$FILES"
run triggers "a push-only workflow whose branch filter matches this PR's head branch always creates a run on the PR's head commit" "main"

heading "Test 9b: push-only workflow, branch filter matches, paths-ignore covers every changed file -> triggers anyway (issue #644 round-4 fix — a push's path filter is NEVER read)"
cat > "$WF" <<'EOF'
name: push-only-filtered
on:
  push:
    branches: [main]
    paths-ignore:
      - 'docs/**'
      - '**.md'
EOF
printf 'docs/foo.md\nREADME.md\n' > "$FILES"
run triggers "a push-only workflow's own paths-ignore is irrelevant to the PR's changed files — GitHub evaluates it against the push's own diff, which this scanner can't see, so this must still wait rather than reading as excluded" "main"

heading "Test 9c: push-only workflow, branch filter matches, paths-ignore filter, a changed file falls outside it -> still triggers"
printf 'docs/foo.md\nsrc/main.py\n' > "$FILES"
run triggers "a push-only workflow with a non-ignored changed file still creates a real run (same reasoning as 9b: the path filter was never consulted either way)" "main"

heading "Test 9d: push trigger with NO branch filter at all, paths-ignore covers every changed file -> triggers, never excluded"
cat > "$WF" <<'EOF'
name: push-no-branch-filter
on:
  push:
    paths-ignore:
      - 'docs/**'
      - '**.md'
EOF
printf 'docs/foo.md\nREADME.md\n' > "$FILES"
run triggers "a push trigger with no branches filter fires for every branch, including this PR's — its paths-ignore (meant for the push's own diff) must never be read as excluding a docs-only PR"

heading "Test 9e: push trigger's branches-ignore matches the PR's own head branch -> no-trigger (legitimate: no push run can ever attach to this head)"
cat > "$WF" <<'EOF'
name: push-branches-ignore
on:
  push:
    branches-ignore:
      - 'release/*'
EOF
printf 'src/main.py\n' > "$FILES"
run no-trigger "a branches-ignore pattern matching the PR's own head branch rules out this push trigger entirely" "release/2.0"

heading "Test 9f: same branches-ignore pattern, a head branch that does NOT match -> triggers"
run triggers "a branches-ignore pattern that doesn't match this PR's head branch leaves the push trigger fully live" "feature/change"

heading "Test 9g: civicstrata's real build.yml fixture — pull_request + push both paths-ignore docs/md, docs-only PR from a non-master branch -> excluded"
# civicstrata#602/#603 lineage, issue #644 round-4 coordinator ruling point 2:
# pull_request's path filter confidently excludes every changed file; push's
# branches: [master] doesn't match this PR's head branch, so push is
# legitimately "no-trigger" and contributes no contradicting evidence —
# overall verdict must still be "excluded".
cat > "$WF" <<'EOF'
name: build
on:
  pull_request:
    paths-ignore: ['**.md', 'docs/**']
  push:
    branches: [master]
    paths-ignore: ['**.md', 'docs/**']
jobs:
  build:
    runs-on: ubuntu-latest
EOF
printf 'docs/foo.md\nREADME.md\n' > "$FILES"
run excluded "a docs-only PR from fix/issue-N (not master) comes out confidently excluded, matching civicstrata's real workflow" "fix/issue-N"

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
    paths-ignore:
      - 'docs/**'
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

# ─────────────── Test 17: "src/**/*.py" matches "src/main.py" (zero directories) ──────────

heading "Test 17: 'src/**/*.py' matches a file directly under src/, not just nested deeper"
cat > "$WF" <<'EOF'
name: api
on:
  pull_request:
    paths:
      - 'src/**/*.py'
EOF
printf 'src/main.py\n' > "$FILES"
run triggers "'**/ ' must match zero directories too, not only one-or-more"

# ─────────────── Test 18: "**/*.py" matches a root-level file (zero directories) ──────────

heading "Test 18: '**/*.py' matches a root-level file with no directory at all"
cat > "$WF" <<'EOF'
name: api
on:
  pull_request:
    paths:
      - '**/*.py'
EOF
printf 'setup.py\n' > "$FILES"
run triggers "a leading '**/ ' must match the empty prefix, not require a directory"

# ─────────────── Test 19: "docs/**" matches "docs" itself (zero directories) ──────────────

heading "Test 19: 'docs/**' paths-ignore excludes the bare 'docs' path itself, not just contents"
cat > "$WF" <<'EOF'
name: build
on:
  pull_request:
    paths-ignore:
      - 'docs/**'
EOF
printf 'docs\n' > "$FILES"
run excluded "a trailing '/**' must match zero directories too (the directory entry itself)"

# ─────────────── Test 20: unsupported glob syntax ([...], +, {}) -> unknown, not guessed ──

heading "Test 20: a paths-ignore pattern using a [...] character class -> unknown"
cat > "$WF" <<'EOF'
name: charclass
on:
  pull_request:
    paths-ignore:
      - 'docs/file[0-9].md'
EOF
printf 'docs/file1.md\n' > "$FILES"
run unknown "a [...] character class isn't implemented by this matcher — don't guess"

heading "Test 20b: a paths pattern using {}  brace expansion -> unknown"
cat > "$WF" <<'EOF'
name: brace
on:
  pull_request:
    paths:
      - 'src/{a,b}.py'
EOF
printf 'src/a.py\n' > "$FILES"
run unknown "{} brace expansion isn't implemented by this matcher — don't guess"

# ─────── Test 21: a filtered pull_request + an unfiltered pull_request_target ─────────────
# (self-review round-3 caveat on #644, reproduced live: checking only
# whichever PR-type key is found first wrongly read this as "excluded")

heading "Test 21: pull_request paths-ignore excludes the file, but a bare pull_request_target also exists -> triggers"
cat > "$WF" <<'EOF'
name: mixed-triggers
on:
  pull_request:
    paths-ignore:
      - 'docs/**'
  pull_request_target:
EOF
printf 'docs/a.md\n' > "$FILES"
run triggers "the unfiltered pull_request_target trigger still fires even though pull_request's filter excludes every changed file"

# ─── Test 22: a workflow_run trigger, no pull_request/push at all -> unknown ───────────────
# (issue #644 third follow-up item 4: a workflow_run job can check out and
# report status against github.event.workflow_run.head_sha, including a
# PR's head, depending on the job's own code — this scanner can't rule
# that out, so presence alone must fail toward "unknown", never
# "no-trigger".)

heading "Test 22: block-form on: with only workflow_run -> unknown, never no-trigger"
cat > "$WF" <<'EOF'
name: workflow-run-only
on:
  workflow_run:
    workflows: ['CI']
    types: [completed]
EOF
printf 'docs/foo.md\n' > "$FILES"
run unknown "a workflow_run-only trigger can still attach a run to a commit — fail toward unknown, not no-trigger"

heading "Test 22b: flow/scalar form 'on: workflow_run' -> unknown, never no-trigger"
cat > "$WF" <<'EOF'
name: workflow-run-scalar
on: workflow_run
EOF
printf 'docs/foo.md\n' > "$FILES"
run unknown "the flow/scalar on: form with workflow_run also fails toward unknown"

# ─── Tests 23-23g: issue #670 — pull_request branches/branches-ignore vs the PR's BASE branch ───
#
# A stacked PR (base = another PR's branch) never gets a run when every
# workflow's `pull_request: branches:` allowlist is just the default branch.

heading "Test 23: pull_request branches [master], PR based on a stacked branch -> excluded-base"
cat > "$WF" <<'EOF'
name: ci
on:
  pull_request:
    branches: [master]
EOF
printf 'src/main.py\n' > "$FILES"
run excluded-base "a base branch outside the allowlist is a confident, permanent exclusion" feature/change fix/issue-1823

heading "Test 23b: same workflow, base branch IS master -> triggers"
run triggers "base branch matches the allowlist (src file, no path filter)" feature/change master

heading "Test 23c: no base branch argument -> base filters not evaluated (pre-#670 behavior)"
run triggers "omitting the base branch leaves branches filters unevaluated"

heading "Test 23d: branches-ignore matching the base branch -> excluded-base"
cat > "$WF" <<'EOF'
on:
  pull_request:
    branches-ignore:
      - 'fix/**'
EOF
run excluded-base "branches-ignore with a glob that matches the base" feature/change fix/issue-1823
run triggers "branches-ignore that does not match the base" feature/change master

heading "Test 23e: base allowed but path filter excludes everything -> plain excluded, not excluded-base"
cat > "$WF" <<'EOF'
on:
  pull_request:
    branches: [master]
    paths-ignore: ['docs/**']
EOF
printf 'docs/a.md\n' > "$FILES"
run excluded "path exclusion is still reported as excluded" feature/change master

heading "Test 23f: base excluded on pull_request, but an unfiltered push trigger can still fire -> triggers"
cat > "$WF" <<'EOF'
on:
  pull_request:
    branches: [master]
  push:
EOF
printf 'src/main.py\n' > "$FILES"
run triggers "the push trigger still attaches a run to the head commit" feature/change fix/issue-1823

heading "Test 23g: unparseable negated branch pattern -> unknown"
cat > "$WF" <<'EOF'
on:
  pull_request:
    branches:
      - '**'
      - '!fix/**'
EOF
run unknown "negation in a branch filter is not guessed at" feature/change fix/issue-1823

heading "Results: $PASS checks passed"
green "All checks passed."
