#!/usr/bin/env bash
# swarm-merge.sh — merge a swarm PR and clean up the local mess.
#
# Usage:
#   swarm-merge.sh <PR#>              # preferred: merges that PR, walks back to
#                                      # its issue for cleanup, cleans
#   swarm-merge.sh <issue#>           # convenience: finds the issue's PR, then
#                                      # the same as above
#   swarm-merge.sh <issue#|PR#> --no-kill # skip the worktree/tmux reap step
#   swarm-merge.sh <issue#|PR#> --override-review  # merge despite a BLOCK verdict
#   swarm-merge.sh <issue#|PR#> --override-migration-gate  # merge despite a migration collision
#   swarm-merge.sh <issue#> --force-cleanup  # housekeep even while the issue is OPEN
#   swarm-merge.sh <issue#|PR#> --squash  # accepted-and-ignored: squash is the only mode
#   swarm-merge.sh <issue#|PR#> --auto-low  # unattended low-risk auto-merge path (#452)
#   swarm-merge.sh --sweep-only       # just run the local-branch sweep
#
# --squash is accepted as a no-op alias (this script always squashes); it is
# not a mode selector. --merge and --rebase are deliberately NOT supported
# and exit non-zero rather than being silently ignored.
#
# --auto-low is for the coordinator's unattended SWARM_AUTOMERGE_LOW path
# ONLY (prompts/coordinator.md "Auto-merge low-risk PRs") — a human calling
# this script directly (or a plain `swarm-merge.sh <N>`) never needs it. It
# adds hard, non-overridable gates (gate numbers match the 8-gate list in
# prompts/coordinator.md; gates 6 (diff-scope read) and 7 (migration
# collision, pre-existing) are not listed again here), fail-closed on any
# error, ordered so the cheap ones refuse before anything spends real
# wall-clock time: Gates 0, 1, 3, 4, 5 first (cheap — single `gh pr view`
# lookups), then the pre-existing self-review/migration gates, then Gate 2
# last, immediately before the `gh pr merge` call (so a PR any earlier gate
# would refuse anyway never sits through ci-wait.sh's full timeout first,
# and the window between "CI confirmed green" and the actual merge stays as
# narrow as possible):
#   Gate 0 (authorship)  scripts/check-coordinator-authorship.sh <N> — refuse
#                         if any head-only commit carries a
#                         `Swarm-Role: coordinator` git trailer. The
#                         coordinator must never auto-merge a PR it authored
#                         itself (#452, carved from #450 finding 4:
#                         corpusminder-spring PR #713 was coordinator-
#                         authored and coordinator-merged with no authorship
#                         check at all). No override flag exists for this
#                         gate — a coordinator-authored PR always goes to
#                         the operator; a human can still merge it by hand
#                         with a plain `swarm-merge.sh <N>` (no --auto-low).
#                         Note: this only catches a commit that was actually
#                         stamped with the trailer — it protects future
#                         coordinator commits, not commits that predate the
#                         convention (PR #713 itself wouldn't have carried
#                         it; Gate 2 below is what would have caught that
#                         specific incident).
#   Gate 1 (rating marker) body contains the exact marker
#                         `<!-- BLIND_MERGE_RISK: low -->`. Absent, or any
#                         other value (medium/high/malformed) → refused.
#   Gate 2 (CI wait)      scripts/ci-wait.sh <N> — a real bounded poll of
#                         `gh pr checks` to a concluded state, replacing the
#                         old `gh pr merge --auto` prescription, which
#                         merged immediately because these repos have no
#                         branch protection for --auto to defer to. A repo
#                         with NO CI checks configured at all (ci-wait.sh
#                         exit 5) is treated as pass-with-a-loud-warning, not
#                         a refusal — logged as a `merge.gate` event noting
#                         the CI absence — because "no checks exist" is not
#                         evidence of a failure, and refusing here would
#                         silently strand every CI-less project's auto-merge
#                         path and point whoever investigates at the wrong
#                         culprit.
#   Gate 3 (review decision) `gh pr view`'s `reviewDecision` is not
#                         `CHANGES_REQUESTED`.
#   Gate 4 (base branch)  `baseRefName` matches the repo's resolved default
#                         branch (`origin/HEAD`, falling back to `main`/
#                         `master`). Never auto-merges feature-to-feature.
#   Gate 5 (draft)        `isDraft` is false.
#
# --auto-low also refuses outright (usage error, before any gate runs) if
# combined with --override-review or --override-migration-gate: the
# unattended path must never accept an override flag — those exist for a
# human who has read the PR and disagrees with a gate, which is precisely
# the judgment --auto-low is not allowed to make on its own.
#
# Pass the PR number. It is the unambiguous handle: an issue can have no
# closing-keyword PR (a worker that split its work and wrote "steps 1-2 of
# #N" instead of "Closes #N"), or several.
#
# Closing the issue is GitHub's job, not this script's: a squash merge to the
# default branch closes every issue the PR body names with a closing keyword
# (Closes/Fixes/Resolves #N). After merging, the script reports whether the
# worker's issue is among them; when it isn't, the issue stays OPEN on
# purpose (partial work) and the script says so with the `gh issue close`
# command to run if the work is in fact complete. It never closes it itself.
#
# What it does:
#   1. Resolves the given number as either an issue or a PR (GitHub shares
#      one numbering sequence, so #N is exactly one object). Given an issue,
#      resolves its linked PR: the closing-keyword PR first, else the single
#      open PR on the worker's `fix/issue-N` branch. Given a PR,
#      walks back to its linked issue so the issue-keyed cleanup below
#      (tmux window, worktree, branch sweep) still knows what to clean —
#      if the PR has no linked issue, the merge proceeds but that cleanup
#      is skipped (and said so explicitly) rather than silently no-opped.
#   2a. Housekeeping-only mode (#368): an issue can reach "closed, nothing to
#      merge, but the worker's mess is still on disk" — closed by another
#      PR's work, PR closed unmerged and redone elsewhere, or closed by hand.
#      When there is no PR to merge but the issue is CLOSED, steps 3-4 are
#      skipped and steps 5-6 (worktree/tmux reap, branch sweep)
#      run as normal: they are keyed on the issue, not the PR, and are valid
#      on their own. An OPEN issue still refuses, on the same reasoning
#      run_sweep uses — an OPEN issue is an in-flight worker, and reaping it
#      would destroy uncommitted work. --force-cleanup overrides that for a
#      worker known to be dead.
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
#   4. Runs `gh pr merge --squash` — deliberately WITHOUT --delete-branch
#      (issue #489): gh >= 2.100 implements that flag's local-delete step by
#      first running `git worktree remove` on whichever linked worktree has
#      the branch checked out, i.e. the live worker's worktree, bypassing
#      kill-worktree.sh's salvage and event logging entirely (fand-etl
#      2026-09-28 lost two incident-evidence files this way). The REMOTE
#      branch is deleted explicitly right after the merge instead; the
#      local branch is the reaper's job (step 7 / kill-worktree.sh).
#   5. Reaps the worker immediately (issue #465): calls kill-worktree.sh <N>
#      right here rather than waiting up to 60s for the watcher's own
#      WATCH_PR_POLL_SECS backstop to notice — same script the watcher uses
#      (kill-finished-workers.sh --with-worktree), so brief salvage
#      (queued inbox/processing/outbox files), the .swarm/.local-data
#      archive, and the reap.worktree event all still happen. --no-kill
#      skips this step entirely, same semantics as before. A deferred
#      (exit 75, in-flight check-claim) or refused (exit 76, non-empty
#      inbox with SWARM_REAP_INBOX=refuse) result is reported and left for
#      the watcher's own backstop to retry; a real failure (any other
#      nonzero exit) is reported as a warning rather than failing the
#      script — the merge itself already succeeded. The watcher's
#      subsequent PR-poll tick finds the worktree already gone
#      (pr_poll_pass's own is_own_worktree_dir check) and skips silently,
#      never re-reaping or posting an orphan comment.
#   6. Runs the SAFER local-branch sweep: deletes `fix/issue-N` only when GitHub
#      issue N's state is CLOSED. (Never deletes branches for OPEN issues, so
#      in-flight workers stay safe.) One `gh issue list` call covers every
#      local fix/issue-* branch, not one `gh issue view` per branch.
#   7. Reports final state.
#
# Exits 0 on success, non-zero on bailout.

