#!/usr/bin/env bash
# swarm-merge.sh — merge a swarm PR and clean up the local mess.
#
# Usage:
#   swarm-merge.sh <issue#|PR#>       # resolves PR from issue (or issue from
#                                      # PR), merges, cleans
#   swarm-merge.sh <issue#|PR#> --no-kill # skip the tmux-kill step
#   swarm-merge.sh <issue#|PR#> --override-review  # merge despite a BLOCK verdict
#   swarm-merge.sh <issue#|PR#> --override-migration-gate  # merge despite a migration collision
#   swarm-merge.sh --sweep-only       # just run the local-branch sweep
#
# What it does:
#   1. Resolves the given number as either an issue or a PR (GitHub shares
#      one numbering sequence, so #N is exactly one object). Given an issue,
#      resolves its linked PR (unchanged pre-#324 behavior). Given a PR,
#      walks back to its linked issue so the issue-keyed cleanup below
#      (tmux window, worktree, branch sweep) still knows what to clean —
#      if the PR has no linked issue, the merge proceeds but that cleanup
#      is skipped (and said so explicitly) rather than silently no-opped.
#   2. Verifies the PR is OPEN and MERGEABLE (or already MERGED → just cleans),
#      and checks the self-review verdict gate: a
#      <!-- SWARM_SELF_REVIEW: BLOCK --> marker comment (posted by
#      scripts/self-review-pr.sh) refuses the merge unless --override-review
#      is given. Verdict-gated merging is a ringer-concept adoption — see
#      docs/ringer-adoptions.md #2.
#      Also runs scripts/migration-collision-check.sh, refusing on a
#      duplicate Flyway version / Alembic multi-head collision unless
#      --override-migration-gate is given. MIGRATION_GATE=0 disables this
#      gate entirely (default on) — see #294.
#   3. cds to the MAIN worktree of the current repo (not the feature one).
#   4. Runs `gh pr merge --squash --delete-branch`. The local-delete step may
#      fail silently if the branch is checked out in a sibling worktree —
#      that's fine; we sweep it later.
#   5. Waits up to 60s for the watcher to reap the worker's worktree + tmux window.
#   6. If the iss-<N> tmux window is still alive after the grace period, kills it.
#   7. Runs the SAFER local-branch sweep: deletes `fix/issue-N` only when GitHub
#      issue N's state is CLOSED. (Never deletes branches for OPEN issues, so
#      in-flight workers stay safe.)
#   8. Reports final state.
#
# Exits 0 on success, non-zero on bailout.

set -euo pipefail

GRACE_SECONDS=60
NO_KILL=0
SWEEP_ONLY=0
OVERRIDE_REVIEW=0
OVERRIDE_MIGRATION_GATE=0
ISSUE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- arg parsing -----------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --no-kill)    NO_KILL=1 ;;
    --sweep-only) SWEEP_ONLY=1 ;;
    --override-review) OVERRIDE_REVIEW=1 ;;
    --override-migration-gate) OVERRIDE_MIGRATION_GATE=1 ;;
    --help|-h)
      sed -n '2,/^# Exits/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag '$arg'" >&2
      exit 2
      ;;
    *)
      [ -z "$ISSUE" ] || { echo "ERROR: multiple issue numbers given" >&2; exit 2; }
      ISSUE="$arg"
      ;;
  esac
done

# --- helpers ---------------------------------------------------------------

# `git worktree list` first row is always the main worktree.
main_worktree() {
  git worktree list --porcelain | awk '/^worktree / { print $2; exit }'
}

# Color helpers; harmless if not a tty.
c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_amber() { printf '\033[33m%s\033[0m' "$1"; }
c_dim()   { printf '\033[2m%s\033[0m' "$1"; }

