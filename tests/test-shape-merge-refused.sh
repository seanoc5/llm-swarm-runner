#!/usr/bin/env bash
#
# test-shape-merge-refused.sh — regression test for #492:
# swarm-merge.sh must not report "Done. PR #N merged" and run cleanup when
# `gh pr merge` refuses the merge. The real incident (fand-etl,
# 2026-09-27): five PRs merged in sequence each printed a "Done. ... merged"
# line and exited 0, but three of them were left OPEN with
# mergeStateStatus DIRTY — the script tolerated every `gh pr merge` failure
# unconditionally instead of checking whether the PR was actually merged.
#
# The fix re-queries `gh pr view` after a failed `gh pr merge` and only
# tolerates the failure when the PR is actually MERGED (the case
# --delete-branch's now-removed local-delete step used to produce — see
# issue #489). PR #499's own review (caveat 1) found the re-query's error
# message always said "nothing merged" / "rebase and retry" even when the
# re-query itself failed (state unknown) or the refusal wasn't a conflict at
# all (auth, network, branch protection) — a rebase hint is actively wrong
# advice in those cases. This file now covers all of:
#
#   Test 0: mergeStateStatus already DIRTY on the *initial* fetch → refuse
#           before ever calling `gh pr merge`.
#   Test 1: gh pr merge fails, re-query confirms state=OPEN with a REAL
#           conflict (mergeable=CONFLICTING, mergeStateStatus=DIRTY) →
#           refuse, rebase hint given, no cleanup.
#   Test 2: gh pr merge fails, re-query confirms state=MERGED (the harmless
#           local-delete-style case) → tolerate, proceed, exit 0.
#   Test 3: gh pr merge fails, re-query confirms state=OPEN but nothing
#           indicates a conflict (mergeable=MERGEABLE, mergeStateStatus=
#           BLOCKED) → refuse, but must NOT suggest a rebase (the refusal
#           is more likely auth/network/branch-protection) and must name
#           the confirmed state.
#   Test 4: the re-query itself fails (`gh pr view` exits non-zero) →
#           fail closed, state reported as UNKNOWN (not OPEN), no rebase
#           hint, no cleanup.
#   Test 5: the re-query "succeeds" but returns empty output → same
#           fail-closed/UNKNOWN handling as Test 4.
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

TEST_DIR=$(mktemp -d -t shape-merge-refused-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/bin"
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

export MIGRATION_GATE=0   # not what this test exercises; keep it out of the way
export GH_LOG="$TEST_DIR/gh.log"
: > "$GH_LOG"

# POST_STATE_FILE controls what the post-merge re-query reports; each test
# below overwrites it before invoking swarm-merge.sh. Distinguishing the
# initial PR_JSON fetch from the post-merge re-query in the stub is done on
# `headRefName`, which only the initial fetch requests — the re-query's
# field list (state,mergeable,mergeStateStatus) is a substring-ambiguous
# prefix match against the initial fetch's longer field list otherwise.
export POST_STATE_FILE="$TEST_DIR/post-state.json"

# The normal stub: initial PR_JSON fetch reports a clean, mergeable OPEN PR;
# `gh pr merge` always refuses (that's what Tests 1-5 exercise); the
# post-merge re-query (issue #492) reads $POST_STATE_FILE, set per test.
write_normal_gh_stub() {
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/"*) echo "true"; exit 0 ;;
    "pr merge") exit 1 ;;   # always refuses — that's what this test exercises
    "pr view")
        case "$*" in
            *comments*)      echo '{"comments":[]}'; exit 0 ;;
            *headRefName*)   echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"fix/issue-77","title":"fake"}'; exit 0 ;;
            # swarm-merge.sh's post-merge re-query (issue #492).
            *mergeStateStatus*) cat "$POST_STATE_FILE"; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"
}
write_normal_gh_stub

# ============================================================================
heading "Test 0: mergeStateStatus already DIRTY on the initial fetch → refuse before ever calling gh pr merge"
# ============================================================================
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/"*) echo "true"; exit 0 ;;
    "pr merge") exit 1 ;;
    "pr view")
        case "$*" in
            *comments*)      echo '{"comments":[]}'; exit 0 ;;
            *headRefName*)   echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"DIRTY","headRefName":"fix/issue-77","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

set +e
OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1)
RC=$?
set -e

[ "$RC" -ne 0 ] || red "expected non-zero exit when mergeStateStatus is already DIRTY, got 0:\n$OUT"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge must never be called once the pre-merge DIRTY gate refuses:\n$(cat "$GH_LOG")"
echo "$OUT" | grep -qi "DIRTY" || red "expected the refusal to name mergeStateStatus=DIRTY, got:\n$OUT"
green "mergeStateStatus=DIRTY on the initial fetch refuses before gh pr merge is ever called"
: > "$GH_LOG"
write_normal_gh_stub

# ============================================================================
heading "Test 1: gh pr merge fails, re-query confirms OPEN with a real conflict → refuse, rebase hint, no cleanup"
# ============================================================================
echo '{"state":"OPEN","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$POST_STATE_FILE"

set +e
OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1)
RC=$?
set -e

[ "$RC" -ne 0 ] || red "expected non-zero exit when the PR is still OPEN after a refused merge, got 0:\n$OUT"
echo "$OUT" | grep -q "Done\." && red "must not print a 'Done.' line when the merge was refused:\n$OUT"
echo "$OUT" | grep -qE '\[5/7\]|\[6/7\]|\[7/7\]' && red "must not reach steps 5-7 (reap wait / kill / sweep) after a refused merge:\n$OUT"
echo "$OUT" | grep -q "state=OPEN" || red "expected the message to name the confirmed state, got:\n$OUT"
echo "$OUT" | grep -qi "rebase" || red "expected a rebase-and-retry hint for a real conflict, got:\n$OUT"
green "refused merge with a confirmed real conflict exits non-zero, suggests rebase, no cleanup"

