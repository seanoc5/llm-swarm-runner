#!/usr/bin/env bash
#
# test-lift-hold.sh — regression test for scripts/lift-hold.sh and the
# hold_refusal_inbox_note helper (issue #1004).
#
# The bug: lifting a coordinator hold by hand (comment, banner, `gh pr ready`)
# left the swarm-hold:coordinator label on the PR, so the operator's
# `merge PR N red` was refused by the hold-label gate. lift-hold.sh does the
# whole lift; this checks the end state (label gone, banner gone, lift comment
# posted, draft readied, body otherwise intact), the guards, and that a merge
# refusal leaves a coordinator inbox item. gh is a stateful PATH shim.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIFT="$SCRIPT_DIR/../scripts/lift-hold.sh"
[ -x "$LIFT" ] || red "lift-hold.sh not executable: $LIFT"

TEST_DIR=$(mktemp -d -t lift-hold-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/shims"
S="$TEST_DIR/state"; mkdir -p "$S"

# gh shim backed by files in $S: body, labels (one per line), draft, state,
# comments (appended), fail-* sentinels to force a failing step.
cat > "$TEST_DIR/shims/gh" <<EOF
#!/usr/bin/env bash
S="$S"
case "\$1 \$2" in
    "pr view")
        case "\$*" in
            *"--json state,isDraft,body"*)
                jq -n --arg s "\$(cat "\$S/state")" --argjson d "\$(cat "\$S/draft")" --rawfile b "\$S/body" '{state:\$s,isDraft:\$d,body:\$b}' ;;
            *"--json labels"*) cat "\$S/labels" ;;
        esac ;;
    "pr comment") [ ! -e "\$S/fail-comment" ] || exit 1
                  while [ \$# -gt 0 ]; do [ "\$1" = --body ] && { printf '%s\n----\n' "\$2" >> "\$S/comments"; break; }; shift; done ;;
    "pr edit")
        case "\$*" in
            *"--body-file -"*)       [ ! -e "\$S/fail-body" ] || exit 1; cat > "\$S/body" ;;
            *"--add-label "*)        printf '%s\n' "\${@: -1}" >> "\$S/labels" ;;
            *"--remove-label "*)     [ ! -e "\$S/fail-label" ] || exit 1
                                     grep -vxF -- "\${@: -1}" "\$S/labels" > "\$S/labels.new" || true; mv "\$S/labels.new" "\$S/labels" ;;
        esac ;;
    "pr ready") [ ! -e "\$S/fail-ready" ] || exit 1; echo false > "\$S/draft" ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/shims/gh"
# The shim reads labels via --jq '.labels[].name'; the real call pipes through
# gh's own --jq, which the shim doesn't implement, so it prints names directly.
export PATH="$TEST_DIR/shims:$PATH"

BANNER='> ⛔ **COORDINATOR HOLD** — fix brief queued to iss-12; do not merge.
> **Next:** worker iss-12 — push the fix — waiting on nothing
'
setup() {  # <draft true|false> <labels...>
    local draft="$1"; shift
    rm -f "$S"/fail-* "$S/comments"
    echo OPEN > "$S/state"; echo "$draft" > "$S/draft"
    : > "$S/labels"; for l in "$@"; do echo "$l" >> "$S/labels"; done
    {
        echo '<!-- BLIND_MERGE_RISK: high -->'
        printf '%s\n' "$BANNER"
        echo '**Bottom line:** the real body, which must survive the lift.'
        echo
        echo 'Second paragraph of the body.'
    } > "$S/body"
}
lift() { rc=0; "$LIFT" "$@" > "$TEST_DIR/out" 2>&1 || rc=$?; }

heading "lift-hold.sh (#1004)"

setup true swarm-hold:coordinator
lift 793 "fix verified"
[ "$rc" = 0 ] || red "full lift: expected exit 0, got $rc: $(cat "$TEST_DIR/out")"
! grep -q 'swarm-hold' "$S/labels" || red "swarm-hold:coordinator still on the PR after the lift: $(cat "$S/labels")"
! grep -q 'COORDINATOR HOLD' "$S/body" || red "banner still in the body: $(cat "$S/body")"
grep -q 'the real body, which must survive' "$S/body" && grep -q 'Second paragraph' "$S/body" && grep -q 'BLIND_MERGE_RISK: high' "$S/body" \
    || red "lift ate the rest of the body: $(cat "$S/body")"
grep -q '^✅ \*\*COORDINATOR HOLD lifted\*\* — fix verified$' "$S/comments" || red "lift comment missing or wrong: $(cat "$S/comments")"
grep -q '^<!-- SWARM_COORDINATOR_HOLD_LIFTED -->$' "$S/comments" || red "lift marker not on its own line"
[ "$(cat "$S/draft")" = false ] || red "draft PR was not readied"
green "label, banner and draft all cleared; body and risk marker intact; lift comment posted"

