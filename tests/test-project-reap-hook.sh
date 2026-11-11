#!/usr/bin/env bash
#
# test-project-reap-hook.sh — issue #741: a project's .swarm/reap-hook.sh runs
# when a worktree is reaped, with the worktree path + issue, before removal;
# a missing hook is silent; a failing or hanging hook never blocks the reap.
set -euo pipefail
red() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
HELPER="$SCRIPT_DIR/../scripts/_project-reap-hook.sh"
TEST_DIR=$(mktemp -d -t reap-hook-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export SWARM_WORKTREE_GROUPING=flat
unset SWARM_REAP_HOOK

setup() { # $1 = case name; sets PROJ, WT
    PROJ="$TEST_DIR/$1/proj"; mkdir -p "$PROJ"
    git init -q "$PROJ"
    git -C "$PROJ" config user.email t@example.com
    git -C "$PROJ" config user.name T
    echo hi > "$PROJ/README.md"; git -C "$PROJ" add README.md
    git -C "$PROJ" commit -q -m init
    WT="$TEST_DIR/$1/wt-issue-741"
    git -C "$PROJ" worktree add -q -b fix/issue-741 "$WT"
    mkdir -p "$PROJ/.swarm"
}
reap() { (cd "$PROJ" && "$KILL_WT" 741 "$PROJ" --no-compose-down) > "$TEST_DIR/run.log" 2>&1; }

# --- Case 1: hook runs once, sees path + issue, worktree still present ------
setup ok
cat > "$PROJ/.swarm/reap-hook.sh" <<HOOK
#!/usr/bin/env bash
echo "\$1 \$2 \$SWARM_REAP_ISSUE \$SWARM_REAP_PROJECT_DIR present=\$([ -d "\$1" ] && echo yes || echo no)" >> "$TEST_DIR/hook.log"
HOOK
chmod +x "$PROJ/.swarm/reap-hook.sh"
reap || red "ok: reap failed: $(cat "$TEST_DIR/run.log")"
[ "$(wc -l < "$TEST_DIR/hook.log")" -eq 1 ] || red "ok: hook should run exactly once"
grep -qx "$WT 741 741 $PROJ present=yes" "$TEST_DIR/hook.log" || red "ok: wrong hook args: $(cat "$TEST_DIR/hook.log")"
[ ! -d "$WT" ] || red "ok: worktree not removed"
green "hook runs once with worktree path + issue, before removal"

# --- Case 2: no hook file: silent, reap proceeds ----------------------------
setup none
reap || red "none: reap failed"
grep -q "reap hook" "$TEST_DIR/run.log" && red "none: should not mention a hook"
[ ! -d "$WT" ] || red "none: worktree not removed"
green "no hook: silent, worktree removed"

# --- Case 3: failing hook warns but the reap still completes ----------------
setup fail
printf '#!/usr/bin/env bash\nexit 7\n' > "$PROJ/.swarm/reap-hook.sh"; chmod +x "$PROJ/.swarm/reap-hook.sh"
reap || red "fail: a failing hook must not fail the reap: $(cat "$TEST_DIR/run.log")"
grep -q "reap hook exited 7" "$TEST_DIR/run.log" || red "fail: no warning in output"
[ ! -d "$WT" ] || red "fail: worktree not removed"
green "failing hook: warning, worktree still removed"

# --- Case 4: hanging hook is bounded by SWARM_REAP_HOOK_TIMEOUT -------------
setup hang
printf '#!/usr/bin/env bash\nsleep 30\n' > "$PROJ/.swarm/reap-hook.sh"; chmod +x "$PROJ/.swarm/reap-hook.sh"
t0=$(date +%s)
SWARM_REAP_HOOK_TIMEOUT=1 "$HELPER" "$WT" 741 "$PROJ" >/dev/null 2>&1 && red "hang: expected non-zero" || true
[ $(( $(date +%s) - t0 )) -lt 20 ] || red "hang: hook not bounded"
green "hanging hook is killed at the timeout"
