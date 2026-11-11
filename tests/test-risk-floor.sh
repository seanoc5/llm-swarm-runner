#!/usr/bin/env bash
#
# test-risk-floor.sh — Non-LLM regression test for scripts/risk-floor.sh
# (issue #731). gh is a PATH shim: `gh api …/files` serves GH_FILES_TSV (the
# script's own --jq is bypassed; the shim emits the already-tab-separated
# "path status additions deletions" rows), `gh pr diff` serves GH_DIFF.
# Every rule gets a "fires" and a "doesn't fire" case, then the --apply bump
# path (marker + footer rewritten, comment naming the rule, idempotent).
# shellcheck disable=SC2089,SC2090  # GH_DIFF carries literal quotes
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

# the worker env carries TASK_ID and may carry RISK_FLOOR_*; neither may leak in
unset TASK_ID RISK_FLOOR RISK_FLOOR_MAX_LINES RISK_FLOOR_MIGRATION_RE RISK_FLOOR_SENSITIVE_RE RISK_FLOOR_TEST_RE RISK_FLOOR_SKIP_RE RISK_FLOOR_BRIEF RISK_FLOOR_DISABLE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOOR="$SCRIPT_DIR/../scripts/risk-floor.sh"
[ -x "$FLOOR" ] || red "risk-floor.sh not executable: $FLOOR"

TEST_DIR=$(mktemp -d -t risk-floor-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
SHIM_DIR="$TEST_DIR/shims"; mkdir -p "$SHIM_DIR"
GH_LOG="$TEST_DIR/gh.log"
BODY_FILE="$TEST_DIR/body.txt"
EDITED_BODY="$TEST_DIR/edited-body.txt"
COMMENT_LOG="$TEST_DIR/comments.log"
ISSUE_BODY_FILE="$TEST_DIR/issue-body.txt"

cat > "$SHIM_DIR/gh" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
  "api "*) printf '%b' "\${GH_FILES_TSV:-}" ;;
  "pr diff") [ "\${GH_DIFF_FAIL:-0}" = 1 ] && { echo "HTTP 406: diff too large" >&2; exit 1; }; printf '%b' "\${GH_DIFF:-}" ;;
  "pr view")
    if   grep -q -- 'headRefOid' <<<"\$*"; then echo abc1234
    elif grep -q -- '--json comments' <<<"\$*"; then
      if [ -s "$COMMENT_LOG" ] && grep -q 'SWARM_RISK_FLOOR: medium head=abc1234 ' "$COMMENT_LOG"; then echo 1; else echo 0; fi
    else cat "$BODY_FILE"; fi ;;
  "issue view") cat "$ISSUE_BODY_FILE" 2>/dev/null || true ;;
  "pr edit") cat > "$EDITED_BODY" ;;
  "pr comment") cat >> "$COMMENT_LOG" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIM_DIR/gh"

# run_floor [args…] — prints stdout, sets rc
run_floor() {
    : > "$GH_LOG"; rm -f "$EDITED_BODY"
    rc=0
    # cwd = scratch dir: the script loads <cwd git root or cwd>/.swarm/.env, which must not be this worktree's
    OUT="$(cd "$TEST_DIR" && PATH="$SHIM_DIR:$PATH" "$FLOOR" "$@" 2>"$TEST_DIR/err.log")" || rc=$?
}
files() { GH_FILES_TSV=""; for row in "$@"; do GH_FILES_TSV+="$row\n"; done; export GH_FILES_TSV; }
floor_is() { grep -qx "floor: $1" <<<"$OUT" || red "expected floor: $1, got: $OUT $(cat "$TEST_DIR/err.log")"; }
has_rule() { grep -q "^rule: $1" <<<"$OUT" || red "expected rule '$1', got: $OUT"; }
no_rule() { ! grep -q "^rule: $1" <<<"$OUT" || red "rule '$1' must not fire, got: $OUT"; }
export GH_DIFF=""
printf '<!-- BLIND_MERGE_RISK: low -->\nbody\n' > "$BODY_FILE"

