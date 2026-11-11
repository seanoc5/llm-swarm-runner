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

# --- Case 5: grace deferral keeps the worktree, so the hook must NOT run ----
setup grace
mkdir -p "$TEST_DIR/shim"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/shim/gh"; cp "$TEST_DIR/shim/gh" "$TEST_DIR/shim/tmux"
chmod +x "$TEST_DIR/shim/gh" "$TEST_DIR/shim/tmux"
git init -q --bare "$TEST_DIR/grace/origin.git"; git -C "$PROJ" remote add origin "$TEST_DIR/grace/origin.git"
git -C "$PROJ" push -q origin HEAD:refs/heads/master 2>/dev/null || true
echo unpushed > "$WT/unpushed.txt"; git -C "$WT" add unpushed.txt; git -C "$WT" commit -q -m unpushed
cat > "$PROJ/.swarm/reap-hook.sh" <<HOOK
#!/usr/bin/env bash
echo ran >> "$TEST_DIR/grace-hook.log"
HOOK
chmod +x "$PROJ/.swarm/reap-hook.sh"
set +e
(cd "$PROJ" && PATH="$TEST_DIR/shim:$PATH" SWARM_REAP_GRACE_SECS=3600 "$KILL_WT" 741 "$PROJ" --no-compose-down --grace) > "$TEST_DIR/run.log" 2>&1
rc=$?; set -e
[ "$rc" -eq 75 ] || red "grace: expected exit 75 (deferred), got $rc: $(cat "$TEST_DIR/run.log")"
[ -d "$WT" ] || red "grace: worktree should be kept"
[ ! -e "$TEST_DIR/grace-hook.log" ] || red "grace: hook ran although the worktree was kept"
green "grace deferral: worktree kept, hook not run"

# --- Case 6 (issue #889): worktree folder already gone: hook still runs -----
setup gone
cat > "$PROJ/.swarm/reap-hook.sh" <<HOOK
#!/usr/bin/env bash
echo "\$1 \$2 present=\$([ -d "\$1" ] && echo yes || echo no)" >> "$TEST_DIR/gone-hook.log"
HOOK
chmod +x "$PROJ/.swarm/reap-hook.sh"
rm -rf "$WT"; git -C "$PROJ" worktree prune
reap || red "gone: reap failed: $(cat "$TEST_DIR/run.log")"
[ -f "$TEST_DIR/gone-hook.log" ] || red "gone: hook did not run for a missing folder: $(cat "$TEST_DIR/run.log")"
[ "$(wc -l < "$TEST_DIR/gone-hook.log")" -eq 1 ] || red "gone: hook should run exactly once"
grep -qx "$WT 741 present=no" "$TEST_DIR/gone-hook.log" || red "gone: wrong hook args: $(cat "$TEST_DIR/gone-hook.log")"
green "missing folder: hook still runs once with path + issue"

# --- Case 7 (issue #889): reap_dangling call site runs the hook -------------
setup dangling
REAP_ORPHAN="$SCRIPT_DIR/../scripts/reap-orphan-worktrees.sh"
cat > "$PROJ/.swarm/reap-hook.sh" <<HOOK
#!/usr/bin/env bash
echo "\$1 \$2" >> "$TEST_DIR/dangling-hook.log"
HOOK
chmod +x "$PROJ/.swarm/reap-hook.sh"
rm -rf "$PROJ/.git/worktrees/$(basename "$WT")"
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 && red "dangling: fixture did not corrupt the registration"
mkdir -p "$TEST_DIR/fakebin"
cat > "$TEST_DIR/fakebin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then printf 'fix/issue-741\tMERGED\n'; exit 0; fi
exit 1
FAKEGH
chmod +x "$TEST_DIR/fakebin/gh"
set +e
(cd "$PROJ" && PATH="$TEST_DIR/fakebin:$PATH" "$REAP_ORPHAN" --yes --min-age-days 0 --project "$PROJ") > "$TEST_DIR/run.log" 2>&1
rc=$?; set -e
[ "$rc" -eq 0 ] || red "dangling: reap-orphan exit $rc: $(cat "$TEST_DIR/run.log")"
[ ! -d "$WT" ] || red "dangling: worktree not removed: $(cat "$TEST_DIR/run.log")"
[ -f "$TEST_DIR/dangling-hook.log" ] || red "dangling: hook did not run: $(cat "$TEST_DIR/run.log")"
grep -qx "$WT 741" "$TEST_DIR/dangling-hook.log" || red "dangling: wrong hook args: $(cat "$TEST_DIR/dangling-hook.log")"
green "dangling registration: reap_dangling runs the hook with path + issue"
