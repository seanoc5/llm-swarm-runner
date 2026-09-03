#!/usr/bin/env bash
#
# test-kill-worktree-salvage.sh — Non-LLM regression test for the inbox/
# outbox salvage-before-reap behavior in kill-worktree.sh (issue #317).
#
# The #317 bug: kill-worktree.sh ran `git worktree remove --force` with no
# look at <worktree>/.swarm/tasks/inbox/ (requeue.sh's follow-up-brief
# queue) or tasks/outbox/ (unread worker messages) — a worktree reaped
# between tasks silently destroyed any queued-but-not-yet-picked-up brief.
#
# Strategy: real git worktree fixtures (no tmux/gh needed — this exercises
# kill-worktree.sh directly, and separately the dry-run preview in
# kill-finished-workers.sh via a private tmux socket + gh stub, mirroring
# test-kill-finished-workers.sh's fixture style).
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
KILL_FINISHED="$SCRIPT_DIR/../scripts/kill-finished-workers.sh"
[ -x "$KILL_WT" ] || red "kill-worktree.sh not executable: $KILL_WT"
[ -x "$KILL_FINISHED" ] || red "kill-finished-workers.sh not executable: $KILL_FINISHED"

REAL_TMUX="$(command -v tmux)" || red "tmux not installed"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t kill-wt-salvage-XXXXXX)
TEST_SOCK="kws-test-$$"
cleanup() {
    "$REAL_TMUX" -L "$TEST_SOCK" kill-server 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Each sub-test gets its own project + worktree fixture so the reap of one
# doesn't disturb another. Repeated below for issues 51 (salvage), 52
# (refuse), 53 (empty-queue no-op).
new_project() {
    local proj="$1"
    mkdir -p "$proj"
    git init -q "$proj"
    git -C "$proj" config user.email test@example.com
    git -C "$proj" config user.name "Test"
    echo hello > "$proj/README.md"
    git -C "$proj" add README.md
    git -C "$proj" commit -q -m init
}

export SWARM_WORKTREE_GROUPING=flat

# ============================================================================
heading "Test 1: non-empty inbox+outbox is salvaged, worktree still removed"
# ============================================================================

PROJ1="$TEST_DIR/proj1"
new_project "$PROJ1"
git -C "$PROJ1" worktree add -q -b fix/issue-51 "$TEST_DIR/wt-issue-51"
WT1="$TEST_DIR/wt-issue-51"

mkdir -p "$WT1/.swarm/tasks/inbox" "$WT1/.swarm/tasks/outbox/processed"
echo "follow-up brief" > "$WT1/.swarm/tasks/inbox/20260101-000000-51.md"
echo "worker message"  > "$WT1/.swarm/tasks/outbox/20260101-000001-fyi.md"
echo "already read"    > "$WT1/.swarm/tasks/outbox/processed/20260101-000002-fyi.md"

RUN1="$TEST_DIR/run1.log"
set +e
(cd "$PROJ1" && "$KILL_WT" 51 "$PROJ1") > "$RUN1" 2>&1
RC1=$?
set -e
[ "$RC1" -eq 0 ] || red "expected exit 0, got $RC1. Output:
$(cat "$RUN1")"
green "kill-worktree.sh exited 0 with a non-empty inbox/outbox"

grep -q 'SALVAGED: 2 unprocessed brief(s) from iss-51 (inbox=1 outbox=1)' "$RUN1" \
    || red "expected a SALVAGED summary line naming counts. Output:
$(cat "$RUN1")"
green "SALVAGED line printed with correct inbox/outbox counts"

SALVAGE_DIR="$PROJ1/.swarm/salvaged/iss-51"
[ -f "$SALVAGE_DIR/inbox/20260101-000000-51.md" ] \
    || red "queued inbox brief was not salvaged to $SALVAGE_DIR/inbox/"
[ -f "$SALVAGE_DIR/outbox/20260101-000001-fyi.md" ] \
    || red "unread outbox message was not salvaged to $SALVAGE_DIR/outbox/"
green "both files moved into the salvage dir"

[ -d "$WT1" ] && red "worktree dir still present after removal: $WT1"
git -C "$PROJ1" show-ref --verify --quiet refs/heads/fix/issue-51 \
    && red "branch fix/issue-51 still present after removal"
green "worktree and branch removed as normal despite the salvage"

# ============================================================================
heading "Test 2: --refuse-nonempty-inbox skips removal entirely (exit 76)"
# ============================================================================

PROJ2="$TEST_DIR/proj2"
new_project "$PROJ2"
git -C "$PROJ2" worktree add -q -b fix/issue-52 "$TEST_DIR/wt-issue-52"
WT2="$TEST_DIR/wt-issue-52"

mkdir -p "$WT2/.swarm/tasks/inbox"
echo "follow-up brief" > "$WT2/.swarm/tasks/inbox/20260101-000000-52.md"

RUN2="$TEST_DIR/run2.log"
set +e
(cd "$PROJ2" && "$KILL_WT" 52 "$PROJ2" --refuse-nonempty-inbox) > "$RUN2" 2>&1
RC2=$?
set -e
[ "$RC2" -eq 76 ] || red "expected exit 76 (refused), got $RC2. Output:
$(cat "$RUN2")"
green "kill-worktree.sh exited 76 under --refuse-nonempty-inbox"

grep -q 'REFUSED: 1 unprocessed brief(s) in iss-52' "$RUN2" \
    || red "expected a REFUSED line. Output:
$(cat "$RUN2")"
[ -d "$WT2" ] || red "worktree was removed despite --refuse-nonempty-inbox"
git -C "$PROJ2" show-ref --verify --quiet refs/heads/fix/issue-52 \
    || red "branch fix/issue-52 was deleted despite --refuse-nonempty-inbox"
[ -f "$WT2/.swarm/tasks/inbox/20260101-000000-52.md" ] \
    || red "queued brief vanished even though the worktree was refused, not salvaged"
[ ! -d "$PROJ2/.swarm/salvaged" ] \
    || red "refuse mode should not create a salvage dir"
green "worktree, branch, and queued brief all left untouched"

# SWARM_REAP_INBOX=refuse env var is equivalent to the flag.
RUN2B="$TEST_DIR/run2b.log"
set +e
(cd "$PROJ2" && SWARM_REAP_INBOX=refuse "$KILL_WT" 52 "$PROJ2") > "$RUN2B" 2>&1
RC2B=$?
set -e
[ "$RC2B" -eq 76 ] || red "expected exit 76 via SWARM_REAP_INBOX=refuse, got $RC2B"
green "SWARM_REAP_INBOX=refuse env var behaves like --refuse-nonempty-inbox"

# ============================================================================
heading "Test 3: empty inbox/outbox reaps exactly as before (no new output)"
# ============================================================================

PROJ3="$TEST_DIR/proj3"
new_project "$PROJ3"
git -C "$PROJ3" worktree add -q -b fix/issue-53 "$TEST_DIR/wt-issue-53"

RUN3="$TEST_DIR/run3.log"
set +e
(cd "$PROJ3" && "$KILL_WT" 53 "$PROJ3") > "$RUN3" 2>&1
RC3=$?
set -e
[ "$RC3" -eq 0 ] || red "expected exit 0, got $RC3. Output:
$(cat "$RUN3")"
grep -qi 'SALVAGED\|REFUSED' "$RUN3" \
    && red "empty-queue reap must not mention salvage/refuse. Output:
$(cat "$RUN3")"
[ ! -d "$PROJ3/.swarm/salvaged" ] \
    || red "empty-queue reap must not create a salvage dir"
green "empty-queue reap produced no salvage output and no salvage dir"

# ============================================================================
heading "Test 4: kill-finished-workers.sh --dry-run previews salvage counts"
# ============================================================================

PROJ4="$TEST_DIR/proj4"
new_project "$PROJ4"
git -C "$PROJ4" worktree add -q -b fix/issue-61 "$TEST_DIR/wt-issue-61"
mkdir -p "$TEST_DIR/wt-issue-61/.swarm/tasks/inbox"
echo "queued" > "$TEST_DIR/wt-issue-61/.swarm/tasks/inbox/20260101-000000-61.md"

SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCK" "\$@"
EOF
chmod +x "$SHIM_DIR/tmux"
# No open PR for fix/issue-61 → PR-safe under the default parked+PR-safe mode.
cat > "$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SHIM_DIR/gh"

SESSION4="llm-proj4"
"$SHIM_DIR/tmux" new-session -d -s "$SESSION4" -n iss-61
"$SHIM_DIR/tmux" send-keys -t "$SESSION4:iss-61" 'echo [polling for next brief]' Enter

RUN4="$TEST_DIR/run4.log"
set +e
(cd "$PROJ4" && PATH="$SHIM_DIR:$PATH" \
    "$KILL_FINISHED" --with-worktree --dry-run) > "$RUN4" 2>&1
RC4=$?
set -e
[ "$RC4" -eq 0 ] || red "expected exit 0, got $RC4. Output:
$(cat "$RUN4")"
grep -q 'iss-61: would salvage 1 unprocessed brief(s) (inbox=1 outbox=0)' "$RUN4" \
    || red "expected a per-window salvage preview line. Output:
$(cat "$RUN4")"
green "dry-run reported the would-be-salvaged count for iss-61"
[ -f "$TEST_DIR/wt-issue-61/.swarm/tasks/inbox/20260101-000000-61.md" ] \
    || red "dry-run must not actually move anything"
[ -d "$TEST_DIR/wt-issue-61" ] || red "dry-run must not remove the worktree"
green "dry-run took no action (brief and worktree untouched)"
"$SHIM_DIR/tmux" kill-session -t "$SESSION4" 2>/dev/null || true

echo
green "ALL TESTS PASSED"
