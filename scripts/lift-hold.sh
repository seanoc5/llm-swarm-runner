#!/usr/bin/env bash
#
# lift-hold.sh — lift a COORDINATOR HOLD in one call (issue #1004).
#
# Usage: lift-hold.sh <PR#> "<why>"
#
# The hand-run lift was four steps (comment, banner, label, ready) and the
# label step got forgotten: SAMlytics PR #793 stayed locked by a leftover
# swarm-hold:coordinator after its hold was "lifted", and the operator's
# `merge PR 793 red` was refused by the hold-label gate. This does all four, in
# the order that matters:
#   1. posts `✅ **COORDINATOR HOLD lifted** — <why>` ending with the
#      SWARM_COORDINATOR_HOLD_LIFTED marker. FIRST, because a newer hold
#      comment makes pr-ready.sh restore the banner and label (#616).
#   2. strips the `> ⛔ **COORDINATOR HOLD**` banner block from the PR body
#      (the banner line and the `>` lines right after it, plus one blank line).
#      Guarded: a result that is empty or lost more than 10 lines is not
#      written, because a bad edit once wiped a body.
#   3. removes swarm-hold:coordinator and swarm-hold:operator. It never touches
#      swarm-hold:ci / :review: pr-ready.sh owns those.
#   4. `gh pr ready` if the PR is a draft.
# Then prints which swarm-hold* labels remain, if any (the PR is still not
# mergeable while one does).
#
# Idempotent: a second run posts one more comment and changes nothing else.
# Exit codes: 0 lifted, 1 usage/gh error before anything changed, 2 a step
# after the comment failed (the output names it; re-run or finish by hand).
#
# Needs gh and jq (gh is stubbed via PATH in tests).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_hold-label.sh
. "$SCRIPT_DIR/_hold-label.sh"

usage() { echo 'Usage: lift-hold.sh <PR#> "<why>"' >&2; exit 1; }

PR="${1:-}" WHY="${2:-}"
[ $# -eq 2 ] || usage
[[ "$PR" =~ ^[0-9]+$ ]] || usage
[ -n "${WHY//[[:space:]]/}" ] || { echo "lift-hold: the reason can't be empty (it goes in the lift comment)" >&2; usage; }
command -v gh >/dev/null 2>&1 || { echo "lift-hold: gh required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "lift-hold: jq required" >&2; exit 1; }

JSON="$(gh pr view "$PR" --json state,isDraft,body 2>/dev/null)" \
    || { echo "lift-hold: gh pr view $PR failed" >&2; exit 1; }
STATE="$(jq -r '.state' <<<"$JSON")"
[ "$STATE" = "OPEN" ] || { echo "lift-hold: PR #$PR is $STATE, not OPEN — nothing to lift" >&2; exit 1; }
IS_DRAFT="$(jq -r '.isDraft' <<<"$JSON")"
BODY="$(jq -r '.body // ""' <<<"$JSON")"

FAILED=0
fail() { echo "lift-hold: FAILED — $*" >&2; FAILED=1; }

# 1. Lift comment first.
COMMENT="$(printf '✅ **COORDINATOR HOLD lifted** — %s\n\n<!-- SWARM_COORDINATOR_HOLD_LIFTED -->' "$WHY")"
gh pr comment "$PR" --body "$COMMENT" >/dev/null 2>&1 \
    || { echo "lift-hold: couldn't post the lift comment on PR #$PR; nothing changed" >&2; exit 1; }
echo "lift-hold: posted the lift comment on PR #$PR"

# 2. Banner out of the body.
BANNER_RE='^> ⛔ \*\*COORDINATOR HOLD\*\*'
if grep -qE "$BANNER_RE" <<<"$BODY"; then
    NEW_BODY="$(BANNER_RE="$BANNER_RE" awk '
        skipping && /^>/ { next }
        skipping { skipping = 0; if ($0 ~ /^[[:space:]]*$/) next }
        $0 ~ ENVIRON["BANNER_RE"] { skipping = 1; next }
        { print }
    ' <<<"$BODY")"
    OLD_LINES="$(wc -l <<<"$BODY")"; NEW_LINES="$(wc -l <<<"$NEW_BODY")"
    # A banner is a few lines; losing more than 10 means the match ran away.
    if [ -z "${NEW_BODY//[[:space:]]/}" ] || [ $((OLD_LINES - NEW_LINES)) -gt 10 ]; then
        fail "stripping the banner would cut PR #$PR's body from $OLD_LINES to $NEW_LINES lines (a banner is under 10); body left alone, remove the banner by hand"
    elif gh pr edit "$PR" --body-file - <<<"$NEW_BODY" >/dev/null 2>&1; then
        echo "lift-hold: removed the hold banner from the body ($OLD_LINES -> $NEW_LINES lines)"
    else
        fail "couldn't rewrite PR #$PR's body (banner still there)"
    fi
else
    echo "lift-hold: no hold banner in the body (nothing to strip)"
fi

# 3. Labels. hold_label_remove is a no-op when the label is absent.
for lbl in "$HOLD_LABEL_COORDINATOR" "$HOLD_LABEL_OPERATOR"; do
    hold_label_remove "$PR" "$lbl" || fail "couldn't remove $lbl from PR #$PR"
done

# 4. Re-ready.
if [ "$IS_DRAFT" = "true" ]; then
    if gh pr ready "$PR" >/dev/null 2>&1; then
        echo "lift-hold: marked PR #$PR ready for review"
    else
        fail "gh pr ready $PR failed (PR is still a draft)"
    fi
fi

# Verify from a fresh read, not from the commands' exit codes.
if LEFT="$(hold_label_names "$PR")"; then
    if [ -n "$LEFT" ]; then
        echo "lift-hold: PR #$PR still carries: $(paste -sd, <<<"$LEFT") — still not mergeable until that clears (pr-ready.sh owns :ci and :review)"
        if grep -qE '^swarm-hold:(ci|review)$' <<<"$LEFT"; then
            echo "lift-hold: next: run pr-ready.sh $PR once (it removes :ci/:review when CI is green); --auto-low refuses until then"
        fi
    else
        echo "lift-hold: PR #$PR carries no swarm-hold* label"
    fi
else
    fail "couldn't re-read PR #$PR's labels to verify"
fi

[ "$FAILED" = 0 ] || exit 2
echo "lift-hold: PR #$PR hold lifted"
