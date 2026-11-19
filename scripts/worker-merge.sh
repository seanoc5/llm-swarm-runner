#!/usr/bin/env bash
#
# worker-merge.sh — the one gated path a worker uses to merge its own PR, at
# every rating, once the operator has approved it in the way that rating
# needs (issue #564 for 🔴; 🟢/🟡 added later). prompts/worker.md says which
# approval each rating needs; this script checks everything a script can.
#
# Usage:
#   worker-merge.sh <PR#> --expect-head <sha> [--rating low|medium|high]
#
# --rating defaults to high, which is how the 🔴-only version was called.
#
# Runs inside the worker sandbox, where swarm-merge.sh can't (it cds to the
# main worktree, which the #504 lockdown doesn't mount). Every gate fails
# closed and there are no override flags — overriding a gate is a human
# decision made at a shell with plain swarm-merge.sh.
#
# Gates, cheap first:
#   1. PR is OPEN, not a draft, carries no swarm-hold* label (#612; see
#      _hold-label.sh), not CONFLICTING, based on the default branch.
#   2. Head matches --expect-head (≥7 hex chars; the short SHA the worker
#      echoed back to the operator before merging). A push after the
#      approval voids it. Re-enforced server-side by --match-head-commit.
#   3. Body carries <!-- BLIND_MERGE_RISK: <rating> --> for the --rating
#      the worker echoed to the operator. An approval given for a 🟢 PR
#      can't merge one that is really rated 🟡/🔴.
#   4. Self-review: for medium/high, a verdict is on record and the latest
#      is not BLOCK. For low (pr-ready.sh skips the review), only a latest
#      BLOCK refuses. --override-review stays with a human running
#      swarm-merge.sh.
#   5. No migration collision (migration-collision-check.sh; 4 = no
#      migrations = pass).
#   6. CI green by a real bounded wait (ci-wait.sh; 5 = no CI configured =
#      pass with a warning, matching swarm-merge.sh Gate 2). Runs last so
#      the window between "green" and the merge stays short.
# Then `gh pr merge <N> --squash --match-head-commit <sha>` (never
# --delete-branch, see #489) and a SWARM_WORKER_MERGE audit comment. The
# watcher reaps the worktree afterwards, as for any merged PR.
#
# Exit codes: 0 merged, 1 usage/gh error, 2 refused by a gate.
#
# Action lock (ADR 0006 §3, issue #773): this script deliberately does NOT take
# swarm-merge.sh's coordinator action lock. It runs in the sandbox, which cannot
# reach the main worktree that holds the lock file, and --match-head-commit
# already makes a race with a locked merge fail safe (one side is refused).
#
# Test hooks: CI_WAIT_SCRIPT, MIGRATION_CHECK_SCRIPT.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_WAIT_SCRIPT="${CI_WAIT_SCRIPT:-$SCRIPT_DIR/ci-wait.sh}"
MIGRATION_CHECK_SCRIPT="${MIGRATION_CHECK_SCRIPT:-$SCRIPT_DIR/migration-collision-check.sh}"

usage() { echo "Usage: worker-merge.sh <PR#> --expect-head <sha> [--rating low|medium|high]" >&2; exit 1; }
refuse() { echo "worker-merge: REFUSED — $*" >&2; exit 2; }
# issue #1004: a hold-label refusal otherwise stays in this worker pane; tell the coordinator
# (outbox decision-needed = urgent) so a stale lock gets lifted. Best effort, never changes the exit.
refuse_hold() {
    local holds="$1" msg="$2" ob tmp
    ob="$(git rev-parse --show-toplevel 2>/dev/null)/.swarm/tasks/outbox"
    if mkdir -p "$ob" 2>/dev/null && tmp="$(mktemp -p "$ob" .tmp.XXXXXX 2>/dev/null)"; then
        printf -- '---\nkind: decision-needed\ntask_id: %s\nts: %s\n---\nworker-merge.sh refused the merge of PR #%s the operator asked for: it carries hold label(s) %s. If the hold is over, run scripts/lift-hold.sh %s "<why>" (comment, banner, label, ready in one call) and tell the operator to re-run the merge; if it should stay, nothing to do.\n' \
            "${TASK_ID:-worker-merge}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR" "$holds" "$PR" > "$tmp" 2>/dev/null \
            && mv -f "$tmp" "$ob/$(date -u +%Y%m%dT%H%M%SZ)-hold-refused.md" 2>/dev/null \
            || rm -f "$tmp" 2>/dev/null
    fi
    refuse "$msg"
}

PR="" EXPECT="" RATING="high"
while [ $# -gt 0 ]; do
    case "$1" in
        --expect-head) EXPECT="${2:-}"; shift 2 ;;
        --expect-head=*) EXPECT="${1#*=}"; shift ;;
        --rating) RATING="${2:-}"; shift 2 ;;
        --rating=*) RATING="${1#*=}"; shift ;;
        -h|--help) usage ;;
        -*) echo "worker-merge: unknown option $1 (there are no override flags)" >&2; usage ;;
        *) [ -z "$PR" ] || usage; PR="$1"; shift ;;
    esac
