#!/usr/bin/env bash
#
# test-pr-brief-marker.sh — Non-LLM regression test for the PR-comment
# reap-race signal added in issue #375.
#
# The #375 bug: a coordinator-requeued follow-up brief (a review-BLOCK fix,
# a privacy caveat) could sit undelivered in a worker's inbox/ while a
# human merged its target PR straight from GitHub — nothing at the PR said
# a fix was queued. kill-worktree.sh's existing salvage (issue #317)
# preserves the brief's bytes but not that signal.
#
# This test exercises the three pieces added to close that gap, using a
# gh stub (no network) that logs every call and records posted comment
# bodies so idempotency and content can be asserted directly:
#
#   1. requeue.sh's notify_pr_pending_brief — posts a
#      `SWARM_PENDING_BRIEF: queued` marker comment when the target
#      worktree's branch has an OPEN PR; skips re-posting while the latest
#      marker already says "queued" (idempotent), but re-flags once a
#      "cleared" comment supersedes it.
#   2. worker-listener.sh's clear_pr_pending_brief_marker — posts the
#      matching `SWARM_PENDING_BRIEF: cleared` comment once a task
#      resolves a PR number AND the worktree's inbox/processing are both
#      drained; skipped when there's nothing "queued" to clear, or when
#      another brief is still queued behind the one that just finished
#      (clearing then would be a false "resolved" — caught in this PR's
#      own self-review, see Test 3). Tested directly (function extracted,
#      not the full dispatch loop — worker-listener.sh has no other test
#      coverage for the same reason: the agent-dispatch loop isn't
#      unit-testable without a real LLM invocation).
#   3. kill-worktree.sh's notify_pr_brief_orphaned — best-effort posts a
#      `SWARM_BRIEF_ORPHANED` comment on the reaped branch's PR when a
#      non-empty inbox/processing/outbox gets salvaged.
#
# Strategy mirrors test-kill-finished-workers.sh: real git fixtures, no
# tmux needed here, gh stubbed via a PATH shim dir that both logs calls
# and simulates comment state so "last marker wins" idempotency is
# actually exercised, not just assumed.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUEUE="$SCRIPT_DIR/../scripts/requeue.sh"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
[ -x "$REQUEUE" ] || red "requeue.sh not executable: $REQUEUE"
[ -x "$KILL_WT" ]  || red "kill-worktree.sh not executable: $KILL_WT"
[ -r "$LISTENER" ] || red "worker-listener.sh not readable: $LISTENER"

command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t pr-brief-marker-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────── gh stub ────────────────────────────────────────
# Simulates just enough of `gh pr view`/`gh pr comment` to exercise the
# last-comment-wins idempotency idiom: every posted comment body is
# base64-encoded onto one line of $COMMENTS_LOG (the real comment bodies
# are multi-line markdown, so a raw append would make one comment look
# like several), and a `--json comments` lookup decodes and replays the
# last line — exactly what the scripts under test then grep/sed against.
command -v base64 >/dev/null 2>&1 || red "base64 not installed (needed by this test's gh stub)"

SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
GH_LOG="$TEST_DIR/gh.log"
COMMENTS_LOG="$TEST_DIR/comments.log"
: > "$GH_LOG"
: > "$COMMENTS_LOG"

# fix/issue-90 → PR #77, OPEN. Every other branch → no PR.
cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"

if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    target="\$3"
    json=""
    prev=""
    for a in "\$@"; do
        [ "\$prev" = "--json" ] && json="\$a"
        prev="\$a"
    done
    case "\$json" in
        number,state)
            if [ "\$target" = "fix/issue-90" ]; then printf '77\tOPEN\n'; exit 0; fi
            exit 1
            ;;
        number)
            if [ "\$target" = "fix/issue-90" ]; then echo 77; exit 0; fi
            exit 1
            ;;
        comments)
            # target is the PR number here; this stub only ever tracks one
            # PR (#77), so just replay the last posted comment body.
            [ "\$target" = "77" ] || exit 1
            if [ -s "$COMMENTS_LOG" ]; then
                tail -n1 "$COMMENTS_LOG" | base64 -d
            fi
            exit 0
            ;;
        *) exit 1 ;;
    esac
fi

if [ "\$1" = "pr" ] && [ "\$2" = "comment" ]; then
    body=""
    prev=""
    for a in "\$@"; do
        [ "\$prev" = "--body" ] && body="\$a"
        prev="\$a"
    done
    # base64-encode so a multi-line body collapses to exactly one log line
    # — one comment == one line, so `wc -l`/`tail -n1` on the log work.
    printf '%s' "\$body" | base64 -w0 >> "$COMMENTS_LOG"
    printf '\n' >> "$COMMENTS_LOG"
    exit 0
