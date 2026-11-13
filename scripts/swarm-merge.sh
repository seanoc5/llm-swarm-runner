#!/usr/bin/env bash
# swarm-merge.sh — merge a swarm PR and clean up the local mess.
#
# Usage:
#   swarm-merge.sh <PR#>              # preferred: merges that PR, walks back to
#                                      # its issue for cleanup, cleans
#   swarm-merge.sh <issue#>           # convenience: finds the issue's PR, then
#                                      # the same as above
#   swarm-merge.sh <issue#|PR#> --no-kill # skip the worktree/tmux reap step
#   swarm-merge.sh <issue#|PR#> --expect-head <sha>  # refuse unless the PR head still starts with <sha> (a push after approval)
#   swarm-merge.sh <issue#|PR#> --override-review  # merge despite a BLOCK verdict
#   swarm-merge.sh <issue#|PR#> --override-migration-gate  # merge despite a migration collision
#   swarm-merge.sh <issue#> --force-cleanup  # housekeep even while the issue is OPEN
#   swarm-merge.sh <issue#|PR#> --squash  # accepted-and-ignored: squash is the only mode
#   swarm-merge.sh <issue#|PR#> --auto-low  # unattended low-risk auto-merge path (#452)
#   swarm-merge.sh <issue#|PR#> --auto-medium  # unattended 🟡 path (SWARM_AUTOMERGE_MEDIUM=1)
#   swarm-merge.sh --sweep-only      # just run the local-branch sweep
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
#   Gate 1b (risk floor, #731) scripts/risk-floor.sh --apply <N>: refuse when the
#                         diff trips a risk-floor rule that a 🟢 may not have
#                         (migration, build/CI/auth config, large diff, deleted or
#                         disabled tests). The script bumps the marker to 🟡 and
#                         comments the rule; an error in it refuses too (fail
#                         closed). RISK_FLOOR=0 skips it. See docs/risk-floor.md.
#   Gate 2 (CI wait)      scripts/ci-wait.sh <N> — a real bounded poll of
#                         `gh pr checks` to a concluded state, replacing the
#                         old `gh pr merge --auto` prescription, which
#                         merged immediately because these repos have no
#                         branch protection for --auto to defer to. ci-wait.sh
#                         exit 5 — no CI checks configured at all, OR (#639)
#                         every pull_request workflow's path filter excludes
#                         this PR's changed files, so no run will ever
#                         register — is treated as pass-with-a-loud-warning,
#                         not a refusal — logged as a `merge.gate` event
#                         noting the CI absence — because neither case is
#                         evidence of a failure, and refusing here would
#                         silently strand every such PR's auto-merge path
#                         and point whoever investigates at the wrong
#                         culprit.
#   Gate 3 (review decision) `gh pr view`'s `reviewDecision` is not
#                         `CHANGES_REQUESTED`.
#   Gate 4 (base branch)  `baseRefName` matches the repo's resolved default
#                         branch (`origin/HEAD`, falling back to `main`/
#                         `master`). Never auto-merges feature-to-feature.
#   Gate 5 (draft)        `isDraft` is false.
#
# --auto-medium is the same unattended path for a 🟡 PR, for projects that
# set SWARM_AUTOMERGE_MEDIUM=1 (refused outright otherwise). It runs every
# --auto-low gate above, with Gate 1 expecting the exact medium marker, plus:
#   Gate 8 (hold)         no `> ⛔ **COORDINATOR HOLD**` banner in the body.
#   Gate 9 (independent APPROVE on head) the latest SWARM_SELF_REVIEW marker
#                         with actor=coordinator or actor=operator says bare
#                         APPROVE and its head=<sha> is the PR's current head
#                         (self-review-pr.sh records it). Also accepted:
#                         APPROVE_WITH_CAVEATS whose marker carries
#                         `caveats=nonblocking followup=<issue#>` (written by
#                         self-review-pr.sh --caveats-nonblocking) when that
#                         follow-up issue exists. Other caveats, BLOCK, a
#                         worker-only review, or an older head → refused.
#                         Which branch was taken is logged as merge.gate.
#                         The merge is then pinned to that reviewed commit,
#                         and a CI-verified head that differs is refused.
#   Gate 10 (full review, #789) both --auto-low and --auto-medium: the latest
#                         trusted SWARM_SELF_REVIEW marker (any actor)
#                         must not carry `excluded=N` (N>0 = files left out of
#                         the review). Plain `swarm-merge.sh <N>` is unaffected.
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
#      duplicate Flyway version / Alembic multi-head collision (exit 2) or
#      an out-of-order Flyway merge (exit 3, #556: a PR-side migration
#      numbered below the base branch's current max) unless
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
# A conflicting PR (mergeable=CONFLICTING or mergeStateStatus=DIRTY, before
# or after the merge attempt) whose worker worktree is still on disk gets a
# resolve-conflicts brief via requeue.sh — once; a re-run while it is still
# queued doesn't send another — and the script exits 3. Re-run after the
# worker pushes. With no worktree, it refuses with exit 1 as before.
#
# Exits 0 on success, 3 when a resolve-conflicts brief was queued, other
# non-zero on bailout.

set -euo pipefail

