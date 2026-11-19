#!/usr/bin/env bash
#
# test-worker-merge.sh — regression test for scripts/worker-merge.sh (#564, all ratings):
# the gated path a worker uses to merge its own 🔴 PR on the operator's
# explicit `merge PR <N> red`. gh is a PATH shim driven by env vars;
# ci-wait.sh and migration-collision-check.sh are replaced via the script's
# CI_WAIT_SCRIPT / MIGRATION_CHECK_SCRIPT hooks.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WM="$SCRIPT_DIR/../scripts/worker-merge.sh"
[ -x "$WM" ] || red "worker-merge.sh not executable: $WM"

TEST_DIR=$(mktemp -d -t worker-merge-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/shims"
GH_LOG="$TEST_DIR/gh.log"

cat > "$TEST_DIR/shims/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$1 \$2" in
    "pr view")
        case "\$*" in
            *"--json state "*)       echo "\${GH_STATE:-OPEN}" ;;
            *"--json isDraft "*)     echo "\${GH_DRAFT:-false}" ;;
            *"--json mergeable "*)   echo "\${GH_MERGEABLE:-MERGEABLE}" ;;
            *"--json baseRefName "*) echo "\${GH_BASE:-master}" ;;
            *"--json headRefOid "*)  echo "\${GH_HEAD:-abcdef1234567890abcdef1234567890abcdef12}" ;;
            *"--json body "*)        printf '<!-- BLIND_MERGE_RISK: %s -->\nbody\n' "\${GH_RISK:-high}" ;;
            *"--json comments "*)    echo "\${GH_VERDICT-APPROVE}" ;;
            # issue #612: the script's own --jq joins the swarm-hold* names with ", ",
            # so the stub answers that result. 2nd+ read returns GH_LABELS_LATE if set
            # (a hold landing during the gates).
            *"--json labels "*)      n=\$(cat "$TEST_DIR/labels.calls" 2>/dev/null || echo 0); echo \$((n+1)) > "$TEST_DIR/labels.calls"
                                    if [ "\$n" -ge 1 ] && [ -n "\${GH_LABELS_LATE:-}" ]; then echo "\$GH_LABELS_LATE"; else echo "\${GH_LABELS-}"; fi ;;
        esac ;;
    "repo view") echo master ;;
    "pr merge"|"pr comment") exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit "${CI_RC:-0}"\n'  > "$TEST_DIR/ci-wait"
printf '#!/usr/bin/env bash\nexit "${MIG_RC:-0}"\n' > "$TEST_DIR/mig-check"
chmod +x "$TEST_DIR/shims/gh" "$TEST_DIR/ci-wait" "$TEST_DIR/mig-check"
export PATH="$TEST_DIR/shims:$PATH" CI_WAIT_SCRIPT="$TEST_DIR/ci-wait" MIGRATION_CHECK_SCRIPT="$TEST_DIR/mig-check"
# issue #1004: a hold refusal writes an outbox note under the repo toplevel; run in a scratch repo, not the real worktree.
REPO="$TEST_DIR/repo"; git init -q "$REPO"
OUTBOX="$REPO/.swarm/tasks/outbox"

# run <expected-rc> <description> [env assignments...] -- <args...>
run() {
    local want="$1" desc="$2"; shift 2
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
    : > "$GH_LOG"; rm -f "$TEST_DIR/labels.calls"
    local rc=0
    (cd "$REPO" && env "${envs[@]}" "$WM" "$@") > "$TEST_DIR/out" 2>&1 || rc=$?
    [ "$rc" = "$want" ] || red "$desc: expected exit $want, got $rc. Output: $(cat "$TEST_DIR/out")"
    if [ "$want" = 0 ]; then
        grep -q -- "pr merge 7 --squash --match-head-commit abcdef1234567890" "$GH_LOG" \
            || red "$desc: merge not called with --match-head-commit. gh log: $(cat "$GH_LOG")"
    else
        ! grep -q "pr merge" "$GH_LOG" || red "$desc: refused, yet gh pr merge was called"
    fi
    green "$desc"
}