fi

exit 1
EOF
chmod +x "$SHIM_DIR/gh"

gh_comment_count() { wc -l < "$COMMENTS_LOG" | tr -d ' '; }
gh_last_comment()  { tail -n1 "$COMMENTS_LOG" | base64 -d; }

# ─────────────────────────── fixture: repo + worktree ───────────────────────

heading "Setup: fixture repo + worktree on issue #90 (branch has a stubbed OPEN PR #77)"
cd "$TEST_DIR"
mkdir proj && cd proj
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git worktree add -q -b fix/issue-90 ../wt-issue-90 master
WT="$TEST_DIR/wt-issue-90"
mkdir -p "$WT/.swarm/tasks/inbox"
green "fixture ready: proj + wt-issue-90 (fix/issue-90 → gh stub PR #77 OPEN)"

# ============================================================================
heading "Test 1: requeue.sh posts SWARM_PENDING_BRIEF: queued on first requeue"
# ============================================================================

echo "follow-up: fix the thing" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" 90 - \
    > "$TEST_DIR/requeue1.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue1.out")"
[ "$(gh_comment_count)" -eq 1 ] || red "expected exactly 1 posted comment after first requeue, got $(gh_comment_count)"
gh_last_comment | grep -q 'SWARM_PENDING_BRIEF: queued' \
    || red "posted comment missing SWARM_PENDING_BRIEF: queued marker: $(gh_last_comment)"
gh_last_comment | grep -q "task \`" || red "posted comment missing task-id reference"
grep -q 'pr comment 77' "$GH_LOG" || red "expected gh pr comment against PR #77"
green "first requeue posts a SWARM_PENDING_BRIEF: queued comment on PR #77"

# ============================================================================
heading "Test 2: a second requeue while still 'queued' does NOT re-post (idempotent)"
# ============================================================================

echo "another follow-up" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" 90 - \
    > "$TEST_DIR/requeue2.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue2.out")"
[ "$(gh_comment_count)" -eq 1 ] || red "expected still exactly 1 posted comment (idempotent skip), got $(gh_comment_count)"
green "second requeue skips posting — latest marker already says queued"

# Extract just the function under test — worker-listener.sh's main body
# runs a live poll loop that isn't safe or meaningful to source directly.
CLEAR_FN="$TEST_DIR/clear_fn.sh"
sed -n '/^clear_pr_pending_brief_marker() {/,/^}/p' "$LISTENER" > "$CLEAR_FN"
[ -s "$CLEAR_FN" ] || red "could not extract clear_pr_pending_brief_marker from worker-listener.sh"

EMPTY_INBOX="$TEST_DIR/empty-inbox"
EMPTY_PROCESSING="$TEST_DIR/empty-processing"
mkdir -p "$EMPTY_INBOX" "$EMPTY_PROCESSING"

# ============================================================================
heading "Test 3: clear_pr_pending_brief_marker stays silent while another brief is still queued (self-review catch)"
# ============================================================================

# Tests 1+2 above each dropped a brief into $WT's real inbox/ via
# requeue.sh and never drained it (no listener loop runs in this test) —
# it has 2 files right now. That's exactly the scenario a first version of
# this function got wrong: task A finishes and resolves a PR, but brief B
# (a second, independent follow-up — or the same one, just not yet
# claimed) is still sitting there unclaimed. Clearing the marker in that
# state would tell a human "resolved" while B is still pending — a false
# green. Confirm the gate holds: non-empty inbox -> no clear, no new
# comment, latest marker stays "queued".
PRE_GATE="$(gh_comment_count)"
(
    # shellcheck disable=SC1090
    source "$CLEAR_FN"
    PATH="$SHIM_DIR:$PATH"
    clear_pr_pending_brief_marker 77 "$WT/.swarm/tasks/inbox" "$EMPTY_PROCESSING"
)
[ "$(gh_comment_count)" -eq "$PRE_GATE" ] \
    || red "expected no new comment while inbox/ still has other queued briefs, went from $PRE_GATE to $(gh_comment_count)"
gh_last_comment | grep -q 'SWARM_PENDING_BRIEF: queued' \
    || red "expected the marker to remain 'queued' — a brief is still unclaimed: $(gh_last_comment)"
green "clear_pr_pending_brief_marker gates on a drained queue — stays silent with another brief still in inbox/"

# ============================================================================
heading "Test 4: worker-listener.sh's clear_pr_pending_brief_marker posts 'cleared' once the queue is drained"
# ============================================================================

