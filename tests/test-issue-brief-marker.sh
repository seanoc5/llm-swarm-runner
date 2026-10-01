#!/usr/bin/env bash
#
# test-issue-brief-marker.sh — Non-LLM regression test for the issue #458
# pre-PR fallback marker.
#
# The #458 bug (civicstrata iss-487, 2026-09-23): a coordinator-requeued
# follow-up brief could sit undelivered in a worker's inbox/ for hours while
# the worker was parked mid-task at an interactive in-pane question — and
# because no PR existed yet at requeue time, issue #375's
# `SWARM_PENDING_BRIEF: queued` PR-comment marker had nowhere to land.
# Nothing anywhere a human would look showed a brief was queued.
#
# This test exercises the fallback added to close that gap, using a gh stub
# (no network) that supports both `pr` and `issue` subcommands, each with
# its own comment log, so the dispatcher's PR-vs-issue routing and each
# path's idempotency can be asserted directly:
#
#   1. requeue.sh's notify_pending_brief dispatcher — routes to the issue
#      #458 fallback (notify_issue_pending_brief) when the target branch
#      has no OPEN PR, posting `SWARM_PENDING_BRIEF: queued` on the GitHub
#      ISSUE instead (worktree name must match wt-issue-<N>).
#   2. Idempotent the same way as the PR path: a second requeue while the
#      latest issue marker still says "queued" does not re-post.
#   3. worker-listener.sh's clear_issue_pending_brief_marker — gates on a
#      drained queue (inbox AND processing empty) exactly like the PR-side
#      clear_pr_pending_brief_marker, and posts the matching `cleared`
#      comment once drained.
#   4. Once the branch gets an OPEN PR, a subsequent requeue routes to the
#      PR marker instead of the issue — the dispatcher's whole point.
#   5. A worktree whose name doesn't match wt-issue-<N> can't be mapped to
#      an issue number, so the fallback silently declines (no gh issue
#      call at all) rather than guessing.
#
# Strategy mirrors test-pr-brief-marker.sh.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUEUE="$SCRIPT_DIR/../scripts/requeue.sh"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$REQUEUE" ] || red "requeue.sh not executable: $REQUEUE"
[ -r "$LISTENER" ] || red "worker-listener.sh not readable: $LISTENER"

command -v git >/dev/null || red "git not installed"
command -v base64 >/dev/null 2>&1 || red "base64 not installed (needed by this test's gh stub)"

TEST_DIR=$(mktemp -d -t issue-brief-marker-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────── gh stub ────────────────────────────────────────
# fix/issue-90 → PR #77, OPEN (mirrors test-pr-brief-marker.sh's fixture, so
# Test 4 below can flip issue-90 from PR-less to PR'd without a new branch).
# Every other branch → no PR. Issue comments are tracked per issue number in
# $ISSUE_COMMENTS_DIR/<N>.log; PR comments in one shared $PR_COMMENTS_LOG —
# separate logs so the dispatcher's routing is verifiable, not just assumed.
SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
GH_LOG="$TEST_DIR/gh.log"
PR_COMMENTS_LOG="$TEST_DIR/pr-comments.log"
ISSUE_COMMENTS_DIR="$TEST_DIR/issue-comments"
mkdir -p "$ISSUE_COMMENTS_DIR"
: > "$GH_LOG"
: > "$PR_COMMENTS_LOG"

cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"

arg_after() {
    local want="\$1"; shift
    local prev=""
    for a in "\$@"; do
        [ "\$prev" = "\$want" ] && { printf '%s' "\$a"; return; }
        prev="\$a"
    done
}

if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    # No branch has a PR yet in this stub generation — Test 5 below swaps in
    # a second gh stub that gives fix/issue-90 a PR once it should route
    # there instead.
    exit 1
fi

if [ "\$1" = "pr" ] && [ "\$2" = "comment" ]; then
    body="\$(arg_after --body "\$@")"
    printf '%s' "\$body" | base64 -w0 >> "$PR_COMMENTS_LOG"
    printf '\n' >> "$PR_COMMENTS_LOG"
    exit 0
fi

if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
    target="\$3"
    json="\$(arg_after --json "\$@")"
    log="$ISSUE_COMMENTS_DIR/\$target.log"
    case "\$json" in
        comments)
            if [ -s "\$log" ]; then
                tail -n1 "\$log" | base64 -d
            fi
            exit 0
            ;;
        *) exit 1 ;;
    esac
fi