# --- safer local-branch sweep ---------------------------------------------
#
# For each local `fix/issue-N` branch, look up issue N on GitHub.
# Delete the branch ONLY if the issue state is CLOSED.
# This is safer than the "remote branch absent" heuristic because a
# freshly-provisioned worker that hasn't pushed yet has an OPEN issue and
# no remote branch — we never want to delete those.
run_sweep() {
  echo "[sweep] scanning local fix/issue-* branches…"
  local deleted=0 kept_open=0 skipped=0
  for b in $(git branch --format='%(refname:short)' | grep -E '^fix/issue-[0-9]+' || true); do
    # Branch name may have a suffix (e.g. fix/issue-118-cluster-a); keep the full
    # name for deletion, but extract just the leading issue number for lookup.
    local num
    num=$(echo "$b" | grep -oE '^fix/issue-[0-9]+' | sed 's|^fix/issue-||')
    local state
    state=$(gh issue view "$num" --json state -q .state 2>/dev/null || echo "UNKNOWN")
    case "$state" in
      CLOSED)
        if git branch -D "$b" >/dev/null 2>&1; then
          echo "  $(c_green "✓") $b (issue #$num CLOSED) — deleted"
          deleted=$((deleted+1))
        else
          echo "  $(c_amber "?") $b (issue #$num CLOSED) — could not delete (still checked out?)"
        fi
        ;;
      OPEN)
        echo "  $(c_dim "·") $b (issue #$num OPEN) — keeping (worker may be in flight)"
        kept_open=$((kept_open+1))
        ;;
      *)
        echo "  $(c_dim "·") $b (issue #$num state=$state) — skipping"
        skipped=$((skipped+1))
        ;;
    esac
  done
  echo "[sweep] deleted=$deleted, kept_open=$kept_open, skipped=$skipped"
}

# --- sweep-only mode -------------------------------------------------------

if [ "$SWEEP_ONLY" = 1 ]; then
  cd "$(main_worktree)"
  run_sweep
  exit 0
fi

# --- normal mode: require an issue number ---------------------------------

if [ -z "$ISSUE" ]; then
  echo "ERROR: issue# or PR# required (or use --sweep-only)" >&2
  echo "Usage: $0 <issue#|PR#> [--no-kill]" >&2
  exit 2
fi

# Sanity: in a git repo?
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repo" >&2; exit 1; }

# cd to main worktree so gh pr merge's local-pull step has the right cwd.
MAIN_WT=$(main_worktree)
cd "$MAIN_WT"
echo "[1/7] working in main worktree: $MAIN_WT"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/_load-env.sh" "$MAIN_WT"

# Resolve the given number as either an issue or a PR — GitHub shares one
# numbering sequence, so #N is exactly one object and this is unambiguous.
INPUT_NUM="$ISSUE"
ISSUE=""
PR_NUM=""

IS_PR=$(gh api "repos/{owner}/{repo}/issues/$INPUT_NUM" --jq '.pull_request != null' 2>/dev/null || echo "")

if [ "$IS_PR" = "true" ]; then
  PR_NUM="$INPUT_NUM"
  echo "[2/7] #$INPUT_NUM is PR #$PR_NUM"
else
  # IS_PR="false" means the probe cleanly resolved INPUT_NUM as an issue.
  # IS_PR="" means the probe itself failed (rate limit, transient network,
  # expired auth, or a genuinely nonexistent number) — rather than treat
  # that the same as "definitely a PR doesn't exist" and abort, fall back
  # to the pre-#324 issue-lookup path. That path is exactly what every
  # issue-number invocation relied on before this probe existed, so a
  # flaky probe never regresses the case that already worked.
  if [ "$IS_PR" != "false" ]; then
    echo "       $(c_amber "⚠ could not classify #$INPUT_NUM via gh api (transient failure?) — falling back to issue lookup")"
  fi
  ISSUE="$INPUT_NUM"
  PR_NUM=$(gh issue view "$ISSUE" --json closedByPullRequestsReferences \
             -q '.closedByPullRequestsReferences[0].number' 2>/dev/null || echo "")
  if [ -z "$PR_NUM" ] || [ "$PR_NUM" = "null" ]; then
    if [ "$IS_PR" = "false" ]; then
      echo "ERROR: no linked PR found for issue #$ISSUE" >&2
    else
      echo "ERROR: could not resolve #$INPUT_NUM as an issue or PR (gh api classification failed, and #$INPUT_NUM has no linked PR as an issue either)" >&2
    fi
    exit 1
  fi
  echo "[2/7] issue #$ISSUE → PR #$PR_NUM"
