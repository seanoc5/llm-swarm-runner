#!/usr/bin/env bash
#
# test-shape-migration-check.sh — Non-LLM shape tests for the migration
# collision gate (#294) and the out-of-order Flyway merge gate (#556):
#
#   - migration-collision-check.sh   Flyway dup-version detection, Flyway
#                                     out-of-order detection (+ its
#                                     MIGRATION_ALLOW_OUT_OF_ORDER opt-out),
#                                     Alembic multi-head detection, exit
#                                     codes, --post idempotency
#   - swarm-merge.sh                 migration gate refusal (collision and
#                                     out-of-order), --override,
#                                     MIGRATION_GATE=0 kill switch,
#                                     --auto-low refusal on out-of-order
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
export GH_PR_LIST="$TEST_DIR/pr-list.json"     # `gh pr list --json number,files` fixture
echo '[]' > "$GH_PR_LIST"
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
        if [[ "$*" == *state,mergeable* ]]; then
            # swarm-merge.sh's main PR_JSON call. body/isDraft/reviewDecision
            # default to values that clear --auto-low's gates 1/3/4/5 (low
            # marker, not a draft, no CHANGES_REQUESTED) so a test only
            # needs to override one via GH_PR_BODY/GH_PR_REVIEW_DECISION/
            # GH_PR_IS_DRAFT when it wants that specific gate to fire.
            base_head="$(jq -c --arg n "$pr_num" '.[$n]' "$GH_PR_TABLE")"
            head="$(jq -r '.headRefName' <<<"$base_head")"
            base="$(jq -r '.baseRefName' <<<"$base_head")"
            jq -n -c \
                --arg head "$head" --arg base "$base" \
                --arg body "${GH_PR_BODY:-<!-- BLIND_MERGE_RISK: low -->}" \
                --arg review "${GH_PR_REVIEW_DECISION:-}" \
                --argjson draft "${GH_PR_IS_DRAFT:-false}" \
                '{state:"OPEN", mergeable:"MERGEABLE", headRefName:$head, baseRefName:$base, title:"fake", body:$body, isDraft:$draft, reviewDecision:$review}'
        elif [[ "$*" == *baseRefName* ]]; then
            jq -c --arg n "$pr_num" '.[$n]' "$GH_PR_TABLE"
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
    "pr list")
        query=""
        args=("$@")
        for i in "${!args[@]}"; do
            [ "${args[$i]}" = "--jq" ] && query="${args[$((i+1))]}"
        done
        if [ -n "$query" ]; then jq -r "$query" "$GH_PR_LIST"; else cat "$GH_PR_LIST"; fi
        exit 0 ;;
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
heading "Test 2b: remediation recipe — PR-side file loses, next free computed, commands verbatim"
# ============================================================================
MIG=src/main/resources/db/migration
echo "$OUT" | grep -q "V107: master owns V107__master-claims-it.sql" \
    || red "recipe must name the base-side owner (never the file to move)"
echo "$OUT" | grep -q "next free version: V108" || red "expected next free V108 (max of V105,V107 + 1)"
echo "$OUT" | grep -qF "git mv $MIG/V107__worker-claims-it.sql $MIG/V108__worker-claims-it.sql" \
    || red "git mv line missing or wrong"
echo "$OUT" | grep -qF 'git commit -m "fix(migration): renumber V107 → V108, V107 taken on master"' \
    || red "commit line missing"
echo "$OUT" | grep -qF "git push origin dup-branch" || red "push line must target the PR head branch"
echo "$OUT" | grep -q "Remediation: rename the losing file" && red "generic remediation line should be replaced by the recipe"
green "recipe: loser = PR-side file, V108, git mv/commit/push verbatim"

# Another open PR already claims V108 → next free must skip to V109.
cat > "$GH_PR_LIST" <<'JSON'
[{"number": 2, "files": [{"path": "src/main/resources/db/migration/V107__worker-claims-it.sql"}]},
 {"number": 9, "files": [{"path": "src/main/resources/db/migration/V108__sibling-pr.sql"}, {"path": "README.md"}]}]
