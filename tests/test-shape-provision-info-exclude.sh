#!/usr/bin/env bash
#
# test-shape-provision-info-exclude.sh — Regression test for the #615
# info/exclude bug found during that issue's incident recovery:
# provision-worker.sh only appended the `.swarm/` exclude line when
# `info/exclude` already existed (`[ -f "$exclude_file" ]`). Any time that
# file is missing — most notably right after a shared-.git wipe like #615's,
# but also just a worktree admin dir that never had one — provisioning
# silently skipped it forever after, and `.swarm/` showed as untracked in
# the worktree from then on.
#
# Same extraction technique as test-shape-provision-stale-container.sh: the
# exact snippet is lifted from provision-worker.sh with sed (never hand-
# copied), so a future edit that reintroduces the bug (or renames `$WT`)
# fails here instead of drifting silently. The snippet is inline script,
# not a function, so it's wrapped in one here purely for the test's own
# convenience — the body under test is still provision-worker.sh's own.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
[ -r "$PROVISION" ] || red "provision-worker.sh not readable: $PROVISION"
command -v git >/dev/null 2>&1 || red "git not found — required by this test"

TEST_DIR=$(mktemp -d -t shape-provision-info-exclude-XXXXXX)
cleanup() {
    [ "${KEEP:-0}" = "1" ] && { echo "KEEP=1: leaving $TEST_DIR for inspection" >&2; return; }
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

body="$(sed -n '/^exclude_file="\$(git -C "\$WT"/,/^fi$/p' "$PROVISION")"
[ -n "$body" ] || red "could not extract the info/exclude snippet from $PROVISION — has it moved or been renamed?"
echo "$body" | grep -q 'mkdir -p' || red "extracted snippet looks stale (no mkdir -p) — extraction markers may need updating"

ensure_swarm_exclude() {
    local WT="$1"
    eval "$body"
}

# Real usage is always a LINKED worktree (provision-worker.sh creates $WT via
# `git worktree add`), never a bare repo opened directly — and that matters
# here: `git rev-parse --git-path` prints a path relative to the repo when
# there's no linked-worktree indirection, but an absolute path into the
# common dir once there is one. A plain `git init` fixture would exercise a
# path-resolution case this code never actually hits in production, so each
# test below builds a real main-repo + worktree pair instead.
new_worktree_fixture() {
    local name="$1"
    local main="$TEST_DIR/$name-main"
    local wt="$TEST_DIR/$name-wt"
    git init -q "$main"
    git -C "$main" config user.email test@example.com
    git -C "$main" config user.name Test
    echo hi > "$main/f.txt"
    git -C "$main" add f.txt
    git -C "$main" commit -qm init
    git -C "$main" branch wta
    git -C "$main" worktree add -q "$wt" wta
    printf '%s' "$wt"
}

# ============================================================================
heading "Test 1: info/exclude missing entirely -> created with .swarm/ (the #615 shape)"
# ============================================================================
WT="$(new_worktree_fixture t1)"
EXCLUDE="$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
rm -f "$EXCLUDE"
[ ! -e "$EXCLUDE" ] || red "setup: info/exclude should not exist yet"
ensure_swarm_exclude "$WT"
[ -f "$EXCLUDE" ] || red "expected info/exclude to be created when missing"
grep -qxF '.swarm/' "$EXCLUDE" || red "expected .swarm/ in the newly created info/exclude, got: $(cat "$EXCLUDE")"
green "a missing info/exclude is created and gets the .swarm/ entry"

# ============================================================================
heading "Test 2: info/exclude exists without the entry -> appended"
# ============================================================================
WT="$(new_worktree_fixture t2)"
EXCLUDE="$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
printf '# some pre-existing local exclude\nfoo.tmp\n' > "$EXCLUDE"
ensure_swarm_exclude "$WT"
grep -qxF 'foo.tmp' "$EXCLUDE" || red "expected the pre-existing line to survive"
grep -qxF '.swarm/' "$EXCLUDE" || red "expected .swarm/ appended, got: $(cat "$EXCLUDE")"
green "an existing info/exclude without the entry gets .swarm/ appended, pre-existing lines kept"

# ============================================================================
heading "Test 3: info/exclude already has the entry -> left untouched (idempotent)"
# ============================================================================
WT="$(new_worktree_fixture t3)"
EXCLUDE="$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
printf '.swarm/\n' > "$EXCLUDE"
before="$(md5sum "$EXCLUDE" | awk '{print $1}')"
ensure_swarm_exclude "$WT"
after="$(md5sum "$EXCLUDE" | awk '{print $1}')"
[ "$before" = "$after" ] || red "expected no change when .swarm/ is already present, before=$before after=$after"
green "an info/exclude that already has .swarm/ is left byte-for-byte unchanged"

# ============================================================================
heading "All provision-worker.sh info/exclude tests passed"
# ============================================================================
green "the #615-found bug (missing info/exclude silently skipped forever) is fixed: the file is created when absent, and the .swarm/ entry is added idempotently either way"