if [ "\$1" = "issue" ] && [ "\$2" = "comment" ]; then
    target="\$3"
    body="\$(arg_after --body "\$@")"
    log="$ISSUE_COMMENTS_DIR/\$target.log"
    printf '%s' "\$body" | base64 -w0 >> "\$log"
    printf '\n' >> "\$log"
    exit 0
fi

exit 1
EOF
chmod +x "$SHIM_DIR/gh"

pr_comment_count()    { wc -l < "$PR_COMMENTS_LOG" | tr -d ' '; }
issue_comment_count() { local n="$1"; local log="$ISSUE_COMMENTS_DIR/$n.log"; [ -f "$log" ] && wc -l < "$log" | tr -d ' ' || echo 0; }
issue_last_comment()  { tail -n1 "$ISSUE_COMMENTS_DIR/$1.log" | base64 -d; }

# ─────────────────────────── fixture: repo + worktree ───────────────────────

heading "Setup: fixture repo + worktree on issue #90 (branch starts with NO PR)"
cd "$TEST_DIR"
mkdir proj && cd proj
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git worktree add -q -b fix/issue-90 ../wt-issue-90 master
WT="$TEST_DIR/wt-issue-90"
mkdir -p "$WT/.swarm/tasks/inbox"
green "fixture ready: proj + wt-issue-90 (fix/issue-90 → gh stub reports no PR yet)"

# ============================================================================
heading "Test 1: requeue.sh falls back to the ISSUE when the branch has no OPEN PR"
# ============================================================================

echo "follow-up: answer my pane question first" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" 90 - \
    > "$TEST_DIR/requeue1.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue1.out")"
[ "$(pr_comment_count)" -eq 0 ] || red "expected no PR comment (branch has no PR), got $(pr_comment_count)"
[ "$(issue_comment_count 90)" -eq 1 ] || red "expected exactly 1 comment posted on issue #90, got $(issue_comment_count 90)"
issue_last_comment 90 | grep -q 'SWARM_PENDING_BRIEF: queued' \
    || red "posted issue comment missing SWARM_PENDING_BRIEF: queued marker: $(issue_last_comment 90)"
issue_last_comment 90 | grep -q 'no open PR exists yet' \
    || red "expected the issue comment to explain why it's not on a PR: $(issue_last_comment 90)"
issue_last_comment 90 | grep -q 'answer my pane question first' \
    || red "expected the brief's own text excerpted into the issue comment: $(issue_last_comment 90)"
grep -q 'issue comment 90' "$GH_LOG" || red "expected gh issue comment against issue #90"
green "requeue.sh posts SWARM_PENDING_BRIEF: queued on issue #90 when its branch has no OPEN PR"

# ============================================================================
heading "Test 2: a second requeue while still 'queued' does NOT re-post (idempotent)"
# ============================================================================

echo "another follow-up" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" 90 - \
    > "$TEST_DIR/requeue2.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue2.out")"
[ "$(issue_comment_count 90)" -eq 1 ] || red "expected still exactly 1 issue comment (idempotent skip), got $(issue_comment_count 90)"
green "second requeue skips posting — latest issue marker already says queued"

# Extract just the function under test.
CLEAR_FN="$TEST_DIR/clear_fn.sh"
sed -n '/^clear_issue_pending_brief_marker() {/,/^}/p' "$LISTENER" > "$CLEAR_FN"
[ -s "$CLEAR_FN" ] || red "could not extract clear_issue_pending_brief_marker from worker-listener.sh"

EMPTY_INBOX="$TEST_DIR/empty-inbox"
EMPTY_PROCESSING="$TEST_DIR/empty-processing"
mkdir -p "$EMPTY_INBOX" "$EMPTY_PROCESSING"

# ============================================================================
heading "Test 3: clear_issue_pending_brief_marker stays silent while another brief is still queued"
# ============================================================================

# Tests 1+2 dropped 2 briefs into $WT's real inbox/ via requeue.sh and never
# drained it — same drained-queue gate as the PR-side clear, verified here
# against the issue-level marker.
PRE_GATE="$(issue_comment_count 90)"
(
    # shellcheck disable=SC1090
    source "$CLEAR_FN"
    PATH="$SHIM_DIR:$PATH"
    clear_issue_pending_brief_marker 90 "$WT/.swarm/tasks/inbox" "$EMPTY_PROCESSING"
)
[ "$(issue_comment_count 90)" -eq "$PRE_GATE" ] \
    || red "expected no new issue comment while inbox/ still has other queued briefs, went from $PRE_GATE to $(issue_comment_count 90)"