heading "Test 1: clean small change → floor low, no rules"
files 'src/main/kotlin/Foo.kt\tmodified\t10\t2'
run_floor 7
[ "$rc" -eq 0 ] || red "rc=$rc"; floor_is low
grep -q '^rule:' <<<"$OUT" && red "no rule expected: $OUT"
green "floor low"

heading "Test 2: migrations — fires (Flyway, Alembic) / doesn't (a file merely named migration)"
files 'src/main/resources/db/migration/V9__add_col.sql\tadded\t3\t0'
run_floor 7; floor_is medium; has_rule migrations
files 'app/alembic/versions/abc_add_col.py\tadded\t20\t0'
run_floor 7; floor_is medium; has_rule migrations
files 'docs/migration-guide.md\tmodified\t4\t1' 'src/Migrator.kt\tmodified\t4\t1'
run_floor 7; floor_is low; no_rule migrations
green "migrations rule"

heading "Test 3: sensitive paths — fires (build file, Dockerfile, workflow, SecurityConfig) / doesn't"
for p in build.gradle.kts svc/pyproject.toml Dockerfile .github/workflows/ci.yml src/main/kotlin/WebSecurityConfig.kt; do
    files "$p\tmodified\t2\t1"; run_floor 7; floor_is medium; has_rule sensitive
done
files 'src/main/kotlin/SecurityNotes.kt\tmodified\t2\t1' 'docs/Dockerfile-notes.md\tmodified\t1\t1' 'README.md\tmodified\t1\t1'
run_floor 7; floor_is low; no_rule sensitive
green "sensitive rule"

heading "Test 4: lines — fires above the limit, not at it; RISK_FLOOR_MAX_LINES overrides"
files 'src/A.kt\tmodified\t200\t101'
run_floor 7; floor_is medium; has_rule lines
files 'src/A.kt\tmodified\t200\t100'
run_floor 7; floor_is low; no_rule lines
files 'src/A.kt\tmodified\t30\t21'
RISK_FLOOR_MAX_LINES=50 run_floor 7; floor_is medium; has_rule lines
RISK_FLOOR_MAX_LINES=51 run_floor 7; floor_is low
green "lines rule"

heading "Test 5: tests — deleted test file fires; non-test deletion doesn't"
files 'src/test/kotlin/FooTest.kt\tremoved\t0\t40'
run_floor 7; floor_is medium; has_rule tests
files 'src/main/kotlin/Foo.kt\tremoved\t0\t40'
run_floor 7; floor_is low; no_rule tests
green "deleted tests"

heading "Test 6: tests — added @Disabled / skip in a test file fires; in main code or as removal doesn't"
files 'src/test/kotlin/FooTest.kt\tmodified\t1\t0'
GH_DIFF='diff --git a/src/test/kotlin/FooTest.kt b/src/test/kotlin/FooTest.kt\n--- a/src/test/kotlin/FooTest.kt\n+++ b/src/test/kotlin/FooTest.kt\n@@ -1,1 +1,2 @@\n+@Disabled("flaky")\n fun x() {}\n'
export GH_DIFF; run_floor 7; floor_is medium; has_rule tests
GH_DIFF='diff --git a/tests/test_x.py b/tests/test_x.py\n--- a/tests/test_x.py\n+++ b/tests/test_x.py\n@@ -1 +1,2 @@\n+@pytest.mark.skip(reason="later")\n'
files 'tests/test_x.py\tmodified\t1\t0'; export GH_DIFF; run_floor 7; floor_is medium; has_rule tests
# same marker in non-test code: not this rule's business
GH_DIFF='diff --git a/src/Foo.kt b/src/Foo.kt\n--- a/src/Foo.kt\n+++ b/src/Foo.kt\n@@ -1 +1,2 @@\n+// @Disabled\n'
files 'src/Foo.kt\tmodified\t1\t0'; export GH_DIFF; run_floor 7; floor_is low; no_rule tests
# a REMOVED @Disabled (re-enabling a test) is a '-' line: must not fire
GH_DIFF='diff --git a/src/test/FooTest.kt b/src/test/FooTest.kt\n--- a/src/test/FooTest.kt\n+++ b/src/test/FooTest.kt\n@@ -1,2 +1 @@\n-@Disabled\n fun x() {}\n'
files 'src/test/FooTest.kt\tmodified\t0\t1'; export GH_DIFF; run_floor 7; floor_is low; no_rule tests
# a Spring property that merely ends in enabled=false is not a disabled test
# (a real false positive found by the fand-app dry run, PR #2143)
GH_DIFF='diff --git a/src/test/kotlin/XTest.kt b/src/test/kotlin/XTest.kt\n--- a/src/test/kotlin/XTest.kt\n+++ b/src/test/kotlin/XTest.kt\n@@ -1 +1,2 @@\n+    properties = ["fand.security.rate-limit.enabled=false"],\n'
files 'src/test/kotlin/XTest.kt\tmodified\t1\t0'; export GH_DIFF; run_floor 7; floor_is low; no_rule tests
GH_DIFF=""; export GH_DIFF
green "disabled tests"

