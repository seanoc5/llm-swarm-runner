#!/usr/bin/env bash
#
# test-shape-merge-housekeeping.sh — regression test for #368:
# swarm-merge.sh must do the housekeeping for an issue that has nothing left
# to merge, instead of hard-erroring and leaving the worker's tmux window and
# worktree behind for a manual cleanup.
#
# The reported case: `swarm-merge.sh 269` against a CLOSED issue whose work
# landed under a different PR printed "ERROR: no linked PR found for issue
# #269" and exited 1 — while window iss-269 and its worktree were both still
# alive. Steps 5-7 (reap wait, tmux/worktree kill, branch sweep) are keyed on
# the issue, not the PR, so they were valid all along.
#
# The guard being asserted alongside it is the one run_sweep already applies
# to branches: an issue that is not CLOSED is an in-flight worker, and reaping
# it would destroy uncommitted work. That case must still refuse unless
# --force-cleanup is given.
#
# Stubs `gh` and `tmux` via PATH override — no GitHub auth, no tmux server.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
[ -x "$MERGE" ] || red "not executable: $MERGE"

TEST_DIR=$(mktemp -d -t shape-merge-housekeep-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/bin"
# tmux stub: never reports a window alive, so the reap-wait loop resolves
# immediately and the test doesn't burn the 60s grace period.
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

REPO="$TEST_DIR/main/some-project"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# gh stub factory: $1 = issue state, $2 = linked PR number ("" for none),
# $3 = PR state (ignored when there is no linked PR).
write_gh() {
    local issue_state="$1" pr="$2" pr_state="${3:-MERGED}"
    cat > "$TEST_DIR/bin/gh" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
    "api repos/{owner}/{repo}/issues/"*)
        echo "false"; exit 0 ;;
    "issue view")
        case "\$*" in
            *closedByPullRequestsReferences*) echo "$pr"; exit 0 ;;
            *--json\ state*)                  echo "$issue_state"; exit 0 ;;
        esac
        exit 0 ;;
    "pr view")
        case "\$*" in
            *state,mergeable*)
                echo '{"state":"$pr_state","mergeable":"MERGEABLE","headRefName":"fix/issue-269","title":"fake","closingIssuesReferences":[]}'
                exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/bin/gh"
}

# ============================================================================
heading "Test 1: CLOSED issue, no linked PR — housekeeps instead of erroring"
# ============================================================================
write_gh CLOSED ""
OUT=$(timeout 15 "$MERGE" 269 2>&1) || red "housekeeping path exited non-zero:\n$OUT"
echo "$OUT" | grep -q "no linked PR found for issue #269" || red "expected the no-PR reason to still be reported, got:\n$OUT"
echo "$OUT" | grep -q "housekeeping only, nothing to merge" || red "expected housekeeping-only notice, got:\n$OUT"
echo "$OUT" | grep -q "\[7/7\] running local-branch sweep" || red "expected step 7 to run — housekeeping means reaching the sweep:\n$OUT"
echo "$OUT" | grep -q "Housekeeping complete for issue #269" || red "expected honest final line, got:\n$OUT"
echo "$OUT" | grep -q "merged for issue" && red "must NOT claim a merge that never happened:\n$OUT"
green "closed issue with no PR now reaches the sweep and reports honestly"

# ============================================================================
heading "Test 2: OPEN issue, no linked PR — still refuses (worker may be live)"
# ============================================================================
write_gh OPEN ""
RC=0
OUT=$(timeout 15 "$MERGE" 269 2>&1) || RC=$?
[ "$RC" -ne 0 ] || red "must NOT housekeep an OPEN issue — that is an in-flight worker:\n$OUT"
echo "$OUT" | grep -q -- "--force-cleanup" || red "error should point at the escape hatch, got:\n$OUT"
echo "$OUT" | grep -q "\[7/7\]" && red "must not reach the sweep for an OPEN issue:\n$OUT"
green "open issue still refuses, and names --force-cleanup"

# ============================================================================
heading "Test 3: OPEN issue + --force-cleanup — housekeeps anyway"
# ============================================================================
write_gh OPEN ""
OUT=$(timeout 15 "$MERGE" 269 --force-cleanup 2>&1) || red "--force-cleanup path exited non-zero:\n$OUT"
echo "$OUT" | grep -q "force-cleanup given" || red "expected the override to be announced, got:\n$OUT"
echo "$OUT" | grep -q "Housekeeping complete for issue #269" || red "expected housekeeping to complete, got:\n$OUT"
green "--force-cleanup overrides the open-issue guard"

# ============================================================================
heading "Test 4: PR CLOSED unmerged on a CLOSED issue — housekeeps, not 'Nothing to do'"
# ============================================================================
write_gh CLOSED 77 CLOSED
OUT=$(timeout 15 "$MERGE" 269 2>&1) || red "closed-PR housekeeping path exited non-zero:\n$OUT"
echo "$OUT" | grep -q "Nothing to do" && red "'Nothing to do' is wrong — the worktree and window are still on disk:\n$OUT"
echo "$OUT" | grep -q "PR #77 is CLOSED (not merged)" || red "expected the closed-PR reason, got:\n$OUT"
echo "$OUT" | grep -q "Housekeeping complete for issue #269 (PR #77 was not merged)" || red "expected final line to name the unmerged PR, got:\n$OUT"
green "closed-unmerged PR now cleans up instead of bailing"

# ============================================================================
heading "Test 5: regression — CLOSED issue with a MERGED PR still merges normally"
# ============================================================================
write_gh CLOSED 77 MERGED
OUT=$(timeout 15 "$MERGE" 269 2>&1) || red "normal merge path regressed:\n$OUT"
echo "$OUT" | grep -q "issue #269 → PR #77" || red "expected normal issue→PR resolution, got:\n$OUT"
echo "$OUT" | grep -q "already MERGED" || red "expected the MERGED branch of the state machine, got:\n$OUT"
echo "$OUT" | grep -q "merged for issue #269" || red "expected the normal final line, got:\n$OUT"
echo "$OUT" | grep -q "Housekeeping complete" && red "must not enter housekeeping mode when there is a merged PR:\n$OUT"
green "normal merge path unchanged"

printf '\n\033[32mAll housekeeping shape tests passed.\033[0m\n'
