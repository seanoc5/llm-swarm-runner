#!/usr/bin/env bash
#
# test-shape-pr-screen-lint.sh — Shape tests for lint-pr-screen.sh (the PR
# screen altitude gate). Pure text-in/findings-out — no gh stub needed, the
# --file path is exercised.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/../scripts/lint-pr-screen.sh"
[ -x "$LINT" ] || red "lint-pr-screen.sh not executable: $LINT"

TEST_DIR=$(mktemp -d -t shape-pr-screen-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

run() { set +e; OUT=$("$LINT" --file "$1" 2>&1); RC=$?; set -e; }

heading "Test 1: manager-altitude screen → clean, exit 0"
cat > "$TEST_DIR/good.md" <<'EOF'
<!-- BLIND_MERGE_RISK: low -->
**Bottom line:** Adds an always-on regression test proving the full pipeline — document upload, real sentence-splitting, concept matching — works end to end against a real database. Nothing in the repo did that before. Test-only, no production code, 7/7 green, runs nightly not per-PR. Closes #618
**Your move:** Merge decision. Recommended: merge — 🟢 test-only.
**What surprised me:** The built-in country list cannot serve as a fixture for concept matching — matching silently does nothing and the test would have passed anyway. Documented; a trap for future tests, not a bug.

#### Decide: file a follow-up for the never-wired matcher?
| Option | Pro | Con |
|---|---|---|
| A: File now | closes a silent gap | more scope than asked |
| B: Leave it | keeps this PR minimal | gap recurs untracked |

✅ Recommend A — cheap to file, findings already written up. Default if silent: B.

<details><summary>Appendix</summary>

## What changed
- `src/test/kotlin/Foo.kt` — backticks are fine down here: `POST /api/corpus`.

</details>

---

<sub>_Swarm metadata._ **Blind-merge risk:** 🟢 low — test-only.</sub>
EOF
run "$TEST_DIR/good.md"
[ "$RC" -eq 0 ] || { echo "$OUT"; red "expected exit 0, got $RC"; }
echo "$OUT" | grep -q clean || { echo "$OUT"; red "expected clean verdict"; }
green "manager-altitude screen passes; appendix backticks ignored"

heading "Test 2: worker-altitude screen → identifiers + budgets + ✅-in-table, exit 3"
{
cat <<'EOF'
<!-- BLIND_MERGE_RISK: medium -->
**Bottom line:** `CorpusNlpHitsChainService.runConceptHitMatching` silently skipped matching for any hierarchy whose concepts carry no materialized `address`, so job 46's backfill reported COMPLETED with 0 `concept_hits`. Fixed by scoping via `hierarchy_id` directly instead of the address prefix, plus added observability so a green-but-empty run is never silently indistinguishable from a real one again, and a regression test covering the empty case, verified green locally against a fresh throwaway Testcontainers Postgres with real CoreNLP and confirmed excluded from the fast lane by tag. Closes #640
**Your move:** Merge decision only; default: stays open, no auto-merge, until you say go. Once merged, re-running the backfill against the dev DB is a good way to confirm end-to-end — that re-run is the operator's call per the issue's out-of-scope note, not done here.
EOF
printf '**What surprised me:** '
for i in $(seq 1 60); do printf 'word%d ' "$i"; done
printf '\n\n'
cat <<'EOF'
#### Decide: follow-up issue?
| Option | Pro | Con | |
|---|---|---|---|
| A: File now | closes gap | more scope | |
| B: Leave it | minimal PR | recurs | ✅ recommended: A — cheap to file |

<details><summary>Appendix</summary>
body
</details>
EOF
} > "$TEST_DIR/bad.md"
run "$TEST_DIR/bad.md"
[ "$RC" -eq 3 ] || { echo "$OUT"; red "expected exit 3, got $RC"; }
for rule in identifiers-above-fold bottom-line-budget your-move-budget surprise-budget recommendation-in-table; do
    echo "$OUT" | grep -q "FAIL $rule" || { echo "$OUT"; red "expected FAIL $rule"; }
done
green "all five rules fire on the worker-altitude screen"

heading "Test 3: no <details> appendix — screen ends at the <sub> footer"
cat > "$TEST_DIR/nofold.md" <<'EOF'
<!-- BLIND_MERGE_RISK: low -->
**Bottom line:** Typo fix in the README. Closes #7

---

<sub>_Swarm metadata._ **Blind-merge risk:** 🟢 low — `README.md` only.</sub>
EOF
run "$TEST_DIR/nofold.md"
[ "$RC" -eq 0 ] || { echo "$OUT"; red "expected exit 0 (footer backtick must not count), got $RC"; }
green "no-ceremony body with backtick only in footer passes"

heading "Test 4: stdin mode"
set +e; OUT=$(printf '**Bottom line:** fine. Closes #1\n' | "$LINT" - 2>&1); RC=$?; set -e
[ "$RC" -eq 0 ] || { echo "$OUT"; red "stdin mode: expected exit 0, got $RC"; }
green "stdin mode works"

heading "Test 5: env budgets are honoured"
set +e; OUT=$(PR_SCREEN_BOTTOM_MAX=3 "$LINT" --file "$TEST_DIR/nofold.md" 2>&1); RC=$?; set -e
[ "$RC" -eq 3 ] || { echo "$OUT"; red "expected exit 3 with PR_SCREEN_BOTTOM_MAX=3, got $RC"; }
echo "$OUT" | grep -q "FAIL bottom-line-budget" || { echo "$OUT"; red "expected bottom-line-budget"; }
green "PR_SCREEN_BOTTOM_MAX override respected"

echo
green "all lint-pr-screen shape tests passed"
