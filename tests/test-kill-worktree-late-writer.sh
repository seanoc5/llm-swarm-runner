#!/usr/bin/env bash
#
# test-kill-worktree-late-writer.sh — Non-LLM regression test for issue
# #795: a watcher/listener recreated .swarm/tasks/status/pr-issue-N.check.json
# AFTER kill-worktree.sh archived .swarm/, so `git worktree remove` failed
# ("Directory not empty") and the run exited without closing the window.
# Simulated with a git shim whose FIRST `worktree remove` recreates the stub
# and fails; kill-worktree.sh must archive the stub, retry, and succeed.
set -euo pipefail
red() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
REAL_GIT="$(command -v git)"
TEST_DIR=$(mktemp -d -t kill-wt-late-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

PROJ="$TEST_DIR/proj"; mkdir -p "$PROJ"
"$REAL_GIT" init -q "$PROJ"
"$REAL_GIT" -C "$PROJ" config user.email t@example.com
"$REAL_GIT" -C "$PROJ" config user.name T
echo hi > "$PROJ/README.md"; "$REAL_GIT" -C "$PROJ" add README.md; "$REAL_GIT" -C "$PROJ" commit -q -m init
export SWARM_WORKTREE_GROUPING=flat
WT="$TEST_DIR/wt-issue-795"
"$REAL_GIT" -C "$PROJ" worktree add -q -b fix/issue-795 "$WT"
mkdir -p "$WT/.swarm/logs"; echo x > "$WT/.swarm/logs/a.log"

mkdir -p "$TEST_DIR/shim"
cat > "$TEST_DIR/shim/git" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = worktree ] && [ "\${2:-}" = remove ] && [ ! -e "$TEST_DIR/shim/fired" ]; then
    touch "$TEST_DIR/shim/fired"
    mkdir -p "$WT/.swarm/tasks/status"
    echo '{}' > "$WT/.swarm/tasks/status/pr-issue-795.check.json"
    echo "error: failed to delete '$WT': Directory not empty" >&2
    exit 1
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TEST_DIR/shim/git"

# tmux shim: never touch a real session. Session exists, window iss-795
# listed, kill-window recorded.
cat > "$TEST_DIR/shim/tmux" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
    has-session) exit 0 ;;
    list-windows) echo iss-795; exit 0 ;;
    kill-window) echo "\$*" >> "$TEST_DIR/killed"; exit 0 ;;
esac
exit 0
SHIM
chmod +x "$TEST_DIR/shim/tmux"

set +e
(cd "$PROJ" && PATH="$TEST_DIR/shim:$PATH" "$KILL_WT" 795 "$PROJ") > "$TEST_DIR/run.log" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || red "expected exit 0, got $RC: $(cat "$TEST_DIR/run.log")"
[ -e "$TEST_DIR/shim/fired" ] || red "shim never fired"
[ ! -d "$WT" ] || red "worktree still present"
green "worktree removed after late-writer retry"
[ -s "$TEST_DIR/killed" ] || red "tmux window not closed on success: $(cat "$TEST_DIR/run.log")"
green "tmux window closed (via shim)"
ls "$PROJ"/.swarm/reaped/ | grep -q 'swarm-late$' || red "late stub not archived: $(ls "$PROJ/.swarm/reaped")"
find "$PROJ"/.swarm/reaped/*swarm-late -name 'pr-issue-795.check.json' | grep -q . || red "stub file missing from archive"
green "late stub archived, not destroyed"