# ============================================================================
heading "Test 2: gh pr merge fails, re-query shows MERGED → tolerate, proceed, exit 0"
# ============================================================================
echo '{"state":"MERGED","mergeable":"MERGED","mergeStateStatus":"MERGED"}' > "$POST_STATE_FILE"

OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1) || red "expected exit 0 once the re-query confirms MERGED:\n$OUT"
echo "$OUT" | grep -q "Done\." || red "expected a 'Done.' completion line once MERGED is confirmed, got:\n$OUT"
grep -q "pr merge 77" "$GH_LOG" || red "gh pr merge 77 was not called"
green "refused-but-actually-MERGED case tolerates the failure and completes"

# ============================================================================
heading "Test 3: gh pr merge fails, re-query confirms OPEN but nothing indicates a conflict → refuse, NO rebase hint"
# ============================================================================
# mergeable=MERGEABLE / mergeStateStatus=BLOCKED is the branch-protection-style
# shape: GitHub says the PR could merge cleanly but something else (required
# review, required status check, etc.) is blocking it. A rebase would not fix
# that, so the message must not tell the operator to rebase.
echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}' > "$POST_STATE_FILE"

set +e
OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1)
RC=$?
set -e

[ "$RC" -ne 0 ] || red "expected non-zero exit for a non-conflict refusal, got 0:\n$OUT"
echo "$OUT" | grep -q "Done\." && red "must not print a 'Done.' line:\n$OUT"
echo "$OUT" | grep -q "state=OPEN" || red "expected the message to name the confirmed state, got:\n$OUT"
echo "$OUT" | grep -qi "rebase onto the default branch and retry\." && red "must NOT suggest a rebase when nothing indicates a conflict:\n$OUT"
echo "$OUT" | grep -qiE "auth|network|branch protection" || red "expected the message to name a non-conflict cause (auth/network/branch protection), got:\n$OUT"
green "refused merge confirmed OPEN with no conflict evidence exits non-zero without a rebase hint"

# ============================================================================
heading "Test 4: the post-refusal re-query itself fails (gh pr view exits non-zero) → fail closed, state=UNKNOWN, no rebase hint"
# ============================================================================
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/"*) echo "true"; exit 0 ;;
    "pr merge") exit 1 ;;
    "pr view")
        case "$*" in
            *comments*)      echo '{"comments":[]}'; exit 0 ;;
            *headRefName*)   echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"fix/issue-77","title":"fake"}'; exit 0 ;;
            # The post-merge re-query itself fails outright — simulates a
            # transient gh error (rate limit, expired auth, network blip).
            *mergeStateStatus*) exit 1 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

set +e
OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1)
RC=$?
set -e

[ "$RC" -ne 0 ] || red "expected non-zero exit when the re-query itself fails, got 0:\n$OUT"
echo "$OUT" | grep -q "Done\." && red "must not print a 'Done.' line when the re-query failed:\n$OUT"
echo "$OUT" | grep -qE '\[5/7\]|\[6/7\]|\[7/7\]' && red "must not reach steps 5-7 after a re-query failure:\n$OUT"
echo "$OUT" | grep -q "confirmed state=" && red "must not claim a confirmed state when the re-query itself failed:\n$OUT"
echo "$OUT" | grep -qi "UNKNOWN" || red "expected the message to say the state is UNKNOWN, got:\n$OUT"
echo "$OUT" | grep -qi "rebase onto the default branch and retry\." && red "must NOT suggest a rebase when the state couldn't even be confirmed:\n$OUT"
green "a failed re-query fails closed, reports state=UNKNOWN, and gives no rebase hint"
write_normal_gh_stub

# ============================================================================
heading "Test 5: the post-refusal re-query succeeds but returns empty output → same fail-closed/UNKNOWN handling"
# ============================================================================
: > "$POST_STATE_FILE"   # empty file: gh exits 0 but prints nothing

set +e
OUT=$(timeout 5 "$MERGE" 77 --no-kill 2>&1)
RC=$?
set -e

[ "$RC" -ne 0 ] || red "expected non-zero exit when the re-query returns empty output, got 0:\n$OUT"
echo "$OUT" | grep -q "Done\." && red "must not print a 'Done.' line when the re-query returned nothing:\n$OUT"
echo "$OUT" | grep -qE '\[5/7\]|\[6/7\]|\[7/7\]' && red "must not reach steps 5-7 after an empty re-query:\n$OUT"
echo "$OUT" | grep -q "confirmed state=" && red "must not claim a confirmed state from empty re-query output:\n$OUT"
echo "$OUT" | grep -qi "UNKNOWN" || red "expected the message to say the state is UNKNOWN, got:\n$OUT"
echo "$OUT" | grep -qi "rebase onto the default branch and retry\." && red "must NOT suggest a rebase when the re-query returned nothing:\n$OUT"
green "an empty re-query result fails closed, reports state=UNKNOWN, and gives no rebase hint"

# ============================================================================
heading "All #492 shape tests passed"
# ============================================================================
green "swarm-merge.sh only tolerates a refused gh pr merge when the PR is confirmed MERGED"
green "and its refusal message matches what is actually known (open+conflict / open+no-conflict / unknown)"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
