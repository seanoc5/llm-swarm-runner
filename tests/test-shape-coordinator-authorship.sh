#!/usr/bin/env bash
#
# test-shape-coordinator-authorship.sh — Non-LLM shape tests for the
# coordinator auto-merge safety gates added in #452 (carved from #450
# finding 4: corpusminder-spring PR #713 was coordinator-authored and
# coordinator-merged 10 seconds after its CI run *started*, with no
# authorship check and no real CI wait):
#
#   - check-coordinator-authorship.sh   Gate 0: refuses a PR whose head
#                                        carries a `Swarm-Role: coordinator`
#                                        commit trailer; clean PR passes;
#                                        fail-closed on gh/git error.
#   - swarm-merge.sh --auto-low         wires Gate 0 and a real CI wait
#                                        (Gate 2, via ci-wait.sh) ahead of
#                                        the merge; a plain `swarm-merge.sh
#                                        <N>` (no --auto-low) is unaffected
#                                        — this only guards the unattended
#                                        SWARM_AUTOMERGE_LOW path.
#
# Uses a REAL git fixture repo (bare "origin" + a clone) for the trailer
# scan, same reasoning as test-shape-migration-check.sh: a commit trailer
# only exists in real git commit objects, not something worth faking.
# `gh` is stubbed via PATH override, combining the pr-table shape from
# test-shape-migration-check.sh with the mergeable/checks shape from
# test-shape-ci-wait.sh, since swarm-merge.sh --auto-low exercises both
# scripts' `gh pr view` call shapes in one run.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH="$SCRIPT_DIR/../scripts/check-coordinator-authorship.sh"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
for s in "$AUTH" "$MERGE"; do
    [ -x "$s" ] || red "not executable: $s"
done

TEST_DIR=$(mktemp -d -t shape-coordinator-authorship-XXXXXX)
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

git -C "$CLONE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$CLONE" push -q origin master

# PR 501 / issue 501: an ordinary worker branch, no coordinator commit.
git -C "$CLONE" checkout -q -b fix/issue-501 master
git -C "$CLONE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "worker fix"
git -C "$CLONE" push -q origin fix/issue-501

# PR 502 / issue 502: carries a coordinator-authored trailer commit, like
# the migration-renumber path in prompts/coordinator.md.
git -C "$CLONE" checkout -q -b fix/issue-502 master
git -C "$CLONE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "worker fix"
git -C "$CLONE" -c user.email=t@t -c user.name=t commit -q --allow-empty \
    --trailer "Swarm-Role: coordinator" -m "fix(migration): mechanical renumber"
git -C "$CLONE" push -q origin fix/issue-502

# PR 503 / issue 503: the SAME trailer given twice on one commit — a
# regression fixture for a self-review finding on this PR: `%(trailers:
# key=...,valueonly)` emits one line per occurrence, so a naive
# `[ "$val" = "coordinator" ]` string-equality check would miss this commit
# (the captured value is "coordinator\ncoordinator", not "coordinator").
git -C "$CLONE" checkout -q -b fix/issue-503 master
git -C "$CLONE" -c user.email=t@t -c user.name=t commit -q --allow-empty \
    --trailer "Swarm-Role: coordinator" --trailer "Swarm-Role: coordinator" \
    -m "fix(migration): duplicate-trailer edge case"
git -C "$CLONE" push -q origin fix/issue-503

# ─────────────────────────── gh stub ────────────────────────────────────────

export GH_PR_TABLE="$TEST_DIR/pr-table.json"   # {"<N>": {"baseRefName":..,"headRefName":..}}
export GH_COMMENTS_DIR="$TEST_DIR/comments"    # $GH_COMMENTS_DIR/<N>.json
export GH_LOG="$TEST_DIR/gh.log"
export GH_PR_LIST="$TEST_DIR/pr-list.json"
echo '[]' > "$GH_PR_LIST"
mkdir -p "$GH_COMMENTS_DIR"
cat > "$GH_PR_TABLE" <<'JSON'
{"501": {"baseRefName": "master", "headRefName": "fix/issue-501"},
 "502": {"baseRefName": "master", "headRefName": "fix/issue-502"},
 "503": {"baseRefName": "master", "headRefName": "fix/issue-503"}}
