#!/usr/bin/env bash
#
# kill-worktree.sh — remove a worker worktree, its branch, and tmux window.
#
# Usage:
#   kill-worktree.sh <issue-number> [project-dir] [--no-compose-down] [--refuse-nonempty-inbox]
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
# issue #317: requeue.sh delivers follow-up briefs into <worktree>/.swarm/
# tasks/inbox/ between tasks; worker-listener.sh atomically claims one by
# mv'ing it into tasks/processing/ while it runs; workers drop mid-task
# messages into tasks/outbox/. But the watcher's auto-reap
# (kill-finished-workers.sh --pr-finalized --with-worktree --yes) fires as
# soon as the PR is finalized and deliberately bypasses the "listener
# parked" check in that mode — so it routinely reaps a worker mid-task,
# with its claimed brief still sitting in processing/, not just an idle
# worker with a stale inbox/. Before removal, any queued file still in
# inbox/, processing/, or outbox/ (excluding outbox/processed/, already
# coordinator-read) is MOVED to
# <project>/.swarm/salvaged/iss-<N>/{inbox,processing,outbox}/ and a
# `SALVAGED: ...` line is printed, so an unattended reap preserves the
# brief instead of silently destroying it. Set --refuse-nonempty-inbox (or
# SWARM_REAP_INBOX=refuse) to skip the worktree entirely instead (exit 76)
# for operators who'd rather the reap stall than salvage-and-remove.
#
# issue #375: salvage alone left the PR itself silent — a human merging
# from GitHub had no way to know a queued fix brief never reached the
# worker. A salvage now also best-effort posts a `SWARM_BRIEF_ORPHANED`
# marker comment on the reaped branch's PR (see notify_pr_brief_orphaned
# below); pairs with requeue.sh's `SWARM_PENDING_BRIEF` marker, which
# flags the PR the moment a follow-up brief is queued, before any reap.
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
REFUSE_NONEMPTY_INBOX=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-compose-down) NO_COMPOSE_DOWN=1 ;;
        --refuse-nonempty-inbox) REFUSE_NONEMPTY_INBOX=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
[ "${SWARM_REAP_INBOX:-}" = "refuse" ] && REFUSE_NONEMPTY_INBOX=1

# Counts queued files directly in dir (0 if dir absent/empty): any regular
# file except a `.tmp.*` in-progress write. Mirrors worker-listener.sh's
# claim_next_task() selection (`find ... -not -name '.tmp.*'`) exactly —
# that function doesn't restrict by extension, so neither does this; an
# earlier *.md-only version undercounted a hand-dropped extension-less
# brief that claim_next_task would still happily dispatch. Local per the
# self-contained-scripts convention (see mtime_epoch above) — mirrored in
# kill-finished-workers.sh's count_queued_files for its --dry-run preview.
count_queued_files() {
    local dir="$1"
    [ -d "$dir" ] || { echo 0; return; }
    find "$dir" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | wc -l | tr -d ' '
}

# Head of one salvaged brief, so "is this still relevant?" is answerable
# from the PR page instead of requiring a shell on the swarm host. Prefers
# inbox/ (never delivered at all) over processing/ (claimed but unfinished)
# — the former is the more complete loss. Self-contained per the
# scripts convention; mirrors requeue.sh's brief_excerpt, including the
# six-backtick fence and the defanging of any six-or-more run in the
# content so a brief carrying its own code fences cannot break out.
salvaged_excerpt() {
    local salvage_dir="$1"
    local max_lines="${SWARM_PR_BRIEF_LINES:-20}"
    [ "${SWARM_PR_BRIEF_EXCERPT:-1}" = "1" ] || return 0
    local file=""
    local d
    for d in inbox processing outbox; do
        file="$(find "$salvage_dir/$d" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | sort | head -1)"
        [ -n "$file" ] && break
    done
    [ -n "$file" ] && [ -r "$file" ] || return 0
    local total
    total="$(wc -l < "$file" 2>/dev/null || echo 0)"
    head -n "$max_lines" "$file" 2>/dev/null \
        | cut -c1-200 \
        | sed -e 's/`\{6,\}/[fence]/g'
    if [ "$total" -gt "$max_lines" ]; then
        printf '\n… truncated (%s more lines)\n' "$((total - max_lines))"
    fi
}

