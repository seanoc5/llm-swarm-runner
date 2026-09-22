#!/usr/bin/env bash
# swarm-merge.sh — merge a swarm PR and clean up the local mess.
#
# Usage:
#   swarm-merge.sh <issue#|PR#>       # resolves PR from issue (or issue from
#                                      # PR), merges, cleans
#   swarm-merge.sh <issue#|PR#> --no-kill # skip the tmux-kill step
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
# What it does:
#   1. Resolves the given number as either an issue or a PR (GitHub shares
#      one numbering sequence, so #N is exactly one object). Given an issue,
#      resolves its linked PR (unchanged pre-#324 behavior). Given a PR,
#      walks back to its linked issue so the issue-keyed cleanup below
#      (tmux window, worktree, branch sweep) still knows what to clean —
#      if the PR has no linked issue, the merge proceeds but that cleanup
#      is skipped (and said so explicitly) rather than silently no-opped.
#   2a. Housekeeping-only mode (#368): an issue can reach "closed, nothing to
#      merge, but the worker's mess is still on disk" — closed by another
#      PR's work, PR closed unmerged and redone elsewhere, or closed by hand.
#      When there is no PR to merge but the issue is CLOSED, steps 3-4 are
#      skipped and steps 5-7 (reap wait, tmux/worktree kill, branch sweep)
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
# Called when there is nothing to merge. Steps 5-7 are keyed on the issue and
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
    exit 1
  fi
  HOUSEKEEP_ONLY=1
}

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

# issue #439 self-review finding: the fallback worktree removal below (when
# the watcher hasn't reaped within GRACE_SECONDS) used to call `git worktree
# remove` directly, bypassing kill-worktree.sh entirely — which meant
# coordinator-watch.sh's worktree_vanish_sweep_pass would flag every such
# fallback removal as an unblessed disappearance. Same EVENTS_LOG/log_event
# shape as kill-worktree.sh/kill-finished-workers.sh.
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
  echo "[2/7] #$INPUT_NUM is PR #$PR_NUM"
elif [ "$IS_PR" = "false" ]; then
  ISSUE="$INPUT_NUM"
  PR_NUM=$(gh issue view "$ISSUE" --json closedByPullRequestsReferences \
             -q '.closedByPullRequestsReferences[0].number' 2>/dev/null || echo "")
  if [ -z "$PR_NUM" ] || [ "$PR_NUM" = "null" ]; then
    PR_NUM=""
    housekeep_or_die "no linked PR found for issue #$ISSUE"
  else
    echo "[2/7] issue #$ISSUE → PR #$PR_NUM"
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
  PR_NUM=$(gh issue view "$ISSUE" --json closedByPullRequestsReferences \
             -q '.closedByPullRequestsReferences[0].number' 2>/dev/null || echo "")
  if [ -n "$PR_NUM" ] && [ "$PR_NUM" != "null" ]; then
    echo "[2/7] issue #$ISSUE → PR #$PR_NUM (resolved via fallback)"
  elif gh pr view "$INPUT_NUM" --json number >/dev/null 2>&1; then
    ISSUE=""
    PR_NUM="$INPUT_NUM"
    echo "[2/7] #$INPUT_NUM resolved directly as PR #$PR_NUM (resolved via fallback)"
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
  PR_JSON=$(gh pr view "$PR_NUM" --json state,mergeable,headRefName,title,closingIssuesReferences,body,isDraft,reviewDecision,baseRefName)
  PR_STATE=$(echo "$PR_JSON" | jq -r .state)
  PR_MERGEABLE=$(echo "$PR_JSON" | jq -r .mergeable)
  PR_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
  PR_TITLE=$(echo "$PR_JSON" | jq -r .title)
  PR_BODY=$(echo "$PR_JSON" | jq -r '.body // ""')
  PR_IS_DRAFT=$(echo "$PR_JSON" | jq -r '.isDraft // false')
  PR_REVIEW_DECISION=$(echo "$PR_JSON" | jq -r '.reviewDecision // ""')
  PR_BASE=$(echo "$PR_JSON" | jq -r '.baseRefName // ""')
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
        # The capture uses [^>]* (not [a-z]+) deliberately: a restrictive
        # class would let a malformed/uppercase first marker (which should
        # fail the exact-match check below) get skipped over in favor of a
        # later, correctly-lowercase mention elsewhere in the body — the
        # same "wrong occurrence wins" bug this fix exists to close.
        RATING_MARKER="$(grep -m1 -oE -- '<!-- BLIND_MERGE_RISK: [^>]* -->' <<<"$PR_BODY" || true)"
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
        DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
        if [ -z "$DEFAULT_BRANCH" ]; then
          for candidate in main master; do
            git show-ref --verify --quiet "refs/remotes/origin/$candidate" &&
              DEFAULT_BRANCH="$candidate" && break
          done
        fi
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
      # Not "nothing to do": the PR is dead but the worker's tmux window and
      # worktree are still on disk, and that is precisely what steps 5-7 clean.
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
  # Steps 5-7 below are keyed on $ISSUE and run exactly as they would after a
  # normal merge.
  echo "[3/7] no PR to inspect for issue #$ISSUE"
  echo "[4/7] nothing to merge — housekeeping only"
fi

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
      # issue #446 self-review: logged AFTER a successful removal, not
      # before — see kill-worktree.sh's matching comment for why the
      # earlier before-removal ordering (issue #439 round 4) traded a rare
      # sweep false positive for a real false negative (a failed removal
      # still getting a blessed event). The same reap.worktree event
      # kill-worktree.sh logs on removal, so this fallback path isn't
      # mistaken for an unblessed `git worktree remove` by the watcher's
      # vanish sweep — but only when the removal actually succeeded.
      if git worktree remove --force "$WORKTREE_DIR" 2>/dev/null; then
        log_event reap.worktree "issue=$ISSUE branch=fix/issue-$ISSUE dir=$WORKTREE_DIR caller=swarm-merge.sh"
      else
        log_event reap.worktree.error "issue=$ISSUE branch=fix/issue-$ISSUE dir=$WORKTREE_DIR caller=swarm-merge.sh reason=remove_failed"
      fi
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
if [ "$HOUSEKEEP_ONLY" = 1 ]; then
  if [ -n "$PR_NUM" ]; then
    echo "$(c_green "Done.") Housekeeping complete for issue #$ISSUE (PR #$PR_NUM was not merged)."
  else
    echo "$(c_green "Done.") Housekeeping complete for issue #$ISSUE (no PR; nothing merged)."
  fi
elif [ -n "$ISSUE" ]; then
  echo "$(c_green "Done.") PR #$PR_NUM merged for issue #$ISSUE."
else
  echo "$(c_green "Done.") PR #$PR_NUM merged (no linked issue)."
fi
