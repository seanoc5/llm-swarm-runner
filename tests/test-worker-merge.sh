#!/usr/bin/env bash
#
# test-worker-merge.sh — regression test for scripts/worker-merge.sh (#564):
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
        esac ;;
    "repo view") echo master ;;
    "pr merge"|"pr comment") exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit "${CI_RC:-0}"\n'  > "$TEST_DIR/ci-wait"
printf '#!/usr/bin/env bash\nexit "${MIG_RC:-0}"\n' > "$TEST_DIR/mig-check"
chmod +x "$TEST_DIR/shims/gh" "$TEST_DIR/ci-wait" "$TEST_DIR/mig-check"
export PATH="$TEST_DIR/shims:$PATH" CI_WAIT_SCRIPT="$TEST_DIR/ci-wait" MIGRATION_CHECK_SCRIPT="$TEST_DIR/mig-check"

# run <expected-rc> <description> [env assignments...] -- <args...>
run() {
    local want="$1" desc="$2"; shift 2
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
    : > "$GH_LOG"
    local rc=0
    env "${envs[@]}" "$WM" "$@" > "$TEST_DIR/out" 2>&1 || rc=$?
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
run 1 "override flags don't exist"                                  -- 7 --expect-head abcdef1 --override-review
run 1 "missing --expect-head is a usage error"                      -- 7
run 1 "too-short SHA is a usage error"                              -- 7 --expect-head abc

printf '\n\033[1;32m=== All worker-merge.sh tests passed ===\033[0m\n'