JSON

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
        if [[ "$*" == *"mergeable,mergeStateStatus,headRefOid"* ]]; then
            # ci-wait.sh's call shape.
            echo "{\"mergeable\":\"${GH_MERGEABLE:-MERGEABLE}\",\"mergeStateStatus\":\"${GH_MERGE_STATE:-CLEAN}\",\"headRefOid\":\"deadbeef\"}"
        elif [[ "$*" == *baseRefName* ]]; then
            jq -c --arg n "$pr_num" '.[$n]' "$GH_PR_TABLE"
        elif [[ "$*" == *state,mergeable* ]]; then
            base_head="$(jq -c --arg n "$pr_num" '.[$n]' "$GH_PR_TABLE")"
            head="$(jq -r '.headRefName' <<<"$base_head")"
            echo "{\"state\":\"OPEN\",\"mergeable\":\"MERGEABLE\",\"headRefName\":\"$head\",\"title\":\"fake\"}"
        elif [[ "$*" == *comments* ]]; then
            cat "$comments_file"
        fi
        exit 0 ;;
    "pr checks")
        exit "${GH_CHECKS_RC:-0}" ;;
    "pr merge") exit 0 ;;
    "pr list")
        cat "$GH_PR_LIST"; exit 0 ;;
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

cd "$CLONE"

