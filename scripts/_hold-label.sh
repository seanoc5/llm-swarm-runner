#!/usr/bin/env bash
#
# _hold-label.sh — the `swarm-hold` merge lock (issue #612).
#
# Draft used to mean four things: the worker is still writing, CI is pending,
# self-review said BLOCK, or the coordinator/operator is holding the PR. Draft
# now means only "the worker is still writing". Every other gate is a label
# plus the PR-body banner (SWARM_DRAFT_REASON or COORDINATOR HOLD), and every
# merge path this repo owns refuses a PR that carries any `swarm-hold*` label:
# swarm-merge.sh (plain and --auto-*), worker-merge.sh, queue-merge-brief.sh.
#
# Labels (one per reason, so a reader sees why in the PR list; the lock is the
# shared `swarm-hold` prefix, so a bare `swarm-hold` counts too):
#   swarm-hold:ci           pr-ready.sh owns it: CI pending/unreadable/red/cancelled
#                           or the project's pre-ready check failed. Removed by
#                           pr-ready.sh when it readies the PR.
#   swarm-hold:review       pr-ready.sh owns it: self-review BLOCK or failure.
#                           Removed by pr-ready.sh when it readies the PR.
#   swarm-hold:coordinator  the coordinator's hold (fix round-trip queued).
#                           Applied with the COORDINATOR HOLD banner; only the
#                           coordinator lifts it. pr-ready.sh never removes it.
#   swarm-hold:operator     an open decision for the operator. Same rules.
#
# Known gap, accepted by the operator (#612): the GitHub web UI and a raw
# `gh pr merge` ignore labels. A required status check can close it per repo
# later.
#
# Sourced, not executed: `. "$SCRIPT_DIR/_hold-label.sh"`. Needs gh and jq.
#
# Functions:
#   hold_label_ensure <name>
#       Creates the label if the repo lacks it. Idempotent: an existing label
#       makes `gh label create` fail, which is swallowed on purpose.
#   hold_label_names <pr>
#       Prints the PR's swarm-hold* label names, one per line. Returns 1 when
#       gh could not be read (callers that GATE a merge treat that as a refusal).
#   hold_label_add <pr> <name>
#       Ensures the label exists, then applies it unless already on the PR.
#   hold_label_remove <pr> <name>
#       Removes the label if the PR carries it.
#   hold_label_manual_present <pr>
#       True when the PR carries a hold label pr-ready.sh does NOT own
#       (coordinator, operator, or the bare name). Lookup failure = false.
#
# HOLD_LABEL_JQ_PRED is a jq boolean over a `gh pr view|list --json labels`
# object for callers that already hold that JSON.

HOLD_LABEL_CI="swarm-hold:ci"
HOLD_LABEL_REVIEW="swarm-hold:review"
HOLD_LABEL_COORDINATOR="swarm-hold:coordinator"
HOLD_LABEL_OPERATOR="swarm-hold:operator"
HOLD_LABEL_RE='^swarm-hold(:.*)?$'
# shellcheck disable=SC2034  # consumed by callers that source this file
HOLD_LABEL_JQ_PRED='any((.labels // [])[]; (.name // "") | test("^swarm-hold(:.*)?$"))'

hold_label_describe() {
    case "$1" in
        "$HOLD_LABEL_CI")          echo "Merge lock: CI not confirmed green (pr-ready.sh removes it when it readies the PR)" ;;
        "$HOLD_LABEL_REVIEW")      echo "Merge lock: self-review BLOCK (pr-ready.sh removes it when it readies the PR)" ;;
        "$HOLD_LABEL_COORDINATOR") echo "Merge lock: coordinator hold (the coordinator lifts it)" ;;
        "$HOLD_LABEL_OPERATOR")    echo "Merge lock: waiting on an operator decision" ;;
        *)                         echo "Merge lock: swarm tooling will not merge this PR" ;;
    esac
}

hold_label_ensure() {
    gh label create "$1" --description "$(hold_label_describe "$1")" --color B60205 >/dev/null 2>&1 || true
}

hold_label_names() {
    local out
    out="$(gh pr view "$1" --json labels --jq '.labels[].name' 2>/dev/null)" || return 1
    grep -E "$HOLD_LABEL_RE" <<<"$out" || true
}

hold_label_add() {
    local pr="$1" name="$2" have
    if have="$(hold_label_names "$pr")" && grep -qxF "$name" <<<"$have"; then
        return 0
    fi
    hold_label_ensure "$name"
    gh pr edit "$pr" --add-label "$name" >/dev/null 2>&1 \
        || { echo "hold-label: WARN: couldn't add '$name' to PR #$pr" >&2; return 1; }
}

hold_label_remove() {
    local pr="$1" name="$2" have
    have="$(hold_label_names "$pr")" || return 1
    grep -qxF "$name" <<<"$have" || return 0
    gh pr edit "$pr" --remove-label "$name" >/dev/null 2>&1 \
        || { echo "hold-label: WARN: couldn't remove '$name' from PR #$pr" >&2; return 1; }
}

hold_label_manual_present() {
    local have
    have="$(hold_label_names "$1")" || return 1
    # Captured, not piped into `grep -q`: an early-exit reader races SIGPIPE under pipefail.
    local manual
    manual="$(grep -vxF -e "$HOLD_LABEL_CI" -e "$HOLD_LABEL_REVIEW" <<<"$have" || true)"
    [ -n "$manual" ]
}