setup false swarm-hold:operator swarm-hold:ci
lift 793 "operator answered"
[ "$rc" = 0 ] || red "operator hold: expected exit 0, got $rc: $(cat "$TEST_DIR/out")"
[ "$(cat "$S/labels")" = "swarm-hold:ci" ] || red "must remove :operator and leave pr-ready's :ci, got: $(cat "$S/labels")"
grep -q 'still carries: swarm-hold:ci' "$TEST_DIR/out" || red "leftover :ci label not reported: $(cat "$TEST_DIR/out")"
green ":operator removed, pr-ready's :ci left alone and reported"

setup false swarm-hold:coordinator
lift 793 "again"; lift 793 "again"
[ "$rc" = 0 ] || red "second run: expected exit 0, got $rc"
green "re-running a lift is harmless"

setup false swarm-hold:coordinator
printf '# Title\n> ⛔ **COORDINATOR HOLD** — x\n' > "$S/body"
lift 793 "tiny body"
[ "$rc" = 0 ] || red "banner-only body: expected exit 0, got $rc: $(cat "$TEST_DIR/out")"
# runaway match (a long blockquote right after the banner) → refused, body untouched, exit 2
setup false swarm-hold:coordinator
{ echo "> ⛔ **COORDINATOR HOLD** — x"; for i in $(seq 1 15); do echo "> quoted line $i"; done; echo; echo ok; } > "$S/body"
cp "$S/body" "$S/body.orig"
lift 793 "guard"
[ "$rc" = 2 ] || red "size guard: expected exit 2, got $rc: $(cat "$TEST_DIR/out")"
cmp -s "$S/body" "$S/body.orig" || red "size guard still rewrote the body"
green "a banner strip that would eat over 10 lines is refused, body untouched, exit 2"

setup true swarm-hold:coordinator; touch "$S/fail-ready"
lift 793 "ready fails"
[ "$rc" = 2 ] || red "failed ready: expected exit 2, got $rc"
grep -q 'gh pr ready 793 failed' "$TEST_DIR/out" || red "failed ready not named: $(cat "$TEST_DIR/out")"
green "a failing step is named and exits 2"

setup false swarm-hold:coordinator; touch "$S/fail-comment"
lift 793 "no comment"
[ "$rc" = 1 ] || red "comment failure: expected exit 1, got $rc"
grep -q 'swarm-hold:coordinator' "$S/labels" && grep -q 'COORDINATOR HOLD' "$S/body" || red "comment failed, yet the lift went ahead"
green "no lift comment means nothing else changes (comment goes first)"

setup false swarm-hold:coordinator; echo MERGED > "$S/state"
lift 793 "closed"
[ "$rc" = 1 ] || red "merged PR: expected exit 1, got $rc"
green "a merged PR is refused"

lift abc "x"; [ "$rc" = 1 ] || red "non-numeric PR: expected exit 1, got $rc"
lift 793 "";  [ "$rc" = 1 ] || red "empty reason: expected exit 1, got $rc"
lift 793;     [ "$rc" = 1 ] || red "missing reason: expected exit 1, got $rc"
green "usage errors exit 1"

heading "hold_refusal_inbox_note (#1004)"
# shellcheck source=../scripts/_hold-label.sh
. "$SCRIPT_DIR/../scripts/_hold-label.sh"
INBOX="$TEST_DIR/coord-inbox"
f="$(hold_refusal_inbox_note "$INBOX" 793 "swarm-hold:coordinator" "swarm-merge.sh")"
[ -f "$f" ] || red "no inbox file written"
case "${f##*/}" in *-merge_refused-*.md) ;; *) red "unexpected inbox filename: $f" ;; esac
grep -q 'PR #793' "$f" && grep -q 'swarm-hold:coordinator' "$f" && grep -q 'lift-hold.sh 793' "$f" \
    || red "note must name the PR, the label and lift-hold.sh: $(cat "$f")"
ls -A "$INBOX" | grep -q '^\.tmp' && red "temp file left behind"
# Urgent by the inbox classifier: the kind must not be in a batched class.
# shellcheck source=../scripts/_coord-inbox-batch.sh
. "$SCRIPT_DIR/../scripts/_coord-inbox-batch.sh"
[ "$(coord_item_kind "$f")" = "merge_refused" ] || red "coord_item_kind did not read merge_refused from $f"
green "refusal writes a merge_refused inbox item naming PR, label and the lift script"

printf '\n\033[1;32m=== All lift-hold tests passed ===\033[0m\n'