issue_last_comment 90 | grep -q 'SWARM_PENDING_BRIEF: queued' \
    || red "expected the issue marker to remain 'queued' — a brief is still unclaimed: $(issue_last_comment 90)"
green "clear_issue_pending_brief_marker gates on a drained queue — stays silent with another brief still in inbox/"

# ============================================================================
heading "Test 4: clear_issue_pending_brief_marker posts 'cleared' once the queue is drained"
# ============================================================================

(
    # shellcheck disable=SC1090
    source "$CLEAR_FN"
    PATH="$SHIM_DIR:$PATH"
    clear_issue_pending_brief_marker 90 "$EMPTY_INBOX" "$EMPTY_PROCESSING"
)
[ "$(issue_comment_count 90)" -eq 2 ] || red "expected a 2nd posted issue comment (the clear), got $(issue_comment_count 90)"
issue_last_comment 90 | grep -q 'SWARM_PENDING_BRIEF: cleared' \
    || red "expected the latest issue comment to carry SWARM_PENDING_BRIEF: cleared: $(issue_last_comment 90)"
green "clear_issue_pending_brief_marker posts SWARM_PENDING_BRIEF: cleared once inbox/processing are empty"

# ============================================================================
heading "Test 5: once the branch has an OPEN PR, requeue.sh routes to the PR instead of the issue"
# ============================================================================

# Flip the gh stub's known state for fix/issue-90 to report an OPEN PR — the
# same branch, now with a PR, should get the #375 PR marker instead of a
# second issue-level post.
cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"

arg_after() {
    local want="\$1"; shift
    local prev=""
    for a in "\$@"; do
        [ "\$prev" = "\$want" ] && { printf '%s' "\$a"; return; }
        prev="\$a"
    done
}

if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    target="\$3"
    json="\$(arg_after --json "\$@")"
    case "\$json" in
        number,state)
            if [ "\$target" = "fix/issue-90" ]; then printf '77\tOPEN\n'; exit 0; fi
            exit 1
            ;;
        comments)
            [ "\$target" = "77" ] || exit 1
            if [ -s "$PR_COMMENTS_LOG" ]; then
                tail -n1 "$PR_COMMENTS_LOG" | base64 -d
            fi
            exit 0
            ;;
        *) exit 1 ;;
    esac
fi

if [ "\$1" = "pr" ] && [ "\$2" = "comment" ]; then
    body="\$(arg_after --body "\$@")"
    printf '%s' "\$body" | base64 -w0 >> "$PR_COMMENTS_LOG"
    printf '\n' >> "$PR_COMMENTS_LOG"
    exit 0
fi

exit 1
EOF
chmod +x "$SHIM_DIR/gh"

PRE_ISSUE="$(issue_comment_count 90)"
echo "yet another follow-up, now that a PR exists" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" 90 - \
    > "$TEST_DIR/requeue3.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue3.out")"
[ "$(pr_comment_count)" -eq 1 ] || red "expected exactly 1 PR comment once the branch has an OPEN PR, got $(pr_comment_count)"
[ "$(issue_comment_count 90)" -eq "$PRE_ISSUE" ] || red "expected no new issue comment once routing to the PR, went from $PRE_ISSUE to $(issue_comment_count 90)"
tail -n1 "$PR_COMMENTS_LOG" | base64 -d | grep -q 'SWARM_PENDING_BRIEF: queued' \
    || red "expected the PR comment to carry the queued marker"
green "requeue.sh routes to the PR marker (#375) once the branch has an OPEN PR, not the issue fallback"

# ============================================================================
heading "Test 6: a worktree name that doesn't match wt-issue-<N> declines the fallback silently"
# ============================================================================

git worktree add -q -b some-other-branch ../some-other-worktree master
mkdir -p "$TEST_DIR/some-other-worktree/.swarm/tasks/inbox"
: > "$GH_LOG"
echo "brief for an unmappable worktree" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" "$TEST_DIR/some-other-worktree" - \
    > "$TEST_DIR/requeue-unmappable.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue-unmappable.out")"
grep -qE '^(pr|issue) comment' "$GH_LOG" && red "did not expect any gh comment call for a worktree with no derivable issue number: $(cat "$GH_LOG")"
green "requeue.sh declines the issue fallback (no gh call at all) when the worktree name doesn't map to an issue number"

echo
green "ALL TESTS PASSED"
