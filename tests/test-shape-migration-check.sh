#!/usr/bin/env bash
#
# test-shape-migration-check.sh — Non-LLM shape tests for the migration
# collision gate (#294):
#
#   - migration-collision-check.sh   Flyway dup-version detection, Alembic
#                                     multi-head detection, exit codes,
#                                     --post idempotency
#   - swarm-merge.sh                 migration gate refusal, --override,
#                                     MIGRATION_GATE=0 kill switch
#
# Uses REAL git fixture repos (bare "origin" + a clone) so ref fetching and
# tree listing exercise real git, not a stub — the collision only exists in
# the union of two branches, which is exactly what real git plumbing gives
# us for free. `gh` is stubbed via PATH override; `--jq` queries are
# genuinely evaluated against a JSON fixture with real `jq`, since the
# migration gate's --post idempotency depends on gh's server-side --jq
# filtering behaving faithfully (a naive stub that just `cat`s raw JSON
# would look non-idempotent when it's actually fine).
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/migration-collision-check.sh"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
for s in "$CHECK" "$MERGE"; do
    [ -x "$s" ] || red "not executable: $s"
done

TEST_DIR=$(mktemp -d -t shape-migration-check-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────── real git fixture repo ─────────────────────────────

ORIGIN="$TEST_DIR/origin.git"
CLONE="$TEST_DIR/clone"
git init -q --bare -b master "$ORIGIN"
git init -q -b master "$CLONE"
git -C "$CLONE" remote add origin "$ORIGIN"

git_commit() { git -C "$CLONE" -c user.email=t@t -c user.name=t commit -q -m "$1"; }

mkdir -p "$CLONE/src/main/resources/db/migration"
echo "select 1;" > "$CLONE/src/main/resources/db/migration/V105__init.sql"
git -C "$CLONE" add -A
git_commit "init"
git -C "$CLONE" push -q origin master

# ─────────────────────────── gh stub (PR #N → branches) ────────────────────

export GH_PR_TABLE="$TEST_DIR/pr-table.json"   # {"<N>": {"base":..,"head":..}}
export GH_COMMENTS_DIR="$TEST_DIR/comments"    # $GH_COMMENTS_DIR/<N>.json
export GH_LOG="$TEST_DIR/gh.log"
mkdir -p "$GH_COMMENTS_DIR"
echo '{}' > "$GH_PR_TABLE"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
pr_num=""
for a in "$@"; do [[ "$a" =~ ^[0-9]+$ ]] && pr_num="$a" && break; done
comments_file="$GH_COMMENTS_DIR/$pr_num.json"
[ -f "$comments_file" ] || echo '{"comments":[]}' > "$comments_file"

case "$1 $2" in
    "api repos/{owner}/{repo}/issues/"*) echo "false"; exit 0 ;;
    "pr view")
        if [[ "$*" == *baseRefName* ]]; then
            jq -c --arg n "$pr_num" '.[$n]' "$GH_PR_TABLE"
        elif [[ "$*" == *state,mergeable* ]]; then
            base_head="$(jq -c --arg n "$pr_num" '.[$n]' "$GH_PR_TABLE")"
            head="$(jq -r '.headRefName' <<<"$base_head")"
            echo "{\"state\":\"OPEN\",\"mergeable\":\"MERGEABLE\",\"headRefName\":\"$head\",\"title\":\"fake\"}"
        elif [[ "$*" == *comments* ]]; then
            query=""
            args=("$@")
            for i in "${!args[@]}"; do
                [ "${args[$i]}" = "--jq" ] && query="${args[$((i+1))]}"
            done
            if [ -n "$query" ]; then
                jq -r "$query" "$comments_file"
            else
                cat "$comments_file"
            fi
        fi
        exit 0 ;;
    "pr comment")
        body="${*: -1}"
        jq --arg b "$body" '.comments += [{"body": $b}]' "$comments_file" > "$comments_file.tmp"
        mv "$comments_file.tmp" "$comments_file"
        exit 0 ;;
    "pr merge") exit 0 ;;
    "issue view")
        case "$*" in
            *closedByPullRequestsReferences*) echo "$pr_num"; exit 0 ;;
            *state*) echo "OPEN"; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