# issue #375: salvage_queued_files (below) preserves the brief's bytes,
# but preservation alone left a merge-race blind spot — twice in one
# civicstrata session a PR merged from GitHub while a coordinator-requeued
# fix brief (a review BLOCK once, a privacy caveat once) sat orphaned in
# this exact salvage path, because nothing at the PR itself said a fix was
# still queued. Best-effort: posts a `<!-- SWARM_BRIEF_ORPHANED -->`
# comment on the reaped branch's PR (any state — this fires right as the
# worktree that would have delivered the brief is being destroyed, so the
# PR is typically already MERGED/CLOSED) naming the salvage location. No
# gh, no remote, no PR for the branch, or a lookup failure is silently
# swallowed — this is a signal, never a gate on the reap itself.
#
# issue #397: "a human should judge whether this is still relevant" was
# the whole of the old guidance, which left the reader with a directory
# path on a host they may not be sitting at. The comment now carries the
# brief's own head plus the exact commands for each of the three possible
# dispositions.
notify_pr_brief_orphaned() {
    local branch="$1" unprocessed="$2" counts="$3" salvage_dir="$4" issue="${5:-}"
    command -v gh >/dev/null 2>&1 || return 0
    local pr
    pr="$(gh pr view "$branch" --json number -q .number 2>/dev/null)" || return 0
    [ -n "$pr" ] || return 0

    # Assembled line by line rather than as one printf: every static line
    # is single-quoted, so the many `backtick` code spans stay literal
    # without an escaping thicket.
    local -a body=()
    body+=('<!-- SWARM_BRIEF_ORPHANED -->')
    body+=(':rotating_light: **Swarm: a queued follow-up brief was orphaned by a worker reap**')
    body+=('')
    body+=("$(printf 'This PR'"'"'s worker worktree was reaped (`kill-worktree.sh`, issues #317/#375) while %s unprocessed brief file(s) (%s) still sat in its task queue — they never reached the worker. If this PR is already merged or closed, whatever the queued brief was meant to fix (a review BLOCK, a privacy caveat, superseded numbers, ...) never made it in.' \
        "$unprocessed" "$counts")")
    body+=('')
    body+=("$(printf 'The brief(s) were preserved, not lost: `%s`.' "$salvage_dir")")

    local excerpt
    excerpt="$(salvaged_excerpt "$salvage_dir")"
    if [ -n "$excerpt" ]; then
        body+=('')
        body+=('<details><summary><b>What was orphaned</b> (head of the first salvaged brief — judge relevance without leaving this page)</summary>')
        body+=('')
        body+=('``````text')
        body+=("$excerpt")
        body+=('``````')
        body+=('</details>')
    fi

    body+=('')
    body+=('**Next steps — pick one:**')
    body+=('')
    body+=("$(printf '1. **Read the rest of it** on the swarm host:\n   ```bash\n   head -n 60 %s/*/*\n   ```' "$salvage_dir")")
    body+=("$(printf '2. **Still relevant → re-file it.** The worktree is gone, so the brief cannot simply be requeued; the swarm dispatches from issues. Open one quoting the excerpt above and referencing this PR:\n   ```bash\n   gh issue create --title '"'"'follow-up: <what the brief asked for>'"'"' \\\n       --body '"'"'Orphaned brief from PR #%s (salvage: %s). <paste brief>'"'"'\n   ```\n   The coordinator picks it up on its next dispatch pass.' \
        "$pr" "$salvage_dir")")
    if [ -n "$issue" ]; then
        body+=("$(printf '   If issue #%s is still open and the work belongs there, re-provisioning against it also works: `provision-worker.sh %s`.' \
            "$issue" "$issue")")
    fi
    body+=("$(printf '3. **Obsolete → drop it**, so the next reader does not re-litigate the same brief:\n   ```bash\n   rm -rf %s\n   ```' "$salvage_dir")")
    body+=('')
    body+=('<sub>scripts/kill-worktree.sh — issue #375 (reap-race escalation), #397 (next steps).</sub>')

    local comment
    comment="$(printf '%s\n' "${body[@]}")"
    gh pr comment "$pr" --body "$comment" >/dev/null 2>&1 || true
}

# Moves every queued file (same selection as count_queued_files) from src/
# into dest/, disambiguating a same-named collision (a prior salvage of the
# same issue) with a UTC timestamp prefix rather than clobbering it.
salvage_queued_files() {
    local src="$1" dest="$2" f base target
    [ -d "$src" ] || return 0
    while IFS= read -r f; do
        base="$(basename "$f")"
        target="$dest/$base"
        [ -e "$target" ] && target="$dest/$(date -u +%Y%m%dT%H%M%SZ)-$base"
        mv "$f" "$target"
    done < <(find "$src" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null)
}

ISSUE="${1:?usage: kill-worktree.sh <issue-number> [project-dir] [--no-compose-down] [--refuse-nonempty-inbox]}"
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

    # issue #317: refuse or salvage unprocessed queued briefs before this
    # worktree is destroyed. inbox/ is requeue.sh's follow-up-brief queue;
    # processing/ holds a brief the listener has already atomically claimed
    # (mv'd out of inbox/) but not yet finished — a --pr-finalized /
    # --merged-only reap bypasses the "parked" check specifically so it can
    # reap a worker mid-task, which makes processing/ the MOST likely place
    # to find in-flight work, not an edge case; outbox/ (minus
    # outbox/processed/, already coordinator-read) is the worker's mid-task
    # message channel. See header comment for rationale.
    INBOX_COUNT="$(count_queued_files "$WT/.swarm/tasks/inbox")"
    PROCESSING_COUNT="$(count_queued_files "$WT/.swarm/tasks/processing")"
    OUTBOX_COUNT="$(count_queued_files "$WT/.swarm/tasks/outbox")"
    UNPROCESSED=$((INBOX_COUNT + PROCESSING_COUNT + OUTBOX_COUNT))
    if [ "$UNPROCESSED" -gt 0 ]; then
        COUNTS_MSG="inbox=$INBOX_COUNT processing=$PROCESSING_COUNT outbox=$OUTBOX_COUNT"
        if [ "$REFUSE_NONEMPTY_INBOX" = "1" ]; then
            echo "  ✗ REFUSED: $UNPROCESSED unprocessed brief(s) in iss-$ISSUE ($COUNTS_MSG)"
            echo "    --refuse-nonempty-inbox / SWARM_REAP_INBOX=refuse is set — worktree, branch, and tmux window left untouched"
            exit 76
        fi
        SALVAGE_DIR="$PROJECT_DIR/.swarm/salvaged/iss-$ISSUE"
        mkdir -p "$SALVAGE_DIR/inbox" "$SALVAGE_DIR/processing" "$SALVAGE_DIR/outbox"
        salvage_queued_files "$WT/.swarm/tasks/inbox" "$SALVAGE_DIR/inbox"
        salvage_queued_files "$WT/.swarm/tasks/processing" "$SALVAGE_DIR/processing"
        salvage_queued_files "$WT/.swarm/tasks/outbox" "$SALVAGE_DIR/outbox"
        echo "  ⚠ SALVAGED: $UNPROCESSED unprocessed brief(s) from iss-$ISSUE ($COUNTS_MSG) → $SALVAGE_DIR"
        notify_pr_brief_orphaned "${ACTUAL_BRANCH:-$BRANCH}" "$UNPROCESSED" "$COUNTS_MSG" "$SALVAGE_DIR" "$ISSUE"
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