fi

# Inspect PR state.
PR_JSON=$(gh pr view "$PR_NUM" --json state,mergeable,headRefName,title,closingIssuesReferences)
PR_STATE=$(echo "$PR_JSON" | jq -r .state)
PR_MERGEABLE=$(echo "$PR_JSON" | jq -r .mergeable)
PR_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
PR_TITLE=$(echo "$PR_JSON" | jq -r .title)
echo "[3/7] PR #$PR_NUM: state=$PR_STATE mergeable=$PR_MERGEABLE branch=$PR_BRANCH"
echo "       title: $PR_TITLE"

if [ -z "$ISSUE" ]; then
  # Local artifacts (tmux window, worktree, branch) are keyed on the branch
  # name provision-worker.sh assigned at spawn time — prefer that as the
  # stronger signal over closingIssuesReferences, which only reflects
  # closing keywords in the PR *body* (empty for a title-only "fixes #N")
  # and, being free-text, could in principle name a different issue than
  # the one this actual worker branch belongs to.
  if [[ "$PR_BRANCH" =~ ^fix/issue-([0-9]+) ]]; then
    ISSUE="${BASH_REMATCH[1]}"
    echo "       branch name encodes issue #$ISSUE — using it for cleanup"
  else
    LINKED_ISSUE=$(echo "$PR_JSON" | jq -r '.closingIssuesReferences[0].number // empty')
    if [ -n "$LINKED_ISSUE" ]; then
      ISSUE="$LINKED_ISSUE"
      echo "       branch name doesn't match fix/issue-N; using closing-issue reference #$ISSUE instead"
    else
      echo "       $(c_amber "⚠ no linked issue — issue-keyed cleanup (tmux window / worktree) will be skipped")"
    fi
  fi
fi

case "$PR_STATE" in
  OPEN)
    if [ "$PR_MERGEABLE" = "CONFLICTING" ]; then
      echo "ERROR: PR #$PR_NUM has merge conflicts. Resolve first." >&2
      echo "       See \$LLM_SWARM_DOCS/VCS/git-github.md for the playbook." >&2
      exit 1
    fi
    # Self-review verdict gate (ringer concept #2 — docs/ringer-adoptions.md).
    # Latest SWARM_SELF_REVIEW marker comment (from self-review-pr.sh) wins.
    VERDICT=$(gh pr view "$PR_NUM" --json comments -q '.comments[].body' 2>/dev/null \
              | grep -oE 'SWARM_SELF_REVIEW: (APPROVE_WITH_CAVEATS|APPROVE|BLOCK)' \
              | tail -1 | sed 's/^SWARM_SELF_REVIEW: //' || true)
    case "$VERDICT" in
      BLOCK)
        if [ "$OVERRIDE_REVIEW" = 0 ]; then
          echo "ERROR: PR #$PR_NUM has a self-review BLOCK verdict. Read the review" >&2
          echo "       comment on the PR; merge with --override-review if you disagree." >&2
          exit 1
        fi
        echo "       $(c_amber "⚠ overriding self-review BLOCK verdict (--override-review)")"
        ;;
      APPROVE_WITH_CAVEATS)
        echo "       $(c_amber "self-review: APPROVE_WITH_CAVEATS — read the caveat on the PR")" ;;
      APPROVE)
        echo "       $(c_green "self-review: APPROVE")" ;;
      *)
        echo "       $(c_dim "no self-review verdict comment (optional: scripts/self-review-pr.sh $PR_NUM --post)")" ;;
    esac
    # Migration collision gate (#294): duplicate Flyway versions / Alembic
    # multi-heads only exist in the *union* of base + head branches, so this
    # is the last point they can be reliably caught before merge.
    if [ "${MIGRATION_GATE:-1}" = "0" ]; then
      echo "       $(c_dim "migration gate: skipped (MIGRATION_GATE=0)")"
    else
      MIGRATION_RC=0
      "$SCRIPT_DIR/migration-collision-check.sh" "$PR_NUM" || MIGRATION_RC=$?
      case "$MIGRATION_RC" in
        0) echo "       $(c_green "migration gate: clean")" ;;
        4) echo "       $(c_dim "migration gate: no migration files touched")" ;;
        2)
          if [ "$OVERRIDE_MIGRATION_GATE" = 0 ]; then
            echo "ERROR: PR #$PR_NUM has a migration collision (duplicate Flyway" >&2
            echo "       version or Alembic multi-head). Run" >&2
            echo "       scripts/migration-collision-check.sh $PR_NUM for details;" >&2
            echo "       merge with --override-migration-gate if you disagree." >&2
            exit 1
          fi
          echo "       $(c_amber "⚠ overriding migration collision (--override-migration-gate)")"
          ;;
        *)
          echo "ERROR: migration-collision-check.sh failed (exit $MIGRATION_RC)" >&2
          exit 1
          ;;
      esac
    fi
    echo "[4/7] merging PR #$PR_NUM (squash, delete-branch)…"
    # gh pr merge's local-delete step may fail; tolerate it.
    if ! gh pr merge "$PR_NUM" --squash --delete-branch; then
      echo "       (local-delete step may have failed; that's expected if branch is still checked out in a worktree — sweep will clean it)"
    fi
    ;;
  MERGED)
    echo "[4/7] PR #$PR_NUM already MERGED — proceeding to cleanup"
    ;;
  CLOSED)
    echo "ERROR: PR #$PR_NUM is CLOSED (not merged). Nothing to do." >&2
    exit 1
    ;;
  *)
    echo "ERROR: PR #$PR_NUM in unexpected state: $PR_STATE" >&2
    exit 1
    ;;