set_pr() {
    # set_pr <N> <base> <head>
    jq --arg n "$1" --arg b "$2" --arg h "$3" '.[$n] = {"baseRefName": $b, "headRefName": $h}' \
        "$GH_PR_TABLE" > "$GH_PR_TABLE.tmp"
    mv "$GH_PR_TABLE.tmp" "$GH_PR_TABLE"
}

cd "$CLONE"

# ============================================================================
heading "Test 1: clean fixture → exit 0"
# ============================================================================
git checkout -q master
git checkout -q -b clean-branch
echo "select 2;" > src/main/resources/db/migration/V106__a.sql
git add -A; git_commit "clean: V106"
git push -q origin clean-branch
set_pr 1 master clean-branch

if OUT=$("$CHECK" 1); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 for clean, got $RC"
echo "$OUT" | grep -q "verdict: clean" || red "verdict line missing"
green "clean fixture → exit 0"

# ============================================================================
heading "Test 2: duplicate Flyway version (PR vs base) → exit 2"
# ============================================================================
git checkout -q master
echo "select 3;" > src/main/resources/db/migration/V107__master-claims-it.sql
git add -A; git_commit "master claims V107 first"
git push -q origin master

git checkout -q -b dup-branch master^   # branch from BEFORE master's V107 commit
echo "select 4;" > src/main/resources/db/migration/V107__worker-claims-it.sql
git add -A; git_commit "worker also claims V107, unaware of master's"
git push -q origin dup-branch
set_pr 2 master dup-branch