heading "worker-merge.sh gates (#564)"
run 0 "all gates pass → squash merge bound to the head SHA"        -- 7 --expect-head abcdef1
run 0 "uppercase SHA prefix still matches"                          -- 7 --expect-head ABCDEF1
run 0 "no CI configured (ci-wait exit 5) passes with a warning"     CI_RC=5 -- 7 --expect-head abcdef1
run 0 "no migrations (check exit 4) passes"                         MIG_RC=4 -- 7 --expect-head abcdef1
run 2 "head moved since approval → refused"                         GH_HEAD=9999999aaaa -- 7 --expect-head abcdef1
run 2 "rating medium → refused (this path is 🔴 only)"              GH_RISK=medium -- 7 --expect-head abcdef1
run 2 "latest self-review BLOCK → refused"                          GH_VERDICT=BLOCK -- 7 --expect-head abcdef1
run 2 "no self-review on record → refused"                          GH_VERDICT= -- 7 --expect-head abcdef1
run 2 "CI failing → refused"                                        CI_RC=1 -- 7 --expect-head abcdef1
run 2 "CI still pending at timeout → refused"                       CI_RC=2 -- 7 --expect-head abcdef1
run 2 "migration collision → refused"                               MIG_RC=2 -- 7 --expect-head abcdef1
run 2 "migration check error → refused (fail closed)"               MIG_RC=1 -- 7 --expect-head abcdef1
run 2 "draft (coordinator hold) → refused"                          GH_DRAFT=true -- 7 --expect-head abcdef1
run 2 "conflicting → refused"                                       GH_MERGEABLE=CONFLICTING -- 7 --expect-head abcdef1
run 2 "not the default branch → refused"                            GH_BASE=feature-x -- 7 --expect-head abcdef1
run 2 "already merged → refused"                                    GH_STATE=MERGED -- 7 --expect-head abcdef1
heading "hold label lock (#612)"
run 2 "swarm-hold:ci label → refused"            GH_LABELS=swarm-hold:ci -- 7 --expect-head abcdef1 --rating high
grep -q "hold label (swarm-hold:ci)" "$TEST_DIR/out" || red "expected the label named in the refusal: $(cat "$TEST_DIR/out")"
run 2 "swarm-hold:coordinator label → refused"   GH_LABELS=swarm-hold:coordinator -- 7 --expect-head abcdef1 --rating high
run 2 "hold lands during the gates → refused"    GH_LABELS_LATE=swarm-hold:operator -- 7 --expect-head abcdef1 --rating high
grep -q "put on hold" "$TEST_DIR/out" || red "expected the late-hold refusal: $(cat "$TEST_DIR/out")"
run 0 "no hold label → merges"                   GH_LABELS= -- 7 --expect-head abcdef1 --rating high
green "hold labels refuse the merge, before and after the CI wait"

heading "hold refusal notifies the coordinator (#1004)"
rm -rf "$OUTBOX"
run 2 "stale swarm-hold:coordinator → refused" TASK_ID=t-1004 GH_LABELS=swarm-hold:coordinator -- 7 --expect-head abcdef1 --rating high
note="$(ls "$OUTBOX"/*-hold-refused.md 2>/dev/null | head -1)"
[ -n "$note" ] || red "no outbox note after a hold-label refusal"
grep -q "^kind: decision-needed" "$note" || red "outbox note is not decision-needed: $(cat "$note")"
grep -q "^task_id: t-1004" "$note" || red "outbox note lacks the task id: $(cat "$note")"
grep -q "swarm-hold:coordinator" "$note" && grep -q "lift-hold.sh 7" "$note" || red "outbox note must name the label and lift-hold.sh: $(cat "$note")"
rm -rf "$OUTBOX"
run 0 "no hold label → merges, no note" GH_LABELS= -- 7 --expect-head abcdef1 --rating high
[ ! -e "$OUTBOX" ] || red "a clean merge wrote an outbox note"
green "refusal on a hold label leaves a decision-needed outbox note naming lift-hold.sh"

heading "🟢/🟡 through the same gates"
run 0 "🟢 low, no self-review on record (pr-ready skips it) → merges" GH_RISK=low GH_VERDICT= -- 7 --expect-head abcdef1 --rating low
run 0 "🟡 medium with APPROVE → merges"                              GH_RISK=medium -- 7 --expect-head abcdef1 --rating medium
run 2 "🟢 low but latest self-review BLOCK → refused"               GH_RISK=low GH_VERDICT=BLOCK -- 7 --expect-head abcdef1 --rating low
run 2 "🟡 medium with no self-review → refused"                      GH_RISK=medium GH_VERDICT= -- 7 --expect-head abcdef1 --rating medium
run 2 "--rating low on a PR actually rated high → refused"          -- 7 --expect-head abcdef1 --rating low
run 2 "--rating medium on a PR rated low → refused"                 GH_RISK=low -- 7 --expect-head abcdef1 --rating medium
run 2 "🟢 low, CI failing → refused"                                 GH_RISK=low CI_RC=1 -- 7 --expect-head abcdef1 --rating low
run 2 "🟢 low, migration collision → refused"                        GH_RISK=low MIG_RC=2 -- 7 --expect-head abcdef1 --rating low
run 1 "unknown --rating value is a usage error"                     -- 7 --expect-head abcdef1 --rating urgent

heading "usage"
run 1 "override flags don't exist"                                -- 7 --expect-head abcdef1 --override-review
run 1 "missing --expect-head is a usage error"                      -- 7
run 1 "too-short SHA is a usage error"                              -- 7 --expect-head abc

printf '\n\033[1;32m=== All worker-merge.sh tests passed ===\033[0m\n'