set -euo pipefail

NO_KILL=0
SWEEP_ONLY=0
OVERRIDE_REVIEW=0
OVERRIDE_MIGRATION_GATE=0
FORCE_CLEANUP=0
HOUSEKEEP_ONLY=0
AUTO_LOW=0
ISSUE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- arg parsing -----------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --no-kill)    NO_KILL=1 ;;
    --sweep-only) SWEEP_ONLY=1 ;;
    --override-review) OVERRIDE_REVIEW=1 ;;
    --override-migration-gate) OVERRIDE_MIGRATION_GATE=1 ;;
    --force-cleanup) FORCE_CLEANUP=1 ;;
    --auto-low)  AUTO_LOW=1 ;;
    --squash)    ;;   # no-op: squash is the only mode this script implements
    --merge|--rebase)
      echo "ERROR: swarm-merge.sh always squashes; $arg is not supported" >&2
      exit 2
      ;;
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

# --auto-low is the coordinator's unattended path; it must never accept an
# override flag — those exist for a human who read the PR and disagrees
# with a specific gate, a judgment call --auto-low doesn't get to make.
if [ "$AUTO_LOW" = 1 ] && { [ "$OVERRIDE_REVIEW" = 1 ] || [ "$OVERRIDE_MIGRATION_GATE" = 1 ]; }; then
  echo "ERROR: --auto-low may not be combined with --override-review or" >&2
  echo "       --override-migration-gate. The unattended path must not accept" >&2
  echo "       overrides — re-run without --auto-low if a human is making this call." >&2
  exit 2