(
    # shellcheck disable=SC1090
    source "$CLEAR_FN"
    PATH="$SHIM_DIR:$PATH"
    clear_pr_pending_brief_marker 77 "$EMPTY_INBOX" "$EMPTY_PROCESSING"
)
[ "$(gh_comment_count)" -eq 2 ] || red "expected a 2nd posted comment (the clear), got $(gh_comment_count)"
gh_last_comment | grep -q 'SWARM_PENDING_BRIEF: cleared' \
    || red "expected the latest comment to carry SWARM_PENDING_BRIEF: cleared: $(gh_last_comment)"
green "clear_pr_pending_brief_marker posts SWARM_PENDING_BRIEF: cleared once inbox/processing are empty"

# ============================================================================
heading "Test 5: clear_pr_pending_brief_marker is a no-op when latest is already 'cleared'"
# ============================================================================

(
    # shellcheck disable=SC1090
    source "$CLEAR_FN"
    PATH="$SHIM_DIR:$PATH"
    clear_pr_pending_brief_marker 77 "$EMPTY_INBOX" "$EMPTY_PROCESSING"
)
[ "$(gh_comment_count)" -eq 2 ] || red "expected no new comment (nothing to clear), got $(gh_comment_count) total"
green "clear is a no-op once the marker is already cleared"

# ============================================================================
heading "Test 6: a requeue AFTER a clear re-flags the PR (posts 'queued' again)"
# ============================================================================

echo "yet another follow-up" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" 90 - \
    > "$TEST_DIR/requeue3.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue3.out")"
[ "$(gh_comment_count)" -eq 3 ] || red "expected a 3rd posted comment (re-flag), got $(gh_comment_count)"
gh_last_comment | grep -q 'SWARM_PENDING_BRIEF: queued' \
    || red "expected the latest comment to be queued again: $(gh_last_comment)"
green "requeue re-flags the PR once the previous marker was cleared"

# ============================================================================
heading "Test 7: kill-worktree.sh posts SWARM_BRIEF_ORPHANED when salvaging a non-empty inbox"
# ============================================================================

# Reuse wt-issue-90 itself — its branch (fix/issue-90) is the one the gh
# stub recognizes as PR #77 — and drop a brief straight into its queue
# (bypassing requeue.sh here since this test targets kill-worktree.sh's
# salvage-time comment, not the queueing comment from Tests 1-5/2 above).
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing"
echo "orphaned brief" > "$WT/.swarm/tasks/inbox/orphan-brief.md"

PRE_COMMENTS="$(gh_comment_count)"
PATH="$SHIM_DIR:$PATH" "$KILL_WT" 90 "$TEST_DIR/proj" \
    > "$TEST_DIR/killwt.out" 2>&1 || red "kill-worktree.sh exited non-zero: $(cat "$TEST_DIR/killwt.out")"
grep -q 'SALVAGED' "$TEST_DIR/killwt.out" || red "expected a SALVAGED line: $(cat "$TEST_DIR/killwt.out")"
POST_COMMENTS="$(gh_comment_count)"
[ "$POST_COMMENTS" -eq $((PRE_COMMENTS + 1)) ] \
    || red "expected exactly 1 new comment from the orphan reap, went from $PRE_COMMENTS to $POST_COMMENTS"
gh_last_comment | grep -q 'SWARM_BRIEF_ORPHANED' \
    || red "expected the newest comment to carry SWARM_BRIEF_ORPHANED: $(gh_last_comment)"
gh_last_comment | grep -q 'salvaged/iss-90' \
    || red "expected the orphan comment to reference the salvage dir"
grep -q 'pr comment 77' "$GH_LOG" || red "expected the orphan comment posted against PR #77"
green "kill-worktree.sh posts SWARM_BRIEF_ORPHANED on the reaped branch's PR, referencing the salvage dir"

# ============================================================================
heading "Test 8: requeue.sh posts nothing for a branch with no PR"
# ============================================================================

git worktree add -q -b fix/issue-91 ../wt-issue-91 master
mkdir -p "$TEST_DIR/wt-issue-91/.swarm/tasks/inbox"
PRE="$(gh_comment_count)"
echo "brief for a PR-less branch" | PATH="$SHIM_DIR:$PATH" "$REQUEUE" 91 - \
    > "$TEST_DIR/requeue91.out" 2>&1 || red "requeue.sh exited non-zero: $(cat "$TEST_DIR/requeue91.out")"
[ "$(gh_comment_count)" -eq "$PRE" ] || red "expected no new comment for a branch with no PR"
green "requeue.sh stays silent when the target branch has no PR (never blocks the requeue itself)"

echo
green "ALL TESTS PASSED"