# ============================================================================
heading "Test 1: check-coordinator-authorship.sh — clean PR → exit 0"
# ============================================================================
if OUT=$("$AUTH" 501 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 for clean PR, got $RC (output: $OUT)"
echo "$OUT" | grep -q "clean" || red "clean verdict line missing"
green "clean PR (no coordinator trailer) → exit 0"

# ============================================================================
heading "Test 2: check-coordinator-authorship.sh — coordinator-trailer PR → exit 1"
# ============================================================================
if OUT=$("$AUTH" 502 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "expected exit 1 for coordinator-authored PR, got $RC (output: $OUT)"
echo "$OUT" | grep -q "REFUSED (Gate 0" || red "refusal must name Gate 0"
echo "$OUT" | grep -q "mechanical renumber" || red "refusal must cite the offending commit"
green "coordinator-trailer PR → exit 1, names Gate 0 and the commit"

# ============================================================================
heading "Test 2b: check-coordinator-authorship.sh — trailer repeated on one commit → still refused"
# ============================================================================
if OUT=$("$AUTH" 503 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "expected exit 1 for duplicate-trailer commit, got $RC (output: $OUT)"
echo "$OUT" | grep -q "REFUSED (Gate 0" || red "refusal must name Gate 0"
green "duplicate-trailer-on-one-commit edge case still refused (exit 1, not missed by string equality)"

# ============================================================================
heading "Test 3: check-coordinator-authorship.sh — unresolvable PR → exit 2 (fail closed)"
# ============================================================================
if OUT=$("$AUTH" 9999 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2 for unresolvable PR, got $RC (output: $OUT)"
green "unresolvable PR → exit 2, fail closed"

# ============================================================================
heading "Test 4: check-coordinator-authorship.sh — no args → usage error, exit 2"
# ============================================================================
if OUT=$("$AUTH" 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2 with no args, got $RC"
green "no PR# argument → exit 2"

# ============================================================================
heading "Test 5: swarm-merge.sh --auto-low refuses a coordinator-authored PR (Gate 0)"
# ============================================================================
: > "$GH_LOG"
if OUT=$("$MERGE" 502 --auto-low 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "swarm-merge --auto-low should refuse PR #502"
echo "$OUT" | grep -qi "gate 0" || red "refusal must name Gate 0"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite Gate 0 refusal"
green "--auto-low refuses coordinator-authored PR, gh pr merge never called"

# ============================================================================
heading "Test 6: swarm-merge.sh <N> (no --auto-low) merges the same PR anyway"
# ============================================================================
# Confirms scope: Gate 0 only guards the unattended --auto-low path. A
# human-invoked plain merge of a coordinator-authored PR (e.g. the
# migration-renumber fix) is unaffected.
: > "$GH_LOG"
if OUT=$("$MERGE" 502 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "plain swarm-merge.sh should still merge PR #502 (rc=$RC, output: $OUT)"
grep -q "pr merge 502" "$GH_LOG" || red "gh pr merge 502 was not called"
green "plain swarm-merge.sh (no --auto-low) is unaffected by Gate 0"

# ============================================================================
heading "Test 7: swarm-merge.sh --auto-low refuses on failing CI (Gate 2), no merge"
# ============================================================================
: > "$GH_LOG"
if OUT=$(GH_CHECKS_RC=1 "$MERGE" 501 --auto-low 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "swarm-merge --auto-low should refuse on failing checks"
echo "$OUT" | grep -qi "gate 2" || red "refusal must name Gate 2"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite failing CI"
green "--auto-low refuses on failing CI (Gate 2), gh pr merge never called"

# ============================================================================
heading "Test 8: swarm-merge.sh --auto-low refuses while CI is still pending (real wait, not a snapshot)"
# ============================================================================
: > "$GH_LOG"
if OUT=$(GH_CHECKS_RC=8 CI_WAIT_TIMEOUT_SECONDS=2 CI_WAIT_POLL_SECONDS=1 \
        "$MERGE" 501 --auto-low 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "swarm-merge --auto-low should refuse while checks are still pending past the deadline"
echo "$OUT" | grep -qi "gate 2" || red "refusal must name Gate 2"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called while CI was still pending"
green "--auto-low never merges on a pending/timed-out CI wait"

# ============================================================================
heading "Test 9: swarm-merge.sh --auto-low proceeds once authorship is clean and CI is green"
# ============================================================================
: > "$GH_LOG"
if OUT=$(GH_CHECKS_RC=0 "$MERGE" 501 --auto-low 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "swarm-merge --auto-low should succeed once both gates pass (rc=$RC, output: $OUT)"
echo "$OUT" | grep -qi "gate 0" || red "Gate 0 should still be reported as checked"
echo "$OUT" | grep -qi "gate 2" || red "Gate 2 should still be reported as checked"
grep -q "pr merge 501" "$GH_LOG" || red "gh pr merge 501 was not called"
green "--auto-low merges once authorship is clean and CI is verified green"

# ============================================================================
heading "Test 10: swarm-merge.sh --auto-low distinguishes a Gate 0 error (exit 2) from a refusal (exit 1)"
# ============================================================================
# A self-review finding on this PR: the refusal message used to say "carries
# a coordinator-authored commit" even when check-coordinator-authorship.sh
# had actually errored (exit 2, e.g. an unresolvable PR) rather than found a
# trailer (exit 1) — misleading for whoever reads the log. PR 999 is absent
# from GH_PR_TABLE, so check-coordinator-authorship.sh can't resolve a base
# ref and fails closed with exit 2.
: > "$GH_LOG"
if OUT=$("$MERGE" 999 --auto-low 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "swarm-merge --auto-low should refuse on a Gate 0 error"
echo "$OUT" | grep -qi "gate 0.*exit 2" || red "must name Gate 0 and the exit 2 error, not a false refusal"
echo "$OUT" | grep -q "carries a coordinator-authored commit" && red "must not claim a trailer was found when Gate 0 actually errored"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite a Gate 0 error"
green "Gate 0 error (exit 2) reported distinctly from a Gate 0 refusal (exit 1)"

# ============================================================================
heading "All coordinator-authorship shape tests passed"
green "Gate 0 (authorship) refusal/pass/fail-closed, Gate 2 (real CI wait) refusal/pass, --auto-low scoping vs plain merge"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
