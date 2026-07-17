#!/usr/bin/env bash
#
# test-shape-lint.sh — Shape tests for lint-brief.sh (ringer manifest-lint
# concept; docs/ringer-adoptions.md #6). Pure text-in/warnings-out — no
# stubs needed.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/../scripts/lint-brief.sh"
[ -x "$LINT" ] || red "lint-brief.sh not executable: $LINT"

TEST_DIR=$(mktemp -d -t shape-lint-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

heading "Test 1: verifiable brief → clean"
cat > "$TEST_DIR/good.md" <<'EOF'
Preamble noise the lint must ignore.

## Task

Fix the flaky retry logic in scripts/worker-listener.sh so a timed-out
check is retried at most once. Add coverage in tests/test-shape-checks.sh.

Acceptance criteria:
- [ ] retry fires exactly once on check failure
- [ ] WORKER_CHECK_RETRY=0 disables it

<!-- SWARM_CHECK: tests/test-shape-checks.sh -->
EOF
OUT=$("$LINT" "$TEST_DIR/good.md")
echo "$OUT" | grep -q "clean" || { echo "$OUT"; red "expected clean verdict"; }
green "verifiable brief passes clean"

heading "Test 2: no done-definition + no files + short → 3 findings, warn-only exit 0"
cat > "$TEST_DIR/bad.md" <<'EOF'
## Task

Make everything better.
EOF
if OUT=$("$LINT" "$TEST_DIR/bad.md"); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "warn-only mode must exit 0 (got $RC)"
echo "$OUT" | grep -q "no-done-definition" || { echo "$OUT"; red "missing no-done-definition"; }
echo "$OUT" | grep -q "no-named-files"     || { echo "$OUT"; red "missing no-named-files"; }
echo "$OUT" | grep -q "underspecified"     || { echo "$OUT"; red "missing underspecified"; }
green "vague brief: all three findings, exit 0"

heading "Test 3: --strict exits 1 on findings"
if "$LINT" --strict "$TEST_DIR/bad.md" >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "--strict should exit 1 (got $RC)"
if "$LINT" --strict "$TEST_DIR/good.md" >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "--strict on clean brief should exit 0 (got $RC)"
green "--strict: 1 on findings, 0 on clean"

heading "Test 4: check-cannot-fail"
cat > "$TEST_DIR/cantfail.md" <<'EOF'
## Task

Update the README.md quick-start section with the new WORKER_CHECK env
vars and their defaults, keeping the existing table format intact.

<!-- SWARM_CHECK: true -->
EOF
OUT=$("$LINT" "$TEST_DIR/cantfail.md")
echo "$OUT" | grep -q "check-cannot-fail" || { echo "$OUT"; red "missing check-cannot-fail"; }
green "SWARM_CHECK 'true' flagged as unable to fail"

heading "Test 5: preamble noise does not mask a fileless task"
cat > "$TEST_DIR/preamble.md" <<'EOF'
Docs index: see docs/refs.md and scripts/setup.sh for details.

---

## Task

Improve performance somehow. Make it faster please. This text is long
enough to escape the underspecified lint because it rambles on and on
about nothing in particular without ever naming a single artifact.

Acceptance criteria:
- [ ] it is faster
EOF
OUT=$("$LINT" "$TEST_DIR/preamble.md")
echo "$OUT" | grep -q "no-named-files" || { echo "$OUT"; red "preamble paths leaked into task lint scope"; }
green "lint scopes to ## Task — preamble paths don't mask no-named-files"

heading "All lint shape tests passed"
green "clean pass, findings, --strict, can't-fail check, ## Task scoping"