heading "Test 6b: GitHub refuses the diff (very large PR) → floor medium with a reason, not an error"
files 'src/Foo.kt\tmodified\t10\t2'
GH_DIFF_FAIL=1 run_floor 7
[ "$rc" -eq 0 ] || red "an unreadable diff must not error out, got rc=$rc: $OUT $(cat "$TEST_DIR/err.log")"
floor_is medium; has_rule tests
grep -q 'could not be read' <<<"$OUT" || red "reason missing: $OUT"
# ... and --apply still bumps and comments for it
printf '<!-- BLIND_MERGE_RISK: low -->\nbody\n' > "$BODY_FILE"; : > "$COMMENT_LOG"
GH_DIFF_FAIL=1 run_floor --apply 7
[ "$rc" -eq 10 ] || red "expected the huge-diff PR to be bumped (10), got $rc"
grep -q 'could not be read' "$COMMENT_LOG" || red "comment must explain: $(cat "$COMMENT_LOG")"
# the disabled-test rule off → the unreadable diff is not consulted at all
RISK_FLOOR_DISABLE=tests GH_DIFF_FAIL=1 run_floor 7; floor_is low
green "unreadable diff raises the floor and is explained"

heading "Test 7: scope — advisory note only, never bumps; skipped with no brief text"
files 'src/main/kotlin/Foo.kt\tmodified\t5\t1' 'scripts/unrelated.sh\tmodified\t5\t1'
printf 'Fix the bug in src/main/kotlin/Foo.kt\n' > "$TEST_DIR/brief.md"
RISK_FLOOR_BRIEF="$TEST_DIR/brief.md" run_floor 7
floor_is low
grep -q '^note: scope — .*scripts/unrelated.sh' <<<"$OUT" || red "scope note missing: $OUT"
grep -q 'src/main/kotlin/Foo.kt' <<<"$(grep '^note:' <<<"$OUT")" && red "mentioned file flagged: $OUT"
printf 'Anything under scripts/ is fair game, plus Foo.kt\n' > "$TEST_DIR/brief.md"
RISK_FLOOR_BRIEF="$TEST_DIR/brief.md" run_floor 7
grep -q '^note:' <<<"$OUT" && red "dir/basename mentions should count as in scope: $OUT"
run_floor 7   # no brief, PR body names no issue
grep -q '^note:' <<<"$OUT" && red "no text → rule skipped silently: $OUT"
printf '<!-- BLIND_MERGE_RISK: low -->\nCloses #55\n' > "$BODY_FILE"
printf 'Touch only docs/ please\n' > "$ISSUE_BODY_FILE"
run_floor 7; grep -q '^note: scope' <<<"$OUT" || red "closing-issue text should feed the scope rule: $OUT"
floor_is low
printf '<!-- BLIND_MERGE_RISK: low -->\nbody\n' > "$BODY_FILE"; rm -f "$ISSUE_BODY_FILE"
green "scope is advisory"