done
[[ "$PR" =~ ^[0-9]+$ ]] || usage
[[ "$EXPECT" =~ ^[0-9a-fA-F]{7,40}$ ]] || { echo "worker-merge: --expect-head needs ≥7 hex chars" >&2; usage; }
case "$RATING" in low|medium|high) ;; *) echo "worker-merge: --rating must be low, medium or high" >&2; usage ;; esac
command -v gh >/dev/null 2>&1 || { echo "worker-merge: gh required" >&2; exit 1; }

view() { gh pr view "$PR" --json "$1" -q "$2"; }

# Gate 1
STATE=$(view state .state) || { echo "worker-merge: gh pr view $PR failed" >&2; exit 1; }
[ "$STATE" = "OPEN" ] || refuse "PR #$PR is $STATE, not OPEN."
[ "$(view isDraft .isDraft)" = "false" ] || refuse "PR #$PR is a draft (the worker is still writing, or a hold placed before #612 — draft-as-hold PRs stay refused)."
# issue #612: the hold lock is a swarm-hold* label (CI, review BLOCK, coordinator
# or operator hold). Fails closed: an unreadable label list refuses.
HOLDS=$(view labels '[.labels[].name | select(test("^swarm-hold(:.*)?$"))] | join(", ")') \
    || refuse "could not read PR #$PR's labels, so the hold lock can't be checked."
[ -z "$HOLDS" ] || refuse_hold "$HOLDS" "PR #$PR carries a hold label ($HOLDS). A hold means someone (pr-ready.sh, the coordinator or the operator) said not to merge yet; only they lift it."
[ "$(view mergeable .mergeable)" != "CONFLICTING" ] || refuse "PR #$PR conflicts with its base."
BASE=$(view baseRefName .baseRefName)
DEFAULT=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name) || { echo "worker-merge: gh repo view failed" >&2; exit 1; }
[ "$BASE" = "$DEFAULT" ] || refuse "PR #$PR targets '$BASE', not the default branch '$DEFAULT'."

# Gate 2
HEAD=$(view headRefOid .headRefOid)
EXPECT_LC=$(printf '%s' "$EXPECT" | tr 'A-F' 'a-f')
case "$HEAD" in
    "$EXPECT_LC"*) ;;
    *) refuse "PR #$PR head is ${HEAD:0:12}, not the approved $EXPECT. New commits since the approval; ask again." ;;
esac

# Gate 3
view body .body | grep "<!-- BLIND_MERGE_RISK: $RATING -->" >/dev/null \
    || refuse "PR #$PR is not rated $RATING (<!-- BLIND_MERGE_RISK: $RATING --> missing). Re-read the rating and ask the operator again."

# Gate 4
VERDICT=$(view comments '[.comments[].body // "" | select(contains("SWARM_SELF_REVIEW:")) | capture("SWARM_SELF_REVIEW: (?<v>APPROVE_WITH_CAVEATS|APPROVE|BLOCK)").v] | last // empty')
[ -n "$VERDICT" ] || [ "$RATING" = low ] || refuse "no self-review verdict on PR #$PR. Run pr-ready.sh first."
[ "$VERDICT" != "BLOCK" ] || refuse "the latest self-review verdict on PR #$PR is BLOCK. Fix and re-push, or the operator overrides from a shell: swarm-merge.sh $PR --override-review."

# Gate 5
MRC=0; "$MIGRATION_CHECK_SCRIPT" "$PR" || MRC=$?
case "$MRC" in
    0|4) ;;
    2) refuse "migration collision on PR #$PR (see migration-collision-check.sh output above)." ;;
    *) refuse "migration-collision-check.sh exited $MRC (error); failing closed." ;;
esac

# Gate 6
CRC=0; "$CI_WAIT_SCRIPT" "$PR" || CRC=$?
case "$CRC" in
    0) ;;
    5) echo "worker-merge: WARNING — no CI configured on this repo; merging on the other gates alone." >&2 ;;
    *) refuse "CI is not green on PR #$PR (ci-wait.sh exit $CRC)." ;;
esac

# issue #612: a hold can land during the CI wait above (minutes); re-read the
# labels right before merging, same fail-closed rule as gate 1.
HOLDS=$(view labels '[.labels[].name | select(test("^swarm-hold(:.*)?$"))] | join(", ")') \
    || refuse "could not re-read PR #$PR's labels right before merging."
[ -z "$HOLDS" ] || refuse_hold "$HOLDS" "PR #$PR was put on hold ($HOLDS) while the gates ran. Nothing merged."

gh pr merge "$PR" --squash --match-head-commit "$HEAD" \
    || { echo "worker-merge: gh pr merge failed (head may have moved; nothing merged)" >&2; exit 1; }
gh pr comment "$PR" --body "<!-- SWARM_WORKER_MERGE: $RATING head=${HEAD:0:12} -->
Merged by the authoring worker on the operator's approval, at head \`${HEAD:0:12}\`, through \`worker-merge.sh\`. All gates passed: open, not draft, no hold label, default base, head match, rating $RATING, self-review ${VERDICT:-not run}, migrations $([ "$MRC" = 4 ] && echo "n/a" || echo clean), CI $([ "$CRC" = 5 ] && echo "not configured" || echo green). (#564)" >/dev/null 2>&1 \
    || echo "worker-merge: merged, but the audit comment failed to post" >&2
echo "worker-merge: merged PR #$PR at ${HEAD:0:12}."