NO_KILL=0
SWEEP_ONLY=0
OVERRIDE_REVIEW=0
OVERRIDE_MIGRATION_GATE=0
FORCE_CLEANUP=0
HOUSEKEEP_ONLY=0
AUTO_LOW=0          # 1 = an unattended path (--auto-low or --auto-medium)
AUTO_RATING=""      # low | medium: the rating that unattended path accepts
REVIEWED_SHA=""
EXPECT_HEAD=""      # --expect-head <sha>: refuse unless the PR head still starts with this (#775)
EXPECT_NEXT=0
EXPECT_SET=0
ISSUE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Test hook (mirrors worker-merge.sh's own CI_WAIT_SCRIPT, #564): lets a
# shape test substitute a fake ci-wait.sh to exercise swarm-merge.sh's own
# handling of ci-wait's output (e.g. a pass with no "verified-head=" line)
# without needing a real CI backend. Defaults identically to before.
#
# PR #643 self-review follow-up: this is a test hook, not a production
# escape hatch. A caller pointing CI_WAIT_SCRIPT at a stub that prints
# "verified-head=<sha>" and exits 0 would let --auto-low merge unattended
# with no real CI check ever run. Honor the override only when the explicit
# SWARM_MERGE_TEST_HOOKS=1 flag is also set (the shape tests set it);
# otherwise ignore it, warn, and fall back to the real ci-wait.sh.
if [ -n "${CI_WAIT_SCRIPT:-}" ] && [ "${SWARM_MERGE_TEST_HOOKS:-0}" != "1" ]; then
  echo "WARNING: CI_WAIT_SCRIPT is set but SWARM_MERGE_TEST_HOOKS=1 is not — ignoring it and using the real ci-wait.sh. This override exists for shape tests only; set SWARM_MERGE_TEST_HOOKS=1 if that is genuinely intended." >&2
  unset CI_WAIT_SCRIPT
fi
CI_WAIT_SCRIPT="${CI_WAIT_SCRIPT:-$SCRIPT_DIR/ci-wait.sh}"

# --- arg parsing -----------------------------------------------------------

for arg in "$@"; do
  if [ "$EXPECT_NEXT" = 1 ]; then
    EXPECT_HEAD="$arg"; EXPECT_SET=1; EXPECT_NEXT=0; continue
  fi
  case "$arg" in
    --expect-head) EXPECT_NEXT=1 ;;
    --expect-head=*) EXPECT_HEAD="${arg#*=}"; EXPECT_SET=1 ;;
    --no-kill)    NO_KILL=1 ;;
    --sweep-only) SWEEP_ONLY=1 ;;
    --override-review) OVERRIDE_REVIEW=1 ;;
    --override-migration-gate) OVERRIDE_MIGRATION_GATE=1 ;;
    --force-cleanup) FORCE_CLEANUP=1 ;;
    --auto-low|--auto-medium)
      [ -z "$AUTO_RATING" ] || { echo "ERROR: give only one of --auto-low / --auto-medium" >&2; exit 2; }
      AUTO_LOW=1; AUTO_RATING="${arg#--auto-}" ;;
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
if [ "$EXPECT_NEXT" = 1 ]; then echo "ERROR: --expect-head needs a SHA" >&2; exit 2; fi
if [ "$EXPECT_SET" = 1 ] && ! [[ "$EXPECT_HEAD" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  echo "ERROR: --expect-head needs 7-40 hex chars (the short SHA you echoed)" >&2; exit 2
fi
EXPECT_HEAD="$(printf "%s" "$EXPECT_HEAD" | tr A-F a-f)"

# --auto-low is the coordinator's unattended path; it must never accept an
# override flag — those exist for a human who read the PR and disagrees
# with a specific gate, a judgment call --auto-low doesn't get to make.
if [ "$AUTO_LOW" = 1 ] && { [ "$OVERRIDE_REVIEW" = 1 ] || [ "$OVERRIDE_MIGRATION_GATE" = 1 ]; }; then
  echo "ERROR: --auto-$AUTO_RATING may not be combined with --override-review or" >&2
  echo "       --override-migration-gate. The unattended path must not accept" >&2
  echo "       overrides — re-run without --auto-$AUTO_RATING if a human is making this call." >&2
  exit 2
fi

# --- helpers ---------------------------------------------------------------

# `git worktree list` first row is always the main worktree.
main_worktree() {
  git worktree list --porcelain | awk '!d && /^worktree / { print $2; d=1 }'
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
# Union of closing-keyword PRs and open PRs on fix/issue-N or fix/issue-N-*
# branches (#906); more than one distinct PR refuses and lists them. Original note: fall
# back to the single OPEN PR on the worker's own fix/issue-N branch: a worker
# that split its work writes "steps 1-2 of #N" rather than "Closes #N", so
# GitHub records no closing link and the issue path used to refuse a PR that
# plainly exists (fand-etl #1133 / PR #1138, 2026-10-06). More than one open
# PR on that branch is ambiguous, so it refuses and asks for the PR number.
# Sets PR_NUM (empty when nothing is found) and PR_VIA (how it was found).
resolve_pr_for_issue() {
  local closing_prs branch_prs all count
  PR_VIA=""
  closing_prs=$(gh issue view "$ISSUE" --json closedByPullRequestsReferences \
                  -q '.closedByPullRequestsReferences[].number' 2>/dev/null || echo "")
  # Open PRs on fix/issue-N or a suffixed fix/issue-N-* branch (#906).
  branch_prs=$(gh pr list --state open --limit 200 --json number,headRefName \
                 --jq ".[] | select(.headRefName | test(\"^fix/issue-$ISSUE(-|\$)\")) | .number" \
                 2>/dev/null || echo "")
  all=$(printf '%s\n%s\n' "$closing_prs" "$branch_prs" | grep '^[0-9][0-9]*$' | sort -un || true)
  count=$(printf '%s\n' "$all" | grep -c '^[0-9][0-9]*$' || true)
  if [ "$count" = 1 ]; then
    PR_NUM="$all"
    if grep -qx "$PR_NUM" <<<"$closing_prs"; then
      PR_VIA="closing keyword"
    else
      PR_VIA="open PR on branch fix/issue-$ISSUE"
    fi
  elif [ "$count" -gt 1 ]; then
    echo "ERROR: issue #$ISSUE maps to $count PRs ($(echo "$all" | sed 's/^/#/' | tr '\n' ' ')) via closing" >&2
    echo "       keywords and open fix/issue-$ISSUE* branches. Pass the PR number." >&2
    exit 1
  else
    PR_NUM=""
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
  echo "Usage: $0 <PR#|issue#> [--no-kill] [--expect-head <sha>]" >&2
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

if [ "$AUTO_RATING" = medium ] && [ "${SWARM_AUTOMERGE_MEDIUM:-0}" != 1 ]; then
  echo "ERROR: --auto-medium refused: SWARM_AUTOMERGE_MEDIUM is not 1 for this project." >&2
  echo "       Set it in <project>/.swarm/.env to opt in, or merge by hand: swarm-merge.sh <N>." >&2
  exit 1
fi

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

# issue #670: retarget open PRs stacked on this PR's head branch onto its own
# base, before the branch is deleted (GitHub closes, not retargets, them).
# Reads PR_NUM, PR_BRANCH, PR_BASE, PR_HEAD_SHA; sets KEEP_BRANCH=1 when the
# branch must not be deleted (lookup or retarget failed). A squash-merge leaves
# the child holding the parent's original commits, so the message says how to
# rebase them off. (tests/test-shape-merge-no-delete-branch.sh runs this
# function against a fake gh — keep it self-contained.)
retarget_stacked_children() {
  local child_prs child rebase_from
  KEEP_BRANCH=0
  [ -n "$PR_BASE" ] || return 0
  # A failed lookup is "unknown", not "no children": keep the branch.
  if ! child_prs=$(gh pr list --state open --base "$PR_BRANCH" --json number --jq '.[].number' 2>/dev/null); then
    child_prs=""
    KEEP_BRANCH=1
    echo "       $(c_amber "⚠ could not list PRs stacked on $PR_BRANCH — keeping origin/$PR_BRANCH; delete it by hand once none are open")"
  fi
  # The remote branch is deleted right after this, so the hint must not name
  # it: prefer the pre-merge head SHA, else resolve the branch's SHA now.
  rebase_from="$PR_HEAD_SHA"
  [ -n "$rebase_from" ] || rebase_from=$(git rev-parse --verify --quiet "origin/$PR_BRANCH" 2>/dev/null || true)
  [ -n "$rebase_from" ] || rebase_from="origin/$PR_BRANCH"
  for child in $child_prs; do
    if gh pr edit "$child" --base "$PR_BASE" >/dev/null 2>&1; then
      echo "       retargeted stacked PR #$child from $PR_BRANCH to $PR_BASE"
      echo "       it still carries #$PR_NUM's original commits (squash-merge rewrote them); in its worktree run:"
      echo "         git fetch origin && git rebase --onto origin/$PR_BASE $rebase_from && git push --force-with-lease"
      log_event merge.retarget "pr=$PR_NUM child=$child base=$PR_BASE result=ok"
    else
      KEEP_BRANCH=1
      echo "       $(c_amber "⚠ could not retarget stacked PR #$child to $PR_BASE — keeping origin/$PR_BRANCH so GitHub doesn't close it; run: gh pr edit $child --base $PR_BASE")"
      log_event merge.retarget "pr=$PR_NUM child=$child base=$PR_BASE result=failed"
    fi
  done
}

# A conflicting PR whose worker is still on disk gets a resolve-conflicts
# brief instead of a dead-end refusal — the same instruction the operator
# used to type by hand. Exits 3 when the brief is (or already was) queued,
# so the caller can retry after the worker pushes; exits 1 when there is no
# worker to send it to. Never returns.
# shellcheck source=_conflict-brief.sh
. "$SCRIPT_DIR/_conflict-brief.sh"
send_conflict_brief_or_die() {
  local detail="$1" wt base out rc=0
  echo "       PR #$PR_NUM has merge conflicts ($detail)."
  wt=""
  [ -n "$ISSUE" ] && wt=$(swarm_worktree_dir "$MAIN_WT" "$ISSUE")
  if [ -z "$wt" ] || [ ! -d "$wt/.swarm" ]; then
    echo "ERROR: PR #$PR_NUM has merge conflicts, and no live worker worktree was" >&2
    echo "       found to resolve them${wt:+ ($wt)}." >&2
    echo "       Respawn one (provision-worker.sh ${ISSUE:-<issue#>}) and tell it to resolve" >&2
    echo "       the conflicts (rebase onto the base branch), or see \$LLM_SWARM_DOCS/VCS/git-github.md." >&2
    exit 1
  fi
  base="${PR_BASE:-$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')}"
  base="${base:-the default branch}"
  out=$(queue_conflict_brief "$wt" "$PR_NUM" "$base" "$detail" "\`swarm-merge.sh\` refused PR #$PR_NUM") || rc=$?
  if [ "$rc" = 2 ]; then
    echo "       $(c_amber "a resolve-conflicts brief is already queued: $out")"
  elif [ "$rc" = 0 ]; then
    [ -n "$out" ] && printf '%s\n' "$out"
    log_event merge.conflict "pr=$PR_NUM issue=$ISSUE action=brief-queued wt=$wt"
  else
    echo "ERROR: requeue.sh failed to queue the resolve-conflicts brief into $wt." >&2
    exit 1
  fi
  echo "       $(c_amber "→ resolve-conflicts brief sent to the issue #$ISSUE worker.")"
  local rerun="swarm-merge.sh $PR_NUM"
  [ "$AUTO_LOW" = 1 ] && rerun="$rerun --auto-$AUTO_RATING"
  echo "       Re-run once it has pushed and CI is green: $rerun"
  exit 3
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
  PR_JSON=$(gh pr view "$PR_NUM" --json state,mergeable,mergeStateStatus,headRefName,title,closingIssuesReferences,body,isDraft,reviewDecision,baseRefName,headRefOid)
  PR_STATE=$(echo "$PR_JSON" | jq -r .state)
  PR_MERGEABLE=$(echo "$PR_JSON" | jq -r .mergeable)
  PR_MERGE_STATE_STATUS=$(echo "$PR_JSON" | jq -r '.mergeStateStatus // ""')
  PR_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
  PR_TITLE=$(echo "$PR_JSON" | jq -r .title)
  PR_BODY=$(echo "$PR_JSON" | jq -r '.body // ""')
  PR_IS_DRAFT=$(echo "$PR_JSON" | jq -r '.isDraft // false')
  PR_REVIEW_DECISION=$(echo "$PR_JSON" | jq -r '.reviewDecision // ""')
  PR_BASE=$(echo "$PR_JSON" | jq -r '.baseRefName // ""')
  PR_HEAD_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid // ""')
  echo "[3/6] PR #$PR_NUM: state=$PR_STATE mergeable=$PR_MERGEABLE branch=$PR_BRANCH"
  echo "       title: $PR_TITLE"

  # issue #775: --expect-head binds this merge to the SHA the operator approved.
  # Cheap early refusal; the authoritative re-check happens under the action lock.
  if [ -n "$EXPECT_HEAD" ]; then
    PR_HEAD_LC="$(printf '%s' "$PR_HEAD_SHA" | tr A-F a-f)"
    if [ "$PR_STATE" = "MERGED" ]; then
      # Already merged (issue #786): there is nothing left to bind a merge to, so
      # this is not a refusal. Same wording and exit as the under-lock path
      # (merged by another actor: warn, continue to cleanup, exit 0).
      if [ -z "$PR_HEAD_LC" ] || [ "${PR_HEAD_LC#"$EXPECT_HEAD"}" = "$PR_HEAD_LC" ]; then
        echo "       $(c_amber "⚠ PR #$PR_NUM is already MERGED, at head ${PR_HEAD_SHA:-unknown} rather than the approved $EXPECT_HEAD (--expect-head) — this run merges nothing; continuing to cleanup")"
        log_event merge.gate "pr=$PR_NUM gate=expect-head result=already-merged-other-head expected=$EXPECT_HEAD now=${PR_HEAD_SHA:-unknown} action=skip-merge"
      fi
    elif [ -z "$PR_HEAD_LC" ] || [ "${PR_HEAD_LC#"$EXPECT_HEAD"}" = "$PR_HEAD_LC" ]; then
      echo "ERROR: PR #$PR_NUM's head is ${PR_HEAD_SHA:-unknown}, not the approved $EXPECT_HEAD (--expect-head) — a push landed after approval. Nothing merged; re-read the PR and re-approve." >&2
      log_event merge.gate "pr=$PR_NUM gate=expect-head result=head-moved expected=$EXPECT_HEAD now=${PR_HEAD_SHA:-unknown} action=refuse"
      exit 1
    fi
  fi

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
        send_conflict_brief_or_die "mergeable=CONFLICTING"
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
        send_conflict_brief_or_die "mergeStateStatus=DIRTY"
      fi
      # --auto-low Gate 0 (#452): authorship, hard and non-overridable. Only
      # active on the coordinator's unattended SWARM_AUTOMERGE_LOW path; a
      # plain `swarm-merge.sh <N>` skips it. Checked here, first and cheap,
      # before anything that costs real wall-clock time below.
      if [ "$AUTO_LOW" = 1 ]; then
        echo "       auto-$AUTO_RATING gate 0 (authorship): checking…"
        AUTH_RC=0
        "$SCRIPT_DIR/check-coordinator-authorship.sh" "$PR_NUM" || AUTH_RC=$?
        if [ "$AUTH_RC" = 1 ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 0 (authorship)." >&2
          echo "       This PR carries a coordinator-authored commit and must go to" >&2
          echo "       the operator — there is no override for this gate. A human can" >&2
          echo "       still merge it directly: swarm-merge.sh $PR_NUM (no --auto-$AUTO_RATING)." >&2
          exit 1
        elif [ "$AUTH_RC" != 0 ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 0 (authorship, exit $AUTH_RC)." >&2
          echo "       check-coordinator-authorship.sh errored rather than returning a clean" >&2
          echo "       verdict (see its output above) — failing closed, not eligible." >&2
          exit 1
        fi

        # --auto-low Gates 1, 3, 4, 5 (#454 follow-up to #452): cheap,
        # non-overridable checks off the same PR_JSON fetch above — no extra
        # `gh` calls. Matches prompts/coordinator.md's 8-gate list; gates 6
        # (diff-scope read) and 7 (migration collision, pre-existing below)
        # aren't repeated here.
        echo "       auto-$AUTO_RATING gate 1 (rating marker): checking…"
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
        if [ "$RATING_MARKER" != "<!-- BLIND_MERGE_RISK: $AUTO_RATING -->" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 1 (rating marker)." >&2
          echo "       First '<!-- BLIND_MERGE_RISK: ... -->' marker in the body is" >&2
          echo "       '${RATING_MARKER:-<absent>}', not the exact $AUTO_RATING marker — not" >&2
          echo "       eligible for unattended merge." >&2
          exit 1
        fi

        # Gate 1b (#731): the marker is the worker's self-rating; this is the
        # deterministic check that the diff allows it. risk-floor.sh --apply
        # bumps a too-low marker itself (and comments with the rule), so a
        # refused PR is already a 🟡 PR for the operator. Fails closed: any
        # exit other than 0/10 refuses. RISK_FLOOR=0 turns it off.
        if [ "${RISK_FLOOR:-1}" != "0" ]; then
          echo "       auto-$AUTO_RATING gate 1b (risk floor): checking…"
          FLOOR_RC=0
          FLOOR_OUT="$("${RISK_FLOOR_SCRIPT:-$SCRIPT_DIR/risk-floor.sh}" --apply "$PR_NUM" 2>&1)" || FLOOR_RC=$?
          if [ "$FLOOR_RC" = 10 ]; then
            echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 1b (risk floor)." >&2
            echo "       The diff is riskier than the $AUTO_RATING rating; the marker was bumped and a comment names the rule:" >&2
            sed 's/^/       /' <<<"$FLOOR_OUT" >&2
            exit 1
          elif [ "$FLOOR_RC" != 0 ]; then
            echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 1b (risk floor, exit $FLOOR_RC)." >&2
            echo "       risk-floor.sh errored rather than returning a verdict — failing closed:" >&2
            sed 's/^/       /' <<<"$FLOOR_OUT" >&2
            exit 1
          fi
        fi

        echo "       auto-$AUTO_RATING gate 3 (review decision): checking…"
        if [ "$PR_REVIEW_DECISION" = "CHANGES_REQUESTED" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 3 (review decision)." >&2
          echo "       reviewDecision is CHANGES_REQUESTED — not eligible for unattended merge." >&2
          exit 1
        fi

        echo "       auto-$AUTO_RATING gate 4 (base branch): checking…"
        DEFAULT_BRANCH="$(resolve_default_branch)"
        if [ -z "$DEFAULT_BRANCH" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 4 (base branch)." >&2
          echo "       Could not resolve the repo's default branch to compare against —" >&2
          echo "       failing closed rather than guessing." >&2
          exit 1
        fi
        if [ "$PR_BASE" != "$DEFAULT_BRANCH" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 4 (base branch)." >&2
          echo "       base is '$PR_BASE', default branch is '$DEFAULT_BRANCH' — never" >&2
          echo "       auto-merge feature-to-feature." >&2
          exit 1
        fi

        echo "       auto-$AUTO_RATING gate 5 (draft): checking…"
        if [ "$PR_IS_DRAFT" = "true" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 5 (draft)." >&2
          echo "       PR is still a draft — not eligible for unattended merge." >&2
          exit 1
        fi

        # Gate 10 (#789): a review that left files out (marker carries
        # excluded=N) is not a full review. Unattended merge refuses; an
        # operator's plain merge is unaffected. Latest trusted marker of any
        # actor wins, any head (a stale exclusion needs a fresh full review).
        echo "       auto-$AUTO_RATING gate 10 (full review, no excluded files): checking…"
        G10_JSON="$(gh pr view "$PR_NUM" --json comments,headRefOid 2>/dev/null || true)"
        [ -n "$G10_JSON" ] || {
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 10: could not read the PR's review markers." >&2
          exit 1
        }
        # Latest marker of any actor, read loosely (any head= token, incl.
        # head=unknown) so the newest marker always wins; then validated
        # strictly below. An unparseable latest marker fails closed. Anchored on
        # "<!-- " so prose quoting a marker is never read as one (#833).
        G10_LOOSE="$(jq -r '.comments[] | select(.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) | .body // ""' <<<"$G10_JSON" 2>/dev/null \
                      | grep -oE "<!-- SWARM_SELF_REVIEW: [A-Za-z_]+( [A-Za-z_]+=[^ >]*)*" \
                      | sed "s/^<!-- //" | tail -1 || true)"
        G10_STRICT='^SWARM_SELF_REVIEW: [A-Z_]+ actor=[A-Za-z0-9_-]+( head=[^ ]+)?( caveats=[a-z]+)?( followup=[0-9]+)?( excluded=[0-9]+)?$'
        G10_MARKER="$G10_LOOSE"
        G10_BAD=""
        if [ -n "$G10_LOOSE" ] && ! grep -qE "$G10_STRICT" <<<"$G10_LOOSE"; then
          G10_BAD="the latest review marker is unparseable: '$G10_LOOSE'"
        fi
        # Gate 9 (--auto-medium) trusts the latest coordinator/operator marker;
        # if THAT one left files out, a later clean worker marker must not
        # paper over it, so check it too.
        G10_IND=""
        if [ "$AUTO_RATING" = medium ]; then
          G10_IND="$(jq -r '.comments[] | select(.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) | .body // ""' <<<"$G10_JSON" 2>/dev/null \
                      | grep -oE "<!-- SWARM_SELF_REVIEW: [A-Za-z_]+ actor=(coordinator|operator)( [A-Za-z_]+=[^ >]*)*" \
                      | sed "s/^<!-- //" | tail -1 || true)"
          if [ -n "$G10_IND" ] && ! grep -qE "$G10_STRICT" <<<"$G10_IND"; then
            G10_BAD="the latest coordinator/operator review marker is unparseable: '$G10_IND'"
          fi
        fi
        if [ -n "$G10_BAD" ]; then
          log_event merge.gate "pr=$PR_NUM gate=10-full-review result=refused reason=unparseable action=refuse-auto-$AUTO_RATING"
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 10 (full review): $G10_BAD (fail closed)." >&2
          exit 1
        fi
        G10_EXCLUDED="$(grep -oE 'excluded=[0-9]+' <<<"$G10_MARKER" | cut -d= -f2 || true)"
        G10_IND_EXCLUDED="$(grep -oE 'excluded=[0-9]+' <<<"$G10_IND" | cut -d= -f2 || true)"
        if [ "${G10_EXCLUDED:-0}" -gt 0 ] || [ "${G10_IND_EXCLUDED:-0}" -gt 0 ]; then
          G10_N=$(( ${G10_EXCLUDED:-0} > ${G10_IND_EXCLUDED:-0} ? ${G10_EXCLUDED:-0} : ${G10_IND_EXCLUDED:-0} ))
          log_event merge.gate "pr=$PR_NUM gate=10-full-review result=refused excluded=$G10_N action=refuse-auto-$AUTO_RATING"
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 10 (full review): a review left out $G10_N file(s), so it is not a full review." >&2
          echo "       Re-run self-review-pr.sh $PR_NUM --post --rerun with a smaller diff, or merge it yourself: swarm-merge.sh $PR_NUM (no --auto-$AUTO_RATING)." >&2
          exit 1
        fi

        if [ "$AUTO_RATING" = medium ]; then
          echo "       auto-medium gate 8 (hold banner): checking…"
          if grep -qE '^> ⛔ \*\*COORDINATOR HOLD\*\*' <<<"$PR_BODY"; then
            echo "ERROR: PR #$PR_NUM refused by --auto-medium Gate 8 (hold): a COORDINATOR HOLD banner is on the body." >&2
            exit 1
          fi

          echo "       auto-medium gate 9 (independent APPROVE on head): checking…"
          REVIEW_JSON="$(gh pr view "$PR_NUM" --json comments,headRefOid 2>/dev/null || true)"
          HEAD_NOW="$(jq -r '.headRefOid // ""' <<<"$REVIEW_JSON" 2>/dev/null || true)"
          # Latest marker from an independent actor; worker rounds don't count.
          # Only repo owner/member/collaborator comments are read, so an outside
          # commenter can't forge one. Workers share the operator's gh account,
          # so this does not stop a worker posting actor=coordinator itself.
          IND_MARKER="$(jq -r '.comments[] | select(.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) | .body // ""' <<<"$REVIEW_JSON" 2>/dev/null \
                        | grep -oE 'SWARM_SELF_REVIEW: [A-Z_]+ actor=(coordinator|operator)( head=[^ >]+)?( caveats=[a-z]+)?( followup=[0-9]+)?( excluded=[0-9]+)?' \
                        | tail -1 || true)"
          IND_VERDICT="$(sed -E 's/^SWARM_SELF_REVIEW: ([A-Z_]+).*/\1/' <<<"$IND_MARKER")"
          IND_HEAD="$(grep -oE 'head=[0-9a-f]+' <<<"$IND_MARKER" | cut -d= -f2 || true)"
          IND_CAVEATS="$(grep -oE 'caveats=[a-z]+' <<<"$IND_MARKER" | cut -d= -f2 || true)"
          IND_FOLLOWUP="$(grep -oE 'followup=[0-9]+' <<<"$IND_MARKER" | cut -d= -f2 || true)"
          GATE9_OK=0
          if [ -n "$HEAD_NOW" ] && [ "$IND_HEAD" = "$HEAD_NOW" ]; then
            if [ "$IND_VERDICT" = APPROVE ]; then
              GATE9_OK=1
              log_event merge.gate "pr=$PR_NUM gate=9-independent-review result=approve head=$HEAD_NOW action=proceed"
            elif [ "$IND_VERDICT" = APPROVE_WITH_CAVEATS ] && [ "$IND_CAVEATS" = nonblocking ] && [ -n "$IND_FOLLOWUP" ]; then
              # Non-blocking caveats (the reviewer judged them not about
              # correctness/security/data loss/schema) are accepted only with
              # a real follow-up ISSUE (not a PR — `gh issue view` also
              # resolves PR numbers, hence the /issues/ url check).
              # It must also be OPEN and mention this PR (#687), so an old,
              # closed or unrelated issue can't stand in for the follow-up.
              FOLLOWUP_JSON="$(gh issue view "$IND_FOLLOWUP" --json url,state,title,body,labels 2>/dev/null || true)"
              FOLLOWUP_URL="$(jq -r '.url // ""' <<<"$FOLLOWUP_JSON" 2>/dev/null || true)"
              FOLLOWUP_STATE="$(jq -r '.state // ""' <<<"$FOLLOWUP_JSON" 2>/dev/null || true)"
              FOLLOWUP_REASON=""
              if [[ "$FOLLOWUP_URL" != */issues/"$IND_FOLLOWUP" ]]; then
                FOLLOWUP_REASON="not-an-issue"
                echo "       follow-up #$IND_FOLLOWUP is not an issue in this repo (gh issue view returned '${FOLLOWUP_URL:-nothing}')." >&2
              elif [ "$FOLLOWUP_STATE" != OPEN ]; then
                FOLLOWUP_REASON="not-open"
                echo "       follow-up #$IND_FOLLOWUP is not OPEN (state '${FOLLOWUP_STATE:-unknown}')." >&2
              elif ! jq -e --arg re "#$PR_NUM([^0-9]|\$)" --arg lb "from-pr-$PR_NUM" '(((.title // "") + "\n" + (.body // "")) | test($re)) or any(.labels[]?; .name == $lb)' <<<"$FOLLOWUP_JSON" >/dev/null 2>&1; then
                FOLLOWUP_REASON="no-pr-reference"
                echo "       follow-up #$IND_FOLLOWUP does not mention #$PR_NUM in its title or body and lacks label from-pr-$PR_NUM." >&2
              fi
              if [ -z "$FOLLOWUP_REASON" ]; then
                GATE9_OK=1
                echo "       $(c_amber "auto-medium gate 9: APPROVE_WITH_CAVEATS accepted — caveats recorded non-blocking, follow-up #$IND_FOLLOWUP")"
                log_event merge.gate "pr=$PR_NUM gate=9-independent-review result=caveats-nonblocking followup=$IND_FOLLOWUP head=$HEAD_NOW action=proceed"
              fi
            fi
          fi
          if [ "$GATE9_OK" != 1 ]; then
            log_event merge.gate "pr=$PR_NUM gate=9-independent-review result=refused verdict=${IND_VERDICT:-none} caveats=${IND_CAVEATS:-none} followup=${IND_FOLLOWUP:-none} followup_reason=${FOLLOWUP_REASON:-none} action=refuse-auto-medium"
            echo "ERROR: PR #$PR_NUM refused by --auto-medium Gate 9 (independent APPROVE on head)." >&2
            echo "       Latest coordinator/operator review: '${IND_MARKER:-<none>}'; current head: '${HEAD_NOW:-<unreadable>}'." >&2
            echo "       Needs a bare APPROVE on this exact head (self-review-pr.sh $PR_NUM --post --actor coordinator)," >&2
            echo "       or non-blocking caveats with a filed follow-up issue (self-review-pr.sh $PR_NUM --caveats-nonblocking <issue#> --actor coordinator)." >&2
            exit 1
          fi
          REVIEWED_SHA="$HEAD_NOW"
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
          3)
            # Out-of-order Flyway merge (#556): a PR-side migration numbered
            # below the base tip's own max — no duplicate number, so this is
            # distinct from the collision case above, but equally refused by
            # default (the same override flag, since a project that runs
            # Flyway with outOfOrder=true may accept it deliberately; see
            # MIGRATION_ALLOW_OUT_OF_ORDER in migration-collision-check.sh's
            # header for an opt-out that avoids this gate firing at all).
            if [ "$OVERRIDE_MIGRATION_GATE" = 0 ]; then
              echo "ERROR: PR #$PR_NUM has an out-of-order Flyway merge (a PR-side" >&2
              echo "       migration numbered below the base branch's current max)." >&2
              echo "       Run scripts/migration-collision-check.sh $PR_NUM for details;" >&2
              echo "       merge with --override-migration-gate if you disagree." >&2
              exit 1
            fi
            echo "       $(c_amber "⚠ overriding out-of-order Flyway merge (--override-migration-gate)")"
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
        echo "       auto-$AUTO_RATING gate 2 (CI wait): waiting for a real conclusion…"
        CI_RC=0
        # issue #629 self-review follow-up: tee ci-wait.sh's own output so we
        # can recover the exact commit it verified (its "verified-head=" line)
        # for --match-head-commit below, while still streaming it live as
        # before. `set -o pipefail` (already on, line 154) makes $? here
        # ci-wait.sh's own exit code, since `tee` itself always succeeds.
        CI_WAIT_LOG="$(mktemp)"
        "$CI_WAIT_SCRIPT" "$PR_NUM" 2>&1 | tee "$CI_WAIT_LOG" || CI_RC=$?
        CI_VERIFIED_SHA="$(grep -o 'verified-head=[0-9a-f]\{7,40\}' "$CI_WAIT_LOG" | tail -1 | cut -d= -f2 || true)"
        rm -f "$CI_WAIT_LOG"
        if [ "$CI_RC" = 5 ]; then
          # No CI checks configured on this repo at all — pass-with-warning,
          # not a refusal (see the Gate 2 note in the header comment above).
          echo "       $(c_amber "⚠ auto-$AUTO_RATING gate 2: no CI checks configured on this repo — proceeding (pass-with-warning)")"
          log_event merge.gate "pr=$PR_NUM gate=2-ci-wait result=no-checks-configured action=proceed"
        elif [ "$CI_RC" != 0 ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-$AUTO_RATING Gate 2 (CI wait, exit $CI_RC)." >&2
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
      # issue #629 self-review follow-up: pin the actual merge to the exact
      # commit that was just verified (by ci-wait.sh above, when it ran) —
      # closes the gap between "CI confirmed green on commit X" and "this
      # merge call happens some moments later" that ci-wait.sh's own result
      # alone can't close. If a NEW push supersedes X in that window,
      # --match-head-commit makes `gh pr merge` refuse instead of silently
      # squash-merging the new, never-checked commit under X's green CI.
      # No verified SHA to pin to. Two different reasons land here, and
      # they get different treatment:
      #   - Gate 2 skipped entirely (plain merge, no --auto-low), or it
      #     passed via the no-CI-configured exit 5 (nothing was ever run,
      #     so there was never a commit to verify) — fall back to a fresh
      #     read right before merging, which still closes the ordinary
      #     TOCTOU window even though it can't catch a push that lands in
      #     the next instant.
      #   - Gate 2 itself exited 0 (a real pass) but produced no
      #     "verified-head=" line anyway. ci-wait.sh's own success path
      #     always prints one, so this means something's wrong with the
      #     log capture, not a case safe to guess through — refuse rather
      #     than silently pinning to an unrelated fresh read that was never
      #     actually checked against the CI result that justified merging
      #     at all (issue #629 follow-up).
      MATCH_SHA="${CI_VERIFIED_SHA:-}"
      # --auto-medium: CI and the independent review must be about the same
      # commit, and the merge pins to it (also when no CI is configured).
      if [ -n "$REVIEWED_SHA" ]; then
        if [ -n "$MATCH_SHA" ] && [ "$MATCH_SHA" != "$REVIEWED_SHA" ]; then
          echo "ERROR: PR #$PR_NUM refused by --auto-medium Gate 9: CI verified $MATCH_SHA but the review was for $REVIEWED_SHA (a push landed in between). Re-review the new head." >&2
          exit 1
        fi
        MATCH_SHA="$REVIEWED_SHA"
      fi
      if [ -z "$MATCH_SHA" ]; then
        if [ "${CI_RC:-}" = "0" ]; then
          echo "ERROR: PR #$PR_NUM's Gate 2 (CI wait) reported a pass but never named the commit it verified — refusing to merge rather than pinning to an unrelated fresh read. Re-run ci-wait.sh by hand ($SCRIPT_DIR/ci-wait.sh $PR_NUM) and check its output." >&2
          exit 1
        fi
        MATCH_SHA="$(gh pr view "$PR_NUM" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
        if [ -z "$MATCH_SHA" ]; then
          # issue #643 self-review follow-up: this fallback read itself can
          # fail (transient gh error, auth, rate limit) just like the main
          # PR_JSON fetch above can. Merging with no --match-head-commit at
          # all reopens the exact TOCTOU window #629 closed: a push landing
          # right now would squash-merge unpinned and unnoticed. --auto-low
          # has no human present to see a warning, so it refuses outright; a
          # plain (human-driven) merge gets a loud warning plus a merge.gate
          # event instead, since a person is already watching this merge and
          # can judge for themselves whether to proceed.
          if [ "$AUTO_LOW" = 1 ]; then
            echo "ERROR: PR #$PR_NUM's fallback head-commit read failed (gh pr view --json headRefOid) with no verified commit to pin to — refusing to merge --auto-$AUTO_RATING unpinned." >&2
            echo "       Retry, or merge by hand (swarm-merge.sh $PR_NUM, no --auto-$AUTO_RATING) once you've confirmed the head commit yourself." >&2
            log_event merge.gate "pr=$PR_NUM gate=match-head-commit result=fallback-read-failed action=refuse-auto-low"
            exit 1
          fi
          echo "       $(c_amber "⚠ could not read PR #$PR_NUM's head commit (gh pr view --json headRefOid failed) — merging WITHOUT --match-head-commit; a push landing right now could merge unpinned and unnoticed")"
          log_event merge.gate "pr=$PR_NUM gate=match-head-commit result=fallback-read-failed action=proceed-unpinned"
        fi
      fi
      # issue #766 (ADR 0006 §3): action lock, held only from here to the end
      # of the merge call — never around ci-wait.sh above, which can block
      # 570 s. It keeps a work run and the operator's conversation session
      # from both merging one PR. Under the lock, re-read the PR: someone
      # else may have merged it already (then we skip the merge, not fail),
      # or the head may have moved since the gates ran (refuse).
      # Only this script takes the lock; worker-merge.sh (sandbox) does not and
      # relies on --match-head-commit instead (issue #773).
      ACTION_LOCK_FILE="${COORD_ACTIONS_LOCK:-$MAIN_WT/.swarm/coord-actions.lock}"
      mkdir -p "$(dirname "$ACTION_LOCK_FILE")" 2>/dev/null || true
      ACTION_LOCK_HELD=0
      if command -v flock >/dev/null 2>&1 && { exec {ACTION_LOCK_FD}>"$ACTION_LOCK_FILE"; } 2>/dev/null; then
        if flock -w "${COORD_ACTIONS_LOCK_TIMEOUT_SECS:-120}" "$ACTION_LOCK_FD"; then
          ACTION_LOCK_HELD=1
        else
          echo "ERROR: swarm-merge.sh (exit 1, not provision-worker.sh's exit 5): PR #$PR_NUM: could not get the coordinator action lock ($ACTION_LOCK_FILE) within ${COORD_ACTIONS_LOCK_TIMEOUT_SECS:-120}s — another coordinator action holds it. Nothing merged; safe to re-run swarm-merge.sh once it finishes." >&2
          log_event merge.gate "pr=$PR_NUM gate=action-lock result=timeout action=refuse"
          exit 1
        fi
      else
        if [ "$AUTO_LOW" = 1 ]; then
          echo "ERROR: PR #$PR_NUM: action lock unavailable (no flock, or $ACTION_LOCK_FILE not writable) — refusing to merge --auto-$AUTO_RATING unlocked. A plain swarm-merge.sh $PR_NUM (no --auto-$AUTO_RATING) may proceed without it." >&2
          log_event merge.gate "pr=$PR_NUM gate=action-lock result=unavailable action=refuse-auto-low"
          exit 1
        fi
        echo "       $(c_amber "⚠ action lock unavailable (no flock, or lock file not writable) — merging without it")"
        log_event merge.gate "pr=$PR_NUM gate=action-lock result=unavailable action=proceed-unlocked"
      fi
      # The head the gates actually saw: the CI-verified or reviewed commit, else the
      # head from the initial PR read (never the fresh fallback read above).
      INITIAL_HEAD="$(jq -r '.headRefOid // ""' <<<"$PR_JSON" 2>/dev/null || true)"
      GATE_SHA="${CI_VERIFIED_SHA:-${REVIEWED_SHA:-$INITIAL_HEAD}}"
      LOCK_JSON="" ; LOCK_RC=0
      LOCK_JSON=$(gh pr view "$PR_NUM" --json state,headRefOid 2>/dev/null) || LOCK_RC=$?
      LOCK_STATE=$(jq -r '.state // ""' <<<"$LOCK_JSON" 2>/dev/null || true)
      LOCK_HEAD=$(jq -r '.headRefOid // ""' <<<"$LOCK_JSON" 2>/dev/null || true)
      MERGED_BY_OTHER=0
      # issue #775: --expect-head, checked against the head re-read under the
      # lock. Fails closed: an unreadable head cannot confirm the approved SHA.
      if [ -n "$EXPECT_HEAD" ] && [ "$LOCK_STATE" != "MERGED" ]; then
        LOCK_HEAD_LC="$(printf '%s' "$LOCK_HEAD" | tr A-F a-f)"
        if [ "$LOCK_RC" != 0 ] || [ -z "$LOCK_HEAD_LC" ] || [ "${LOCK_HEAD_LC#"$EXPECT_HEAD"}" = "$LOCK_HEAD_LC" ]; then
          echo "ERROR: PR #$PR_NUM's head is ${LOCK_HEAD:-unreadable} at merge time, not the approved $EXPECT_HEAD (--expect-head) — refusing. Re-read the PR and re-approve." >&2
          log_event merge.gate "pr=$PR_NUM gate=expect-head result=head-moved-at-lock expected=$EXPECT_HEAD now=${LOCK_HEAD:-unreadable} action=refuse"
          exit 1
        fi
        # Pin the merge call itself to the approved full SHA.
        [ -z "$MATCH_SHA" ] && MATCH_SHA="$LOCK_HEAD"
      fi
      if [ "$LOCK_RC" = 0 ] && [ "$LOCK_STATE" = "MERGED" ]; then
        MERGED_BY_OTHER=1
        echo "       $(c_amber "⚠ PR #$PR_NUM was merged by another actor while this merge waited for the action lock — skipping the merge call")"
        if [ -n "$EXPECT_HEAD" ]; then
          LOCK_HEAD_LC="$(printf '%s' "$LOCK_HEAD" | tr A-F a-f)"
          if [ -z "$LOCK_HEAD_LC" ] || [ "${LOCK_HEAD_LC#"$EXPECT_HEAD"}" = "$LOCK_HEAD_LC" ]; then
            echo "       $(c_amber "⚠ it merged at head ${LOCK_HEAD:-unknown}, not the approved $EXPECT_HEAD (--expect-head); this run merges nothing")"
          fi
        fi
        log_event merge.gate "pr=$PR_NUM gate=action-lock result=already-merged action=skip-merge"
      elif [ "$LOCK_RC" = 0 ] && [ -n "$LOCK_STATE" ] && [ "$LOCK_STATE" != "OPEN" ]; then
        echo "ERROR: PR #$PR_NUM is $LOCK_STATE at merge time (re-read under the action lock) — nothing merged." >&2
        log_event merge.gate "pr=$PR_NUM gate=action-lock result=state-$LOCK_STATE action=refuse"
        exit 1
      elif [ "$LOCK_RC" = 0 ] && [ -n "$LOCK_HEAD" ] && [ -n "$GATE_SHA" ] && [ "$LOCK_HEAD" != "$GATE_SHA" ]; then
        echo "ERROR: PR #$PR_NUM's head moved between the gates and the merge (gated $GATE_SHA, now $LOCK_HEAD) — refusing. Re-run the gates on the new head." >&2
        log_event merge.gate "pr=$PR_NUM gate=action-lock result=head-moved gated=$GATE_SHA now=$LOCK_HEAD action=refuse"
        exit 1
      elif [ "$LOCK_RC" = 0 ] && [ -n "$LOCK_HEAD" ] && [ -n "$INITIAL_HEAD" ] && [ "$LOCK_HEAD" != "$INITIAL_HEAD" ]; then
        # ci-wait.sh follows new commits and reports the newest as verified-head, so
        # GATE_SHA can equal a head that arrived during the CI wait; the authorship,
        # review and migration gates only ever read INITIAL_HEAD (PR_JSON).
        echo "ERROR: PR #$PR_NUM's head is $LOCK_HEAD now but the authorship/review/migration gates read $INITIAL_HEAD (it moved during the CI wait) — refusing. Re-run the gates on the new head." >&2
        log_event merge.gate "pr=$PR_NUM gate=action-lock result=head-moved-since-gates gated=$INITIAL_HEAD now=$LOCK_HEAD action=refuse"
        exit 1
      elif [ "$LOCK_RC" != 0 ] || [ -z "$LOCK_HEAD" ]; then
        if [ "$AUTO_LOW" = 1 ]; then
          echo "ERROR: PR #$PR_NUM: re-read under the action lock failed — refusing to merge --auto-$AUTO_RATING without it." >&2
          log_event merge.gate "pr=$PR_NUM gate=action-lock result=reread-failed action=refuse-auto-low"
          exit 1
        fi
        echo "       $(c_amber "⚠ re-read under the action lock failed — continuing on the earlier read")"
        log_event merge.gate "pr=$PR_NUM gate=action-lock result=reread-failed action=proceed"
      fi
      MATCH_ARGS=()
      [ -n "$MATCH_SHA" ] && MATCH_ARGS=(--match-head-commit "$MATCH_SHA")
      MERGE_RC=0
      if [ "$MERGED_BY_OTHER" = 0 ]; then
        gh pr merge "$PR_NUM" --squash "${MATCH_ARGS[@]}" || MERGE_RC=$?
      fi
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
            echo "       PR #$PR_NUM is confirmed state=$POST_STATE with a real conflict." >&2
            send_conflict_brief_or_die "mergeable=$POST_MERGEABLE, mergeStateStatus=$POST_MSS"
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
      # The daily changelog reads this to tell unattended merges from operator
      # ones; the colour marker alone can't (operator-merged 🟢/🟡 PRs exist).
      if [ "$AUTO_LOW" = 1 ]; then MERGE_MODE="unattended-$AUTO_RATING"; else MERGE_MODE=operator; fi
      # Merge call finished: release the action lock before cleanup (issue #766).
      if [ "$ACTION_LOCK_HELD" = 1 ]; then exec {ACTION_LOCK_FD}>&-; ACTION_LOCK_HELD=0; fi
      # Whoever actually merged logs merge.done; the loser of a race does not.
      [ "${MERGED_BY_OTHER:-0}" = 1 ] || log_event merge.done "pr=$PR_NUM issue=${ISSUE:-none} mode=$MERGE_MODE"
      # issue #670: a stacked PR (base = this PR's head branch) is silently
      # CLOSED by GitHub when that branch is deleted, not retargeted. Move any
      # open child PRs onto this PR's own base first. If a retarget fails,
      # keep the branch: a leftover branch is cheap, a closed child PR isn't.
      retarget_stacked_children
      if [ "$KEEP_BRANCH" = 1 ]; then
        echo "       (remote branch origin/$PR_BRANCH not deleted — see retarget warning above)"
      elif git push origin --delete "$PR_BRANCH" >/dev/null 2>&1; then
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
    # --grace: a worker with unsaved edits keeps its worktree for
    # SWARM_REAP_GRACE_SECS (4h) instead of losing it to an immediate reap.
    "$SCRIPT_DIR/kill-worktree.sh" "$ISSUE" "$MAIN_WT" --grace || KILL_RC=$?
    case "$KILL_RC" in
      0) echo "       reaped ✓" ;;
      75)
        echo "       $(c_amber "⚠ kill-worktree.sh deferred (in-flight check-claim, or unsaved work held for the reap grace) — worktree left in place, watcher's own backstop will retry")"
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

# issue #641: a merge makes the project checkout stale by one commit; nothing
# else fast-forwards it, so workers/watchers would keep running pre-fix scripts.
# Best effort: never changes the exit status, warns when it cannot update.
if [ "$HOUSEKEEP_ONLY" != 1 ] && [ -n "$PR_NUM" ] && [ -f "$SCRIPT_DIR/_checkout-staleness.sh" ]; then
  # shellcheck source=_checkout-staleness.sh
  . "$SCRIPT_DIR/_checkout-staleness.sh"
  if FF_MSG="$(checkout_ff_to_origin "$MAIN_WT")"; then
    echo "[ff] $FF_MSG"
  else
    echo "[ff] $(c_amber "⚠ $FF_MSG")"
  fi
fi

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