heading "Test 8: RISK_FLOOR_DISABLE turns individual rules off"
files 'db/migration/V1__x.sql\tadded\t1\t0' 'build.gradle.kts\tmodified\t1\t1'
RISK_FLOOR_DISABLE="migrations" run_floor 7; floor_is medium; no_rule migrations; has_rule sensitive
RISK_FLOOR_DISABLE="migrations,sensitive" run_floor 7; floor_is low
green "disable list"

heading "Test 9: custom pattern via RISK_FLOOR_SENSITIVE_RE"
files 'scripts/swarm-merge.sh\tmodified\t1\t1'
run_floor 7; floor_is low
RISK_FLOOR_SENSITIVE_RE='^scripts/swarm-merge\.sh$' run_floor 7; floor_is medium; has_rule sensitive
green "custom regex"

heading "Test 10: several rules → all listed, floor still medium"
files 'db/migration/V1__x.sql\tadded\t400\t0' 'build.gradle.kts\tmodified\t1\t1'
run_floor 7; floor_is medium; has_rule migrations; has_rule sensitive; has_rule lines
green "multiple rules listed"

heading "Test 11: --apply bumps marker + footer, comments with the rule, exits 10"
printf '<!-- BLIND_MERGE_RISK: low -->\nbody\n\n<sub>**Blind-merge risk:** 🟢 low — tiny</sub>\n' > "$BODY_FILE"
: > "$COMMENT_LOG"
files 'db/migration/V1__x.sql\tadded\t3\t0'
run_floor --apply 7
[ "$rc" -eq 10 ] || red "expected exit 10, got $rc: $OUT $(cat "$TEST_DIR/err.log")"
[ -f "$EDITED_BODY" ] || red "PR body was not edited"
head -1 "$EDITED_BODY" | grep -qx '<!-- BLIND_MERGE_RISK: medium -->' || red "marker not bumped: $(cat "$EDITED_BODY")"
grep -q 'Blind-merge risk:\*\* 🟡 medium' "$EDITED_BODY" || red "footer not bumped: $(cat "$EDITED_BODY")"
grep -q 'SWARM_RISK_FLOOR: medium head=abc1234' "$COMMENT_LOG" || red "no marker comment: $(cat "$COMMENT_LOG")"
grep -q 'rule: migrations' "$COMMENT_LOG" || red "comment must name the rule: $(cat "$COMMENT_LOG")"
green "bump path"

heading "Test 12: --apply is idempotent on the comment (same head), still exits 10 if marker still low"
run_floor --apply 7
[ "$rc" -eq 10 ] || red "expected exit 10, got $rc"
[ "$(grep -c 'SWARM_RISK_FLOOR: medium head=abc1234' "$COMMENT_LOG")" -eq 1 ] || red "comment duplicated: $(cat "$COMMENT_LOG")"
green "one comment per head"

heading "Test 13: --apply leaves a rating at/above the floor alone"
printf '<!-- BLIND_MERGE_RISK: medium -->\nbody\n' > "$BODY_FILE"; : > "$COMMENT_LOG"
run_floor --apply 7
[ "$rc" -eq 0 ] || red "expected 0 for medium ≥ floor, got $rc"
[ ! -f "$EDITED_BODY" ] || red "body must not be edited"
[ ! -s "$COMMENT_LOG" ] || red "no comment expected"
printf '<!-- BLIND_MERGE_RISK: low -->\nbody\n' > "$BODY_FILE"
files 'src/Foo.kt\tmodified\t3\t1'
run_floor --apply 7
[ "$rc" -eq 0 ] || red "expected 0 for clean 🟢, got $rc"
[ ! -f "$EDITED_BODY" ] || red "clean 🟢 must not be edited"
green "no bump when not needed"

heading "Test 14: errors — no files listed, bad PR number, unknown flag → exit 1"
GH_FILES_TSV=""; export GH_FILES_TSV
run_floor 7; [ "$rc" -eq 1 ] || red "empty file list should fail closed, got $rc"
run_floor abc; [ "$rc" -eq 1 ] || red "non-numeric PR should fail, got $rc"
run_floor --bogus 7; [ "$rc" -eq 1 ] || red "unknown flag should fail, got $rc"
green "errors exit 1"

green "ALL TESTS PASSED"