fi

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

# --- housekeeping-only decision (#368) ------------------------------------
#
# Called when there is nothing to merge. Steps 5-6 are keyed on the issue and
# stand on their own, so the absence of a PR is not a reason to abandon the
# worker's tmux window and worktree to a manual cleanup.
#
# The guard is the one run_sweep already applies to branches: an OPEN issue is
# an in-flight worker. Reaping its window and force-removing its worktree
# would destroy uncommitted work, so that case still refuses.
housekeep_or_die() {
  local reason="$1" state
  state=$(gh issue view "$ISSUE" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [ "$state" = "CLOSED" ]; then
    echo "       $(c_amber "$reason; issue #$ISSUE is CLOSED — housekeeping only, nothing to merge")"
  elif [ "$FORCE_CLEANUP" = 1 ]; then
    echo "       $(c_amber "$reason; issue #$ISSUE is $state but --force-cleanup given — housekeeping anyway")"
  else
    echo "ERROR: $reason, and issue #$ISSUE is $state." >&2
    echo "       An issue that is not CLOSED with nothing merged usually means the" >&2
    echo "       worker is still in flight; reaping its window and worktree now" >&2
    echo "       would destroy uncommitted work." >&2
    echo "       Re-run with --force-cleanup if you know the worker is dead." >&2
    echo "       If the work has a PR, pass the PR number instead: $0 <PR#>" >&2
    exit 1
  fi
  HOUSEKEEP_ONLY=1
}

# --- issue -> PR resolution -------------------------------------------------
#
# Closing-keyword link first (the pre-#324 behavior). When there is none, fall
# back to the single OPEN PR on the worker's own fix/issue-N branch: a worker
# that split its work writes "steps 1-2 of #N" rather than "Closes #N", so
# GitHub records no closing link and the issue path used to refuse a PR that
# plainly exists (fand-etl #1133 / PR #1138, 2026-10-06). More than one open
# PR on that branch is ambiguous, so it refuses and asks for the PR number.
# Sets PR_NUM (empty when nothing is found) and PR_VIA (how it was found).
resolve_pr_for_issue() {
  local branch_prs count
  PR_VIA=""
  PR_NUM=$(gh issue view "$ISSUE" --json closedByPullRequestsReferences \
             -q '.closedByPullRequestsReferences[0].number' 2>/dev/null || echo "")
  [ "$PR_NUM" = "null" ] && PR_NUM=""
  if [ -n "$PR_NUM" ]; then
    PR_VIA="closing keyword"
    return 0
  fi
  branch_prs=$(gh pr list --head "fix/issue-$ISSUE" --state open --json number \
                 -q '.[].number' 2>/dev/null || echo "")
  count=$(printf '%s\n' "$branch_prs" | grep -c '^[0-9][0-9]*$' || true)
  if [ "$count" = 1 ]; then
    PR_NUM="$branch_prs"
    PR_VIA="open PR on branch fix/issue-$ISSUE"
  elif [ "$count" -gt 1 ]; then
    echo "ERROR: issue #$ISSUE has no closing-keyword PR and $count open PRs on" >&2
    echo "       branch fix/issue-$ISSUE ($(echo "$branch_prs" | tr '\n' ' ')). Pass the PR number." >&2
    exit 1
  fi
}

# The repo's default branch from origin/HEAD, else origin/main or
# origin/master; empty if none resolves.
resolve_default_branch() {
  local b
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  b="${b#origin/}"
  if [ -z "$b" ]; then
    for candidate in main master; do
      git show-ref --verify --quiet "refs/remotes/origin/$candidate" &&
        b="$candidate" && break
    done
  fi
  echo "$b"
}

# After a merge: say whether GitHub closes the worker's issue. GitHub closes
# issues named by a closing keyword in the PR body, and only when the PR
# merges into the default branch; this script never closes one itself,
# because a PR without the keyword is often deliberate partial work.
report_issue_closure() {
  local closing others default_branch
  default_branch="$(resolve_default_branch)"
  if [ -n "$PR_BASE" ] && [ -n "$default_branch" ] && [ "$PR_BASE" != "$default_branch" ]; then
    echo "       $(c_amber "issue #$ISSUE stays OPEN: PR #$PR_NUM merged into '$PR_BASE', not '$default_branch'; GitHub closes issues only on merges into the default branch.")"
    echo "       Once the work reaches $default_branch: gh issue close $ISSUE --comment \"Done in #$PR_NUM\""
    return 0
  fi
  closing=" $(echo "$PR_JSON" | jq -r '[(.closingIssuesReferences // [])[].number | tostring] | join(" ")' 2>/dev/null || true) "
  if [[ "$closing" == *" $ISSUE "* ]]; then
    echo "       issue #$ISSUE: GitHub closes it (PR #$PR_NUM names it with a closing keyword)"
  else
    echo "       $(c_amber "issue #$ISSUE stays OPEN: PR #$PR_NUM has no closing keyword for it (partial work, or the keyword was left out).")"
    echo "       If the work is complete: gh issue close $ISSUE --comment \"Done in #$PR_NUM\""
  fi
  others=$(echo "$closing" | tr ' ' '\n' | grep -vx "$ISSUE" | grep . | sed 's/^/#/' | tr '\n' ' ' || true)
  [ -n "$others" ] && echo "       GitHub also closes: $others"
  return 0
}

# --- safer local-branch sweep ---------------------------------------------
#
# For each local `fix/issue-N` branch, look up issue N's state on GitHub.
# Delete the branch ONLY if the issue state is CLOSED.
# This is safer than the "remote branch absent" heuristic because a
# freshly-provisioned worker that hasn't pushed yet has an OPEN issue and
# no remote branch — we never want to delete those.
#
# issue #465: used to make one `gh issue view <num>` round-trip per branch.
# Instead, make exactly one `gh issue list --state all` call up front and
# match branch numbers against it locally — a single GitHub call regardless
# of how many fix/issue-* branches are lying around. SWARM_SWEEP_ISSUE_LIMIT
# (default 1000) bounds that one call; an issue number missing from the
# listing (beyond the limit, or genuinely gone) falls back to the same
# UNKNOWN/skip behavior a failed `gh issue view` used to produce — never
# delete unless CLOSED is confirmed.
run_sweep() {
  echo "[sweep] scanning local fix/issue-* branches…"
  local deleted=0 kept_open=0 skipped=0
  local branches
  branches="$(git branch --format='%(refname:short)' | grep -E '^fix/issue-[0-9]+' || true)"
  if [ -z "$branches" ]; then
    echo "[sweep] deleted=0, kept_open=0, skipped=0"
    return 0
  fi

  local issue_json
  issue_json="$(gh issue list --state all --json number,state \
                  --limit "${SWARM_SWEEP_ISSUE_LIMIT:-1000}" 2>/dev/null || echo '[]')"
  [ -n "$issue_json" ] || issue_json='[]'

  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    # Branch name may have a suffix (e.g. fix/issue-118-cluster-a); keep the full
    # name for deletion, but extract just the leading issue number for lookup.
    local num state
    num=$(echo "$b" | grep -oE '^fix/issue-[0-9]+' | sed 's|^fix/issue-||')
    state=$(echo "$issue_json" | jq -r --arg n "$num" \
              '([.[] | select(.number == ($n|tonumber)) | .state])[0] // "UNKNOWN"' 2>/dev/null)
    [ -n "$state" ] || state="UNKNOWN"
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
  done <<< "$branches"
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
  echo "ERROR: PR# (or issue#) required (or use --sweep-only)" >&2
  echo "Usage: $0 <PR#|issue#> [--no-kill]" >&2
  exit 2
fi

# Sanity: in a git repo?
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repo" >&2; exit 1; }

# cd to main worktree so gh pr merge's local-pull step has the right cwd.
MAIN_WT=$(main_worktree)
cd "$MAIN_WT"
echo "[1/6] working in main worktree: $MAIN_WT"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/_load-env.sh" "$MAIN_WT"

# issue #465: swarm-merge.sh no longer removes the worktree itself (see
# step 5 below, which now calls kill-worktree.sh directly) — but Gate 2's
# no-checks-configured pass-with-warning below still logs a merge.gate
# event, so EVENTS_LOG/log_event stay here for that one caller.
EVENTS_LOG="$MAIN_WT/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

# Resolve the given number as either an issue or a PR — GitHub shares one
# numbering sequence, so #N is exactly one object and this is unambiguous.
INPUT_NUM="$ISSUE"
ISSUE=""
PR_NUM=""

IS_PR=$(gh api "repos/{owner}/{repo}/issues/$INPUT_NUM" --jq '.pull_request != null' 2>/dev/null || echo "")

if [ "$IS_PR" = "true" ]; then
  PR_NUM="$INPUT_NUM"
  echo "[2/6] #$INPUT_NUM is PR #$PR_NUM"
elif [ "$IS_PR" = "false" ]; then
  ISSUE="$INPUT_NUM"
  resolve_pr_for_issue
  if [ -z "$PR_NUM" ]; then
    housekeep_or_die "no linked PR found for issue #$ISSUE"
  else
    echo "[2/6] issue #$ISSUE → PR #$PR_NUM (via $PR_VIA)"
  fi
else
  # The probe itself failed (rate limit, transient network, expired auth) —
  # distinct from a clean "false" (definitely an issue). Rather than treat
  # that the same as "definitely not a PR" and abort, retry classification
  # directly against both endpoints before giving up. Issue-first, since
  # that's the pre-#324 path every existing invocation relied on; PR second,
  # so a flaky probe doesn't regress #324's own PR-number case either.
  echo "       $(c_amber "⚠ could not classify #$INPUT_NUM via gh api (transient failure?) — trying issue and PR lookups directly")"
  ISSUE="$INPUT_NUM"
  resolve_pr_for_issue
  if [ -n "$PR_NUM" ]; then
    echo "[2/6] issue #$ISSUE → PR #$PR_NUM (via $PR_VIA; resolved via fallback)"
  elif gh pr view "$INPUT_NUM" --json number >/dev/null 2>&1; then
    ISSUE=""
    PR_NUM="$INPUT_NUM"
    echo "[2/6] #$INPUT_NUM resolved directly as PR #$PR_NUM (resolved via fallback)"
  elif [ -n "$(gh issue view "$INPUT_NUM" --json number -q .number 2>/dev/null)" ]; then
    # It is a real issue with no linked PR. Same housekeeping case as above,
    # reached through the degraded-classification path.
    # Require the number to come *back*, not merely a zero exit: in this
    # branch `gh` is already known to be behaving oddly (the classification
    # probe just failed), and a success with no output is not evidence the
    # issue exists. Same rigor the PR_NUM checks above apply.
    PR_NUM=""
    housekeep_or_die "no linked PR found for issue #$ISSUE"
  else
    echo "ERROR: could not resolve #$INPUT_NUM as an issue or PR (gh api classification failed, and neither an issue nor PR lookup succeeded)" >&2
    exit 1
  fi
fi

if [ "$HOUSEKEEP_ONLY" = 0 ]; then
  # Inspect PR state.
  PR_JSON=$(gh pr view "$PR_NUM" --json state,mergeable,mergeStateStatus,headRefName,title,closingIssuesReferences,body,isDraft,reviewDecision,baseRefName)
  PR_STATE=$(echo "$PR_JSON" | jq -r .state)
  PR_MERGEABLE=$(echo "$PR_JSON" | jq -r .mergeable)
  PR_MERGE_STATE_STATUS=$(echo "$PR_JSON" | jq -r '.mergeStateStatus // ""')
  PR_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
  PR_TITLE=$(echo "$PR_JSON" | jq -r .title)
  PR_BODY=$(echo "$PR_JSON" | jq -r '.body // ""')
  PR_IS_DRAFT=$(echo "$PR_JSON" | jq -r '.isDraft // false')
  PR_REVIEW_DECISION=$(echo "$PR_JSON" | jq -r '.reviewDecision // ""')
  PR_BASE=$(echo "$PR_JSON" | jq -r '.baseRefName // ""')
  echo "[3/6] PR #$PR_NUM: state=$PR_STATE mergeable=$PR_MERGEABLE branch=$PR_BRANCH"
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
      # Pre-merge gate (#492): mergeStateStatus DIRTY means GitHub has already
      # finished recomputing real conflicts against the base branch. This is
      # a cheap opportunistic check, not a guaranteed catch of the incident's
      # race: GitHub computes `mergeable`/`mergeStateStatus` together in a
      # background job, so immediately after a sibling PR in the same batch
      # merges, both fields can still read UNKNOWN here while that job is
      # in flight — the gate simply won't fire in that window, and the PR
      # falls through to the real `gh pr merge` attempt below. What actually
      # fails closed on the incident's failure mode regardless of that race
      # is the CONFLICTING check just above plus the post-refusal re-query
      # after the real merge attempt (both below); this gate only saves the
      # cost of gates/CI-wait/merge when GitHub happens to have already
      # settled on DIRTY by the time we ask.
      if [ "$PR_MERGE_STATE_STATUS" = "DIRTY" ]; then
        echo "ERROR: PR #$PR_NUM is not mergeable (mergeStateStatus=DIRTY)." >&2
        echo "       Rebase onto the default branch and retry." >&2
        exit 1
      fi
      # --auto-low Gate 0 (#452): authorship, hard and non-overridable. Only
      # active on the coordinator's unattended SWARM_AUTOMERGE_LOW path; a
      # plain `swarm-merge.sh <N>` skips it. Checked here, first and cheap,
      # before anything that costs real wall-clock time below.
      if [ "$AUTO_LOW" = 1 ]; then
        echo "       auto-low gate 0 (authorship): checking…"
        AUTH_RC=0
        "$SCRIPT_DIR/check-coordinator-authorship.sh" "$PR_NUM" || AUTH_RC=$?
        if [ "$AUTH_RC" = 1 ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 0 (authorship)." >&2
          echo "       This PR carries a coordinator-authored commit and must go to" >&2
          echo "       the operator — there is no override for this gate. A human can" >&2
          echo "       still merge it directly: swarm-merge.sh $PR_NUM (no --auto-low)." >&2
          exit 1
        elif [ "$AUTH_RC" != 0 ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 0 (authorship, exit $AUTH_RC)." >&2
          echo "       check-coordinator-authorship.sh errored rather than returning a clean" >&2
          echo "       verdict (see its output above) — failing closed, not eligible." >&2
          exit 1
        fi

        # --auto-low Gates 1, 3, 4, 5 (#454 follow-up to #452): cheap,
        # non-overridable checks off the same PR_JSON fetch above — no extra
        # `gh` calls. Matches prompts/coordinator.md's 8-gate list; gates 6
        # (diff-scope read) and 7 (migration collision, pre-existing below)
        # aren't repeated here.
        echo "       auto-low gate 1 (rating marker): checking…"
        # Self-review finding on this PR: an unanchored substring grep for
        # the exact low marker also matches a PR whose body merely quotes
        # that marker in prose elsewhere (e.g. this PR's own Follow-up/
        # Findings sections, while its real top-of-body marker is medium) —
        # a mis-rated PR would still clear this gate. The convention is the
        # marker lives as the FIRST `<!-- BLIND_MERGE_RISK: ... -->` HTML
        # comment in the body (prompts/worker.md "PR risk assessment"); take
        # only that one, whatever rating it names, not any later mention.
        # Two self-review rounds narrowed this down to "match on the token,
        # not on any part of the expected format": matching on a pattern
        # anchored to `<!-- BLIND_MERGE_RISK: ... -->` (spaces, comment
        # delimiters, or a restrictive value class) lets a first marker that
        # deviates from that exact shape (e.g. `<!--BLIND_MERGE_RISK:
        # medium-->`, no interior spaces) get skipped over in favor of a
        # later, well-formed mention elsewhere in the body — the same
        # "wrong occurrence wins" bug in a new costume each time. Instead:
        # take the first LINE containing the literal token `BLIND_MERGE_RISK`
        # at all, trim it, and exact-compare THAT against the canonical
        # marker — a malformed first marker then simply fails the exact
        # match (refused) rather than being invisible to the search.
        RATING_MARKER="$(grep -m1 -- 'BLIND_MERGE_RISK' <<<"$PR_BODY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
        if [ "$RATING_MARKER" != "<!-- BLIND_MERGE_RISK: low -->" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 1 (rating marker)." >&2
          echo "       First '<!-- BLIND_MERGE_RISK: ... -->' marker in the body is" >&2
          echo "       '${RATING_MARKER:-<absent>}', not the exact low marker — not" >&2
          echo "       eligible for unattended merge." >&2
          exit 1
        fi

        echo "       auto-low gate 3 (review decision): checking…"
        if [ "$PR_REVIEW_DECISION" = "CHANGES_REQUESTED" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 3 (review decision)." >&2
          echo "       reviewDecision is CHANGES_REQUESTED — not eligible for unattended merge." >&2
          exit 1
        fi

        echo "       auto-low gate 4 (base branch): checking…"
        DEFAULT_BRANCH="$(resolve_default_branch)"
        if [ -z "$DEFAULT_BRANCH" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 4 (base branch)." >&2
          echo "       Could not resolve the repo's default branch to compare against —" >&2
          echo "       failing closed rather than guessing." >&2
          exit 1
        fi
        if [ "$PR_BASE" != "$DEFAULT_BRANCH" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 4 (base branch)." >&2
          echo "       base is '$PR_BASE', default branch is '$DEFAULT_BRANCH' — never" >&2
          echo "       auto-merge feature-to-feature." >&2
          exit 1
        fi

        echo "       auto-low gate 5 (draft): checking…"
        if [ "$PR_IS_DRAFT" = "true" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 5 (draft)." >&2
          echo "       PR is still a draft — not eligible for unattended merge." >&2
          exit 1
        fi
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
      # --auto-low Gate 2 (#452): a real CI wait, hard and non-overridable.
      # Deliberately last, right before the merge call — the self-review and
      # migration gates above are cheap, already-decided lookups (an instant
      # BLOCK verdict or Flyway collision), so a PR that's going to be
      # refused anyway is refused before burning ci-wait.sh's full timeout,
      # and the window between "CI confirmed green" and the actual merge
      # stays as narrow as possible.
      if [ "$AUTO_LOW" = 1 ]; then
        echo "       auto-low gate 2 (CI wait): waiting for a real conclusion…"
        CI_RC=0
        "$SCRIPT_DIR/ci-wait.sh" "$PR_NUM" || CI_RC=$?
        if [ "$CI_RC" = 5 ]; then
          # No CI checks configured on this repo at all — pass-with-warning,
          # not a refusal (see the Gate 2 note in the header comment above).
          echo "       $(c_amber "⚠ auto-low gate 2: no CI checks configured on this repo — proceeding (pass-with-warning)")"
          log_event merge.gate "pr=$PR_NUM gate=2-ci-wait result=no-checks-configured action=proceed"
        elif [ "$CI_RC" != 0 ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-low Gate 2 (CI wait, exit $CI_RC)." >&2
          echo "       See ci-wait.sh's output above for which case fired (red checks," >&2
          echo "       timeout, or CONFLICTING/DIRTY needing a rebase)." >&2
          exit 1
        fi
      fi
      echo "[4/6] merging PR #$PR_NUM (squash)…"
      # issue #489: never --delete-branch here. On gh >= 2.100 its
      # local-delete step removes the linked worktree that has the branch
      # checked out — the live worker's worktree — with no salvage and no
      # reap.worktree event. Delete the remote branch ourselves instead;
      # the local branch is deleted by kill-worktree.sh / the step-7 sweep.
      MERGE_RC=0
      gh pr merge "$PR_NUM" --squash || MERGE_RC=$?
      if [ "$MERGE_RC" != 0 ]; then
        # issue #492: a nonzero exit here used to be swallowed unconditionally
        # (the old --delete-branch local-delete step could fail harmlessly
        # even on a real merge). Re-query the PR's actual state instead of
        # guessing from the exit code: only a confirmed MERGED state excuses
        # the failure now that --delete-branch is gone (issue #489) and the
        # local-delete case it was written for no longer exists on this path.
        #
        # The re-query itself can fail or come back empty (gh transient
        # error, auth expiry, rate limit) — that must fail closed exactly
        # like a confirmed-still-OPEN state, but with its own wording: we
        # genuinely don't know the PR's state, so don't claim "OPEN" and
        # don't suggest a rebase (issue #499 caveat 1/3).
        POST_RC=0
        POST_JSON=$(gh pr view "$PR_NUM" --json state,mergeable,mergeStateStatus 2>/dev/null) || POST_RC=$?
        POST_STATE=""
        POST_MERGEABLE=""
        POST_MSS=""
        if [ "$POST_RC" = 0 ] && [ -n "$POST_JSON" ]; then
          POST_STATE=$(echo "$POST_JSON" | jq -r '.state // ""' 2>/dev/null || true)
          POST_MERGEABLE=$(echo "$POST_JSON" | jq -r '.mergeable // ""' 2>/dev/null || true)
          POST_MSS=$(echo "$POST_JSON" | jq -r '.mergeStateStatus // ""' 2>/dev/null || true)
        fi
        if [ "$POST_STATE" != "MERGED" ]; then
          echo "ERROR: gh pr merge refused PR #$PR_NUM (exit $MERGE_RC) — nothing merged, skipping cleanup." >&2
          if [ -z "$POST_STATE" ]; then
            # (b) re-query itself failed, or came back without a usable
            # state — genuinely unknown, not "confirmed OPEN". Never suggest
            # rebase here: we have no evidence of a conflict, only a second
            # failure on top of the first.
            echo "       Could not confirm PR #$PR_NUM's real state afterward" >&2
            echo "       (re-query exit=$POST_RC, state=UNKNOWN) — this does NOT mean the PR" >&2
            echo "       is still open, only that we can't tell. Check it by hand" >&2
            echo "       (gh pr view $PR_NUM) before retrying." >&2
          elif [ "$POST_MERGEABLE" = "CONFLICTING" ] || [ "$POST_MSS" = "DIRTY" ]; then
            # (a) confirmed open, and the refusal is a real conflict.
            echo "       PR #$PR_NUM is confirmed state=$POST_STATE with a real conflict" >&2
            echo "       (mergeable=$POST_MERGEABLE, mergeStateStatus=$POST_MSS)." >&2
            echo "       Rebase onto the default branch and retry." >&2
          else
            # (a) confirmed open, but nothing indicates a conflict — the
            # refusal is more likely auth, network, or branch protection.
            # Rebasing won't fix those, so don't tell the operator it will.
            echo "       PR #$PR_NUM is confirmed state=$POST_STATE" \
                 "(mergeable=${POST_MERGEABLE:-UNKNOWN}, mergeStateStatus=${POST_MSS:-UNKNOWN})," >&2
            echo "       and nothing here indicates a merge conflict — the refusal is more" >&2
            echo "       likely auth, network, or branch protection. Investigate why" >&2
            echo "       gh pr merge exited $MERGE_RC before retrying; a rebase may not help." >&2
          fi
          exit 1
        fi
        echo "       $(c_amber "⚠ gh pr merge exited $MERGE_RC but PR #$PR_NUM is confirmed MERGED — proceeding")"
      fi
      if git push origin --delete "$PR_BRANCH" >/dev/null 2>&1; then
        echo "       deleted remote branch origin/$PR_BRANCH"
      else
        echo "       (remote branch origin/$PR_BRANCH not deleted — already gone, or repo auto-deletes head branches)"
      fi
      ;;
    MERGED)
      echo "[4/6] PR #$PR_NUM already MERGED — proceeding to cleanup"
      ;;
    CLOSED)
      # Not "nothing to do": the PR is dead but the worker's tmux window and
      # worktree are still on disk, and that is precisely what steps 5-6 clean.
      if [ -n "$ISSUE" ]; then
        housekeep_or_die "PR #$PR_NUM is CLOSED (not merged)"
      else
        echo "ERROR: PR #$PR_NUM is CLOSED (not merged) and has no linked issue," >&2
        echo "       so there are no issue-keyed artifacts to clean up." >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: PR #$PR_NUM in unexpected state: $PR_STATE" >&2
      exit 1
      ;;
  esac
else
  # Housekeeping-only: no PR exists, so there is nothing to inspect or gate.
  # Steps 5-6 below are keyed on $ISSUE and run exactly as they would after a
  # normal merge.
  echo "[3/6] no PR to inspect for issue #$ISSUE"
  echo "[4/6] nothing to merge — housekeeping only"
fi

if [ -n "$ISSUE" ]; then
  if [ "$NO_KILL" = 1 ]; then
    echo "[5/6] --no-kill set; leaving tmux window / worktree alone"
  else
    # issue #465: reap right now instead of waiting up to 60s for the
    # watcher's own WATCH_PR_POLL_SECS backstop to notice this merge.
    # kill-worktree.sh is the SAME reaper the watcher uses
    # (kill-finished-workers.sh --with-worktree calls it per target), so
    # brief salvage (queued inbox/processing/outbox files), the
    # .swarm/.local-data archive, and the reap.worktree event logging all
    # still happen exactly as they would for a watcher-driven reap.
    echo "[5/6] reaping worktree + tmux window for issue #$ISSUE…"
    KILL_RC=0
    "$SCRIPT_DIR/kill-worktree.sh" "$ISSUE" "$MAIN_WT" || KILL_RC=$?
    case "$KILL_RC" in
      0) echo "       reaped ✓" ;;
      75)
        echo "       $(c_amber "⚠ kill-worktree.sh deferred (in-flight check-claim) — worktree left in place, watcher's own backstop will retry")"
        ;;
      76)
        echo "       $(c_amber "⚠ kill-worktree.sh refused (non-empty inbox, SWARM_REAP_INBOX=refuse) — worktree left in place")"
        ;;
      *)
        echo "       $(c_amber "⚠ kill-worktree.sh exited $KILL_RC — see its output above; worktree/window may still be present")"
        ;;
    esac
  fi
else
  echo "[5/6] no linked issue for PR #$PR_NUM — skipping tmux/worktree reap"
fi

# Run the safer local-branch sweep.
echo "[6/6] running local-branch sweep…"
run_sweep

echo
if [ "$HOUSEKEEP_ONLY" = 1 ]; then
  if [ -n "$PR_NUM" ]; then
    echo "$(c_green "Done.") Housekeeping complete for issue #$ISSUE (PR #$PR_NUM was not merged)."
  else
    echo "$(c_green "Done.") Housekeeping complete for issue #$ISSUE (no PR; nothing merged)."
  fi
elif [ -n "$ISSUE" ]; then
  echo "$(c_green "Done.") PR #$PR_NUM merged for issue #$ISSUE."
  report_issue_closure
else
  echo "$(c_green "Done.") PR #$PR_NUM merged (no linked issue)."
fi