esac

if [ -n "$ISSUE" ]; then
  # Wait for watcher to reap the worktree + tmux window.
  TMUX_WIN="iss-$ISSUE"
  WORKTREE_DIR="$(swarm_worktree_dir "$MAIN_WT" "$ISSUE")"
  echo "[5/7] waiting up to ${GRACE_SECONDS}s for watcher reap of $TMUX_WIN + $(basename "$WORKTREE_DIR")…"
  elapsed=0
  while [ $elapsed -lt $GRACE_SECONDS ]; do
    tmux_alive=0
    wt_alive=0
    tmux list-windows 2>/dev/null | grep -qE ": ${TMUX_WIN}[* -]?\b" && tmux_alive=1
    [ -e "$WORKTREE_DIR/.git" ] && wt_alive=1
    if [ $tmux_alive -eq 0 ] && [ $wt_alive -eq 0 ]; then
      echo "       reaped after ${elapsed}s ✓"
      break
    fi
    sleep 3
    elapsed=$((elapsed+3))
  done

  # If still alive, manually kill (unless --no-kill).
  if [ "$NO_KILL" = 0 ]; then
    if tmux list-windows 2>/dev/null | grep -qE ": ${TMUX_WIN}[* -]?\b"; then
      echo "[6/7] watcher didn't reap; killing tmux window $TMUX_WIN"
      tmux kill-window -t "$TMUX_WIN" 2>/dev/null || true
    fi
    if [ -e "$WORKTREE_DIR/.git" ]; then
      echo "[6/7] watcher didn't reap; removing worktree $WORKTREE_DIR"
      git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
    fi
  else
    echo "[6/7] --no-kill set; leaving tmux window / worktree alone"
  fi
else
  echo "[5/7] no linked issue for PR #$PR_NUM — skipping tmux/worktree reap wait"
  echo "[6/7] no linked issue for PR #$PR_NUM — skipping tmux/worktree kill"
fi

# Run the safer local-branch sweep.
echo "[7/7] running local-branch sweep…"
run_sweep

echo
if [ -n "$ISSUE" ]; then
  echo "$(c_green "Done.") PR #$PR_NUM merged for issue #$ISSUE."
else
  echo "$(c_green "Done.") PR #$PR_NUM merged (no linked issue)."
fi