if OUT=$("$CHECK" 2 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2 for Flyway dup, got $RC"
echo "$OUT" | grep -q "V107 claimed by" || red "collision detail missing"
green "duplicate Flyway version → exit 2"

# ============================================================================
heading "Test 3: dotted version is distinct (V107 vs V107.1) → no collision"
# ============================================================================
git checkout -q master
git checkout -q -b dotted-branch
echo "select 5;" > src/main/resources/db/migration/V107.1__patch.sql
git add -A; git_commit "V107.1 patch, distinct from V107"
git push -q origin dotted-branch
set_pr 3 master dotted-branch

if OUT=$("$CHECK" 3); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 for dotted-distinct, got $RC"
green "V107 vs V107.1 not treated as a collision"

# ============================================================================
heading "Test 4: Alembic multi-head DAG → exit 2"
# ============================================================================
git checkout -q master
git checkout -q -b alembic-branch
mkdir -p alembic/versions
# versions/__init__.py has no revision= line at all — a real Alembic
# project convention, and a regression fixture for a self-review finding
# (PR #299): grep|head under pipefail still propagates grep's exit 1 on
# no match even though head succeeds, which killed the whole script via
# set -e before this file was ever skipped as expected.
: > alembic/versions/__init__.py
cat > alembic/versions/aaa.py <<'PYEOF'
revision = 'aaa111'
down_revision = None
PYEOF
cat > alembic/versions/bbb.py <<'PYEOF'
revision = 'bbb222'
down_revision = 'aaa111'
PYEOF
cat > alembic/versions/ccc.py <<'PYEOF'
revision = 'ccc333'
down_revision = 'aaa111'
PYEOF
git add -A; git_commit "two siblings branch from aaa111: two heads, plus a revision-less __init__.py"
git push -q origin alembic-branch
set_pr 4 master alembic-branch

if OUT=$("$CHECK" 4 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2 for Alembic multi-head, got $RC (output: $OUT)"
echo "$OUT" | grep -q "multi-head DAG (2 heads)" || red "multi-head detail missing"
green "Alembic multi-head DAG → exit 2 (revision-less __init__.py doesn't crash the script)"

# Merge revision joins the heads → back to clean
git checkout -q alembic-branch
cat > alembic/versions/merge.py <<'PYEOF'
revision = 'merge444'
down_revision = ('bbb222', 'ccc333')
PYEOF
git add -A; git_commit "merge revision joins the two heads"
git push -q origin alembic-branch

if OUT=$("$CHECK" 4); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 after alembic merge revision, got $RC"
green "alembic merge revision resolves the multi-head"

# ============================================================================
heading "Test 5: no migration files in the union → exit 4"
# ============================================================================
git checkout -q master
git checkout -q -b no-migrations-branch
echo "docs only" > NOTES.md
git add -A; git_commit "no migration touch"
git push -q origin no-migrations-branch

BARE_ORIGIN="$TEST_DIR/bare-origin.git"
BARE_CLONE="$TEST_DIR/bare-clone"
git init -q --bare -b master "$BARE_ORIGIN"
git init -q -b master "$BARE_CLONE"
git -C "$BARE_CLONE" remote add origin "$BARE_ORIGIN"
echo "hi" > "$BARE_CLONE/README.md"
git -C "$BARE_CLONE" add -A
git -C "$BARE_CLONE" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$BARE_CLONE" push -q origin master
git -C "$BARE_CLONE" checkout -q -b no-mig
echo "more" >> "$BARE_CLONE/README.md"
git -C "$BARE_CLONE" add -A
git -C "$BARE_CLONE" -c user.email=t@t -c user.name=t commit -q -m "still no migrations"
git -C "$BARE_CLONE" push -q origin no-mig
set_pr 5 master no-mig

cd "$BARE_CLONE"
if OUT=$("$CHECK" 5 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 4 ] || red "expected exit 4 for no-migrations, got $RC"
echo "$OUT" | grep -q "skipped" || red "skip message missing"
green "no migration files in union → exit 4"
cd "$CLONE"

# ============================================================================
heading "Test 6: --post idempotency — unchanged verdict skips, changed verdict re-posts"
# ============================================================================
: > "$GH_LOG"
"$CHECK" 2 --post >/dev/null 2>&1 || true
grep -q "pr comment" "$GH_LOG" || red "expected first --post to comment"
green "--post posts the verdict comment"

: > "$GH_LOG"
"$CHECK" 2 --post >/dev/null 2>&1 || true
grep -q "pr comment" "$GH_LOG" && red "unchanged verdict re-posted a comment"
green "unchanged verdict on re-run: --post stays silent"

# ============================================================================
heading "Test 7: swarm-merge migration gate — refuses, --override-migration-gate proceeds"
# ============================================================================
# issue #2 → PR #2 (the Flyway dup-version PR from Test 2; pr_num extraction
# in the gh stub picks the first numeric arg, so issue# == PR# here)
: > "$GH_LOG"
if "$MERGE" 2 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "swarm-merge should refuse on migration collision"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite migration collision"
green "migration collision refuses merge, gh pr merge never called"

: > "$GH_LOG"
if "$MERGE" 2 --override-migration-gate >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "override-migration-gate merge failed (rc=$RC)"
grep -q "pr merge 2" "$GH_LOG" || red "gh pr merge not called under --override-migration-gate"
green "--override-migration-gate proceeds to merge"

: > "$GH_LOG"
if MIGRATION_GATE=0 "$MERGE" 2 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "MIGRATION_GATE=0 should skip the gate and merge (rc=$RC)"
grep -q "pr merge 2" "$GH_LOG" || red "gh pr merge not called with MIGRATION_GATE=0"
green "MIGRATION_GATE=0 kill switch skips the gate"

# ============================================================================
heading "All migration-collision-check shape tests passed"
green "Flyway dup detection, dotted-version distinctness, Alembic multi-head, exit 4 skip, --post idempotency, swarm-merge gate + override + kill switch"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