JSON
if OUT=$("$CHECK" 2 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2, got $RC"
echo "$OUT" | grep -q "next free version: V109" || red "next free must skip V108 claimed by open PR #9"
echo "$OUT" | grep -q "and 1 other open PR" || red "other-open-PR count missing"
echo "$OUT" | grep -qF "$MIG/V109__worker-claims-it.sql" || red "git mv must use V109"
green "recipe: open-PR sweep bumps next free past a sibling PR's V108"
echo '[]' > "$GH_PR_LIST"

# PR-internal duplicate (both claimants on the head) → no git mv, says so.
git checkout -q -b internal-dup master
echo "select 6;" > "$MIG/V120__one.sql"
echo "select 7;" > "$MIG/V120__two.sql"
git add -A; git_commit "worker ships two V120s"
git push -q origin internal-dup
set_pr 4 master internal-dup
if OUT=$("$CHECK" 4 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2 for PR-internal dup, got $RC"
echo "$OUT" | grep -q "V120: every claimant is PR-side (PR-internal duplicate" || red "PR-internal dup not called out"
echo "$OUT" | grep -q "git mv" && red "PR-internal dup must not emit a git mv (which file loses is the worker's call)"
green "recipe: PR-internal duplicate flagged, no git mv"

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
heading "Test 8: out-of-order Flyway merge (#556) — PR adds V3 below base max V5 → exit 3"
# ============================================================================
# Dedicated fixture repo (clean V1/V2/V5 base) rather than reusing $CLONE,
# which has accumulated unrelated collisions from earlier tests by now.
OOO_ORIGIN="$TEST_DIR/ooo-origin.git"
OOO_CLONE="$TEST_DIR/ooo-clone"
git init -q --bare -b master "$OOO_ORIGIN"
git init -q -b master "$OOO_CLONE"
git -C "$OOO_CLONE" remote add origin "$OOO_ORIGIN"
ooo_commit() { git -C "$OOO_CLONE" -c user.email=t@t -c user.name=t commit -q -m "$1"; }

mkdir -p "$OOO_CLONE/$MIG"
echo "select 1;" > "$OOO_CLONE/$MIG/V1__one.sql"
echo "select 2;" > "$OOO_CLONE/$MIG/V2__two.sql"
echo "select 5;" > "$OOO_CLONE/$MIG/V5__five.sql"
git -C "$OOO_CLONE" add -A; ooo_commit "base: V1, V2, V5"
git -C "$OOO_CLONE" push -q origin master

git -C "$OOO_CLONE" checkout -q -b ooo-branch master
echo "select 3;" > "$OOO_CLONE/$MIG/V3__three.sql"
git -C "$OOO_CLONE" add -A; ooo_commit "worker adds V3, unaware master already merged V5"
git -C "$OOO_CLONE" push -q origin ooo-branch
set_pr 20 master ooo-branch

cd "$OOO_CLONE"
if OUT=$("$CHECK" 20 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 3 ] || red "expected exit 3 for out-of-order, got $RC (output: $OUT)"
echo "$OUT" | grep -q "verdict: out-of-order" || red "verdict line missing"
echo "$OUT" | grep -qF "$MIG/V3__three.sql (V3)" || red "offending file not named"
echo "$OUT" | grep -q "base tip's max version (V5" || red "base max (V5) not reported"
echo "$OUT" | grep -q "next free version: V6" || red "expected next free V6 (max of V1,V2,V3,V5 + 1)"
echo "$OUT" | grep -qF "git mv $MIG/V3__three.sql $MIG/V6__three.sql" || red "git mv line missing or wrong"
echo "$OUT" | grep -qF "git commit -m \"fix(migration): renumber to V6, below base tip max V5 on master\"" \
    || red "commit line missing"
echo "$OUT" | grep -qF "git push origin ooo-branch" || red "push line must target the PR head branch"
green "out-of-order Flyway merge → exit 3, names V3, base max V5, suggested V6, recipe verbatim"

# ============================================================================
heading "Test 9: PR adds V6 on a base with max V5 → clean"
# ============================================================================
git -C "$OOO_CLONE" checkout -q -b clean-higher master
echo "select 6;" > "$OOO_CLONE/$MIG/V6__six.sql"
git -C "$OOO_CLONE" add -A; ooo_commit "clean: V6 above base max V5"
git -C "$OOO_CLONE" push -q origin clean-higher
set_pr 21 master clean-higher

if OUT=$("$CHECK" 21); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 for a PR above base max, got $RC"
echo "$OUT" | grep -q "verdict: clean" || red "verdict line missing"
green "PR adds V6 above base max V5 → clean"

# ============================================================================
heading "Test 10: MIGRATION_ALLOW_OUT_OF_ORDER=1 downgrades out-of-order to a warning, exit 0"
# ============================================================================
if OUT=$(MIGRATION_ALLOW_OUT_OF_ORDER=1 "$CHECK" 20 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 under MIGRATION_ALLOW_OUT_OF_ORDER=1, got $RC"
echo "$OUT" | grep -q "verdict: out-of-order" || red "verdict should still read out-of-order"
echo "$OUT" | grep -q "downgraded to a warning" || red "warning note missing"
green "MIGRATION_ALLOW_OUT_OF_ORDER=1: out-of-order warns and exits 0"
# swarm-merge.sh's own migration-collision-check.sh call fetches base/head
# from the CURRENT directory's "origin" remote — stay in $OOO_CLONE (whose
# origin is $OOO_ORIGIN, holding master/ooo-branch) rather than $CLONE
# (whose origin is the unrelated $ORIGIN fixture) for Tests 11-12.

# ============================================================================
heading "Test 11: swarm-merge migration gate — out-of-order refuses plain and --auto-low"
# ============================================================================
# Both refusal paths run BEFORE the override-proceeds test below, which
# actually merges and deletes the real remote branch (swarm-merge.sh issue
# #489: no --delete-branch on `gh pr merge`, but it does run a real `git
# push origin --delete` right after) — once that lands, ooo-branch is gone
# from $OOO_ORIGIN and a later fetch-based check would fail for the wrong
# reason.
: > "$GH_LOG"
if OUT=$("$MERGE" 20 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "swarm-merge should refuse on an out-of-order Flyway merge"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite the out-of-order verdict"
echo "$OUT" | grep -qi "out-of-order" || red "refusal message should name the out-of-order verdict"
green "out-of-order merge refuses merge, gh pr merge never called"

# Gates 0 (authorship), 1 (rating marker), 3 (review decision), 4 (base
# branch), 5 (draft) all clear on the gh stub's defaults, so --auto-low
# reaches the migration gate (which runs before the CI wait) and refuses
# there, the same gate plain swarm-merge.sh refuses at above.
: > "$GH_LOG"
if OUT=$("$MERGE" 20 --auto-low 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "swarm-merge --auto-low should refuse the out-of-order PR #20"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite the out-of-order verdict"
echo "$OUT" | grep -qi "out-of-order" || red "--auto-low refusal message should name the out-of-order verdict"
green "--auto-low refuses on out-of-order Flyway merge, gh pr merge never called"

# ============================================================================
heading "Test 12: swarm-merge migration gate — --override-migration-gate proceeds despite out-of-order"
# ============================================================================
: > "$GH_LOG"
if "$MERGE" 20 --override-migration-gate >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "override-migration-gate merge failed on out-of-order PR (rc=$RC)"
grep -q "pr merge 20" "$GH_LOG" || red "gh pr merge not called under --override-migration-gate"
green "--override-migration-gate proceeds to merge despite out-of-order"
cd "$CLONE"

# ============================================================================
heading "All migration-collision-check shape tests passed"
green "Flyway dup detection + remediation recipe (loser/next-free/open-PR sweep/internal dup), dotted-version distinctness, out-of-order merge detection + MIGRATION_ALLOW_OUT_OF_ORDER opt-out (#556), Alembic multi-head, exit 4 skip, --post idempotency, swarm-merge gate + override + kill switch + --auto-low refusal"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
