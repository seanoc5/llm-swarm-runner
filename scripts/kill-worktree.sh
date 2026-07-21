#!/usr/bin/env bash
#
# kill-worktree.sh — remove a worker worktree, its branch, and tmux window.
#
# Usage:
#   kill-worktree.sh <issue-number> [project-dir] [--no-compose-down]
#
# Removes the worktree at <derived path>/wt-issue-<N>, deletes the branch
# fix/issue-<N>, and kills the tmux window iss-<N> if any. Idempotent —
# warns about pieces that don't exist but never errors. Use for ABANDON
# verdicts from coordinator triage.
#
# Path derivation honors SWARM_WORKTREE_GROUPING (flat|project, default
# flat). See scripts/_load-env.sh swarm_worktree_dir() for the rule.
#
# Before the worktree is removed, brings down any docker compose stack the
# worker started inside it (see _compose-down-for-worktree.sh) — otherwise
# the containers survive as port-squatters after the worktree is gone
# (issue #105). Pass --no-compose-down to skip this and preserve the
# containers (e.g. to inspect their logs after the fact).
#
# WARNING: --force is used. Any uncommitted work in the worktree is lost.
# The script prints how-much-work-will-be-lost before deletion.
#
# issue #181: before removing anything, checks for an in-flight check-on-done
# run (coordinator-watch.sh's maybe_run_check claims a worktree via a
# `mkdir`'d .swarm/tasks/status/<task_id>.check-claim dir while its
# acceptance check runs). If an unexpired claim is found, removal is
# DEFERRED (exit 75) rather than yanking the worktree out from under a
# running check — see maybe_run_check's own comments for the claim/release
# protocol. A claim older than CHECK_CLAIM_STALE_SECS (default:
# WORKER_CHECK_TIMEOUT + 300s slack) is treated as a crashed check and no
# longer blocks removal.
set -euo pipefail

# Portable mtime (epoch seconds). GNU coreutils first, BSD fallback. Mirrors
# reap-orphan-worktrees.sh's mtime_epoch — kept local since scripts here are
# self-contained (see scripts/README.md).
mtime_epoch() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

NO_COMPOSE_DOWN=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-compose-down) NO_COMPOSE_DOWN=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

ISSUE="${1:?usage: kill-worktree.sh <issue-number> [project-dir] [--no-compose-down]}"
PROJECT_DIR="${2:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Source the env loader to (a) pick up SWARM_WORKTREE_GROUPING from
# <project>/.swarm/.env or sandbox .env.example, and (b) get
# swarm_worktree_dir() to derive WT correctly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

WT="$(swarm_worktree_dir "$PROJECT_DIR" "$ISSUE")"
BRANCH="fix/issue-$ISSUE"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"

cd "$PROJECT_DIR"

# The worktree may have been repurposed onto a different branch mid-life
# (checkout -B from a parked worker — see issue #97), decoupling the
# dirname-derived fix/issue-N from what's actually checked out. Capture the
# real branch before removal so it doesn't linger as an orphaned local ref.
ACTUAL_BRANCH=""
if [ -d "$WT" ]; then
    ACTUAL_BRANCH="$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi

echo "=== kill-worktree #$ISSUE ==="
echo "  project:  $PROJECT_DIR"
echo "  worktree: $WT"
echo "  branch:   $BRANCH"
if [ -n "$ACTUAL_BRANCH" ] && [ "$ACTUAL_BRANCH" != "$BRANCH" ]; then
    echo "  actual:   $ACTUAL_BRANCH (worktree was repurposed; deleting this too)"
fi
echo "  tmux:     $SESSION_NAME / iss-$ISSUE"
echo

# Show what we're about to discard
if [ -d "$WT" ]; then
    DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
    if [ -z "$DEFAULT_BRANCH" ]; then
        for candidate in main master; do
            if git show-ref --verify --quiet "refs/heads/$candidate"; then
                DEFAULT_BRANCH="$candidate"
                break
            fi
        done
    fi
    DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"
    AHEAD="$(git -C "$WT" rev-list --count "$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo '?')"
    DIRTY="$(git -C "$WT" status --porcelain 2>/dev/null | wc -l)"
    echo "  Worktree state: $AHEAD commit(s) ahead of $DEFAULT_BRANCH, $DIRTY uncommitted change(s)"

    # issue #181: defer if a check-on-done run is actively using this
    # worktree. Reap racing a running check produced spurious failures
    # (getcwd/"No such file or directory") on code that was actually fine
    # — the ground vanished mid-run, not the code. See maybe_run_check in
    # coordinator-watch.sh for where the claim is taken and released.
    CHECK_CLAIM_STALE_SECS="${CHECK_CLAIM_STALE_SECS:-$(( ${WORKER_CHECK_TIMEOUT:-600} + 300 ))}"
    ACTIVE_CLAIM=""
    shopt -s nullglob
    for claim in "$WT"/.swarm/tasks/status/*.check-claim; do
        [ -d "$claim" ] || continue
        claim_age=$(( $(date +%s) - $(mtime_epoch "$claim") ))
        if [ "$claim_age" -lt "$CHECK_CLAIM_STALE_SECS" ]; then
            ACTIVE_CLAIM="$(basename "$claim") (${claim_age}s old)"
            break
        fi
        echo "  - stale check-claim $(basename "$claim") (${claim_age}s >= ${CHECK_CLAIM_STALE_SECS}s TTL) — treating as a crashed check, proceeding"
    done
    shopt -u nullglob
    if [ -n "$ACTIVE_CLAIM" ]; then
        echo "  ⏸ in-flight check ($ACTIVE_CLAIM) — deferring worktree removal, retry next reap pass"
        exit 75
    fi

    if [ "$NO_COMPOSE_DOWN" = "1" ]; then
        echo "  - skipping compose down (--no-compose-down)"
    else
        "$SCRIPT_DIR/_compose-down-for-worktree.sh" "$WT" || echo "  WARN: compose-down helper exited non-zero (continuing)"
    fi
    git worktree remove --force "$WT"
    echo "  ✓ removed worktree"
else
    echo "  - worktree dir not present (skipped)"
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git branch -D "$BRANCH"
    echo "  ✓ deleted branch $BRANCH"
else
    echo "  - branch $BRANCH not present (skipped)"
fi

if [ -n "$ACTUAL_BRANCH" ] && [ "$ACTUAL_BRANCH" != "$BRANCH" ]; then
    if git show-ref --verify --quiet "refs/heads/$ACTUAL_BRANCH"; then
        git branch -D "$ACTUAL_BRANCH"
        echo "  ✓ deleted branch $ACTUAL_BRANCH (repurposed)"
    else
        echo "  - branch $ACTUAL_BRANCH not present (skipped)"
    fi
fi

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
        tmux kill-window -t "$SESSION_NAME:iss-$ISSUE"
        echo "  ✓ killed tmux window"
    else
        echo "  - tmux window not present (skipped)"
    fi
else
    echo "  - tmux session not running (skipped window cleanup)"
fi

echo
echo "Done."
