#!/usr/bin/env bash
#
# test-kill-worktree-removal-failure.sh — issue #795 double-failure pins.
# Case 1 (late writer): git's removal fails twice (stub recreated each time).
#   Expect exit 1, the tmux window closed, reap.worktree.error logged, and
#   the first late stub archived.
# Case 2 (other failure, no .swarm/ present): removal fails once for a
#   non-late-writer reason. Expect exit 1 and the tmux window LEFT OPEN
#   (the worktree may still have a live worker).
set -euo pipefail
red() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
REAL_GIT="$(command -v git)"
TEST_DIR=$(mktemp -d -t kill-wt-fail-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/shim"
# tmux shim: session exists, window iss-795 listed, kill-window recorded.
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

setup() { # $1 = case name; sets PROJ, WT
    PROJ="$TEST_DIR/$1/proj"; mkdir -p "$PROJ"
    "$REAL_GIT" init -q "$PROJ"
    "$REAL_GIT" -C "$PROJ" config user.email t@example.com
    "$REAL_GIT" -C "$PROJ" config user.name T
    echo hi > "$PROJ/README.md"; "$REAL_GIT" -C "$PROJ" add README.md
    "$REAL_GIT" -C "$PROJ" commit -q -m init
    WT="$TEST_DIR/$1/wt-issue-795"
    "$REAL_GIT" -C "$PROJ" worktree add -q -b fix/issue-795 "$WT"
    rm -f "$TEST_DIR/killed"
}
run() {
    set +e
    (cd "$PROJ" && PATH="$TEST_DIR/shim:$PATH" SWARM_WORKTREE_GROUPING=flat "$KILL_WT" 795 "$PROJ") > "$TEST_DIR/run.log" 2>&1
    RC=$?
    set -e
}

# --- Case 1: late writer, both removals fail --------------------------------
setup late
mkdir -p "$WT/.swarm/logs"; echo x > "$WT/.swarm/logs/a.log"
cat > "$TEST_DIR/shim/git" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = worktree ] && [ "\${2:-}" = remove ]; then
    mkdir -p "$WT/.swarm/tasks/status"
    echo '{}' > "$WT/.swarm/tasks/status/pr-issue-795.check.json"
    echo "error: failed to delete '$WT': Directory not empty" >&2
    exit 1
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TEST_DIR/shim/git"
run
[ "$RC" -eq 1 ] || red "late: expected exit 1, got $RC: $(cat "$TEST_DIR/run.log")"
[ -d "$WT" ] || red "late: worktree should be left in place"
[ -s "$TEST_DIR/killed" ] || red "late: window should be closed after late-writer retry failed"
ls "$PROJ"/.swarm/reaped/ | grep -q 'swarm-late$' || red "late: stub not archived"
green "late-writer double failure: exit 1, window closed, stub archived"

# --- Case 2: non-late failure (no .swarm/ after archive) ---------------------
setup other
cat > "$TEST_DIR/shim/git" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = worktree ] && [ "\${2:-}" = remove ]; then
    echo "error: cannot remove a locked working tree" >&2
    exit 1
fi
exec "$REAL_GIT" "\$@"
SHIM
run
[ "$RC" -eq 1 ] || red "other: expected exit 1, got $RC: $(cat "$TEST_DIR/run.log")"
[ -d "$WT" ] || red "other: worktree should be left in place"
[ ! -e "$TEST_DIR/killed" ] || red "other: window must stay open on a non-late-writer failure"
green "non-late failure: exit 1, window left open"
