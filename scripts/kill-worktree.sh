#!/usr/bin/env bash
#
# kill-worktree.sh — remove a worker worktree, its branch, and tmux window.
#
# Usage:
#   kill-worktree.sh <issue-number> [project-dir] [--no-compose-down] [--refuse-nonempty-inbox] [--grace] [--now]
#
# Removes the worktree at <derived path>/wt-issue-<N>, deletes the branch
# fix/issue-<N>, and kills the tmux window iss-<N> if any. Idempotent —
# warns about pieces that don't exist but never errors. Use for ABANDON
# verdicts from coordinator triage.
#
# Path derivation prefers wherever git's own worktree registry says branch
# fix/issue-N actually lives (issue #407), falling back to the
# SWARM_WORKTREE_GROUPING-derived path (flat|project, default flat; see
# scripts/_load-env.sh swarm_worktree_dir()) only when git has no
# registration for it.
#
# Before the worktree is removed, brings down any docker compose stack the
# worker started inside it (see _compose-down-for-worktree.sh) — otherwise
# the containers survive as port-squatters after the worktree is gone
# (issue #105). Pass --no-compose-down to skip this and preserve the
# containers (e.g. to inspect their logs after the fact).
#
# WARNING: --force is used. The script prints the worktree's state before
# deletion, and (issue: reap saves unpushed work, below) saves anything
# not already on a remote first.
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
#
# issue #495: the #317 salvage only ever covered the task-queue subdirs
# (inbox/processing/outbox), so everything else a worker wrote under
# `.swarm/` (logs, status, a misplaced evidence file) or `.local-data/`
# (working output files) was still destroyed unrecoverably by the
# `git worktree remove --force` below. Before that removal, both are
# archived to `<project>/.swarm/reaped/iss-<N>-<UTC>.{swarm,local-data}/`
# — `.local-data/` only under SWARM_REAP_LOCALDATA_MAX_MB (default 512MB),
# since worker-generated datasets can be large; over the cap it is left in
# place (still destroyed by the removal, same as before this issue) but
# its size/path are logged and printed. See archive_worktree_scratch below.
#
# Saved work + reap grace: since 2026-10-18 roughly 1 reap in 5 landed
# mid-task, and none of the salvage above covered the CODE — unpushed
# commits and uncommitted edits went with `git worktree remove --force`.
#   G1 (always on): before removal, commits not on any remote-tracking ref
#   (nor the local default branch) are written as a git bundle, tracked
#   edits as `git diff HEAD --binary`, and untracked files as a tarball
#   (under SWARM_REAP_SAVE_UNTRACKED_MAX_MB, default 100), all as
#   `<project>/.swarm/reaped/iss-<N>-<UTC>.{bundle,patch,untracked.tgz}`
#   plus a `.saved.txt` manifest with restore commands. Logged as
#   reap.worktree.saved_work and announced on the PR with a
#   `<!-- SWARM_WORK_SAVED -->` comment. A squash-merged branch whose
#   remote ref was deleted (swarm-merge.sh does that) is NOT counted as
#   unpushed: if merging HEAD into the default branch changes nothing, the
#   work already landed. Nothing unsaved → nothing written, same as before.
#   G2 (--grace, passed by kill-finished-workers.sh's PR-state modes — the
#   watcher's unattended autoclose): with unsaved work, the worker window
#   is closed and the brief queue salvaged as usual, but the worktree and
#   branch stay for SWARM_REAP_GRACE_SECS (default 14400 = 4h; 0 disables)
#   behind a marker at `<project>/.swarm/reap-deferred/iss-<N>`. Exit 75,
#   the same "deferred, retry next reap pass" code as an in-flight check.
#   Any later call (watcher's windowless pass, reap-orphan-worktrees.sh,
#   a human) defers again until the grace is over, then saves and removes.
#   --now ignores the marker. Clean worktrees are removed immediately.
set -euo pipefail

# Portable mtime (epoch seconds). GNU coreutils first, BSD fallback. Mirrors
# reap-orphan-worktrees.sh's mtime_epoch — kept local since scripts here are
# self-contained (see scripts/README.md).
mtime_epoch() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

NO_COMPOSE_DOWN=0
REFUSE_NONEMPTY_INBOX=0
GRACE_REQUESTED=0
REMOVE_NOW=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-compose-down) NO_COMPOSE_DOWN=1 ;;
        --refuse-nonempty-inbox) REFUSE_NONEMPTY_INBOX=1 ;;
        --grace) GRACE_REQUESTED=1 ;;
        --now) REMOVE_NOW=1 ;;
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
#
# issue #449: provision-worker.sh prepends prompts/refs.md's Reference
# Docs Index to every brief, so a literal head excerpt showed only that
# preamble and nothing task-specific — misread three times on separate
# civicstrata/fand-app PRs as salvage corruption before the coordinator's
# investigation (issue #449 comments) traced it to this excerpt starting
# at line 1 instead of the brief's own content. Excerpt from the brief's
# `## Task` heading when present; fall back to the head for briefs that
# don't have one (hand-authored requeues, legacy format).
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
    local total start remaining
    total="$(wc -l < "$file" 2>/dev/null || echo 0)"
    start="$(grep -n '^## Task$' "$file" 2>/dev/null | head -1 | cut -d: -f1)"
    start="${start:-1}"
    tail -n "+$start" "$file" 2>/dev/null \
        | head -n "$max_lines" \
        | cut -c1-200 \
        | sed -e 's/`\{6,\}/[fence]/g'
    remaining=$((total - start + 1 - max_lines))
    if [ "$remaining" -gt 0 ]; then
        printf '\n… truncated (%s more lines)\n' "$remaining"
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

# issue #407: resolves the worktree path for BRANCH from git's own
# worktree registry rather than trusting the SWARM_WORKTREE_GROUPING-derived
# path alone. A worktree created under `flat` grouping
# (<parent>/wt-issue-N) is left exactly where it is if the project later
# switches to `project` grouping — the branch's worktree is still fully
# registered and un-deletable while it exists, but swarm_worktree_dir()
# only ever computes the CURRENT mode's path, so the derived path silently
# misses it ("worktree dir not present (skipped)"), and the branch delete
# that follows fails with "cannot delete branch used by worktree".
#
# `git worktree list --porcelain` run against $project_dir is inherently
# scoped to that repo's own registry, so the #357 own-repo guarantee holds
# for free here — a worktree belonging to a different project's repo can
# never appear in this project's `git worktree list` output. Falls back to
# the derived path when git has no registration for the branch (worktree
# never created, or already removed) — same behavior as before this issue.
resolve_worktree_path() {
    local project_dir="$1" branch="$2" derived="$3"
    local path="" line
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) path="${line#worktree }" ;;
            "branch refs/heads/$branch")
                echo "$path"
                return 0
                ;;
        esac
    done < <(git -C "$project_dir" worktree list --porcelain 2>/dev/null)
    echo "$derived"
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

# issue #495: the #317 salvage above only ever covers the three task-queue
# subdirs. Everything else a worker wrote under the worktree's `.swarm/`
# (logs/, status/, an evidence file dropped there instead of
# `<project>/.swarm/evidence/`) or under its `.local-data/` (working
# output files) was still destroyed silently by `git worktree remove
# --force` below. Two fand-etl incidents on 2026-09-28 lost exactly this:
# corrected output data under `.local-data/` (iss-1103, reaped by the
# watcher's sanctioned autoclose) and incident-evidence logs under
# `.swarm/logs/` (iss-1010, reaped by #489's gh-side removal — same class
# of loss, different remover, which is why this lives in kill-worktree.sh
# itself rather than any one caller).
#
# Archives whatever is left of `<wt>/.swarm/` (always — small: tasks,
# logs, status) and `<wt>/.local-data/` (only under
# SWARM_REAP_LOCALDATA_MAX_MB, default 512 — worker-generated datasets can
# be large) to `<project>/.swarm/reaped/iss-<N>-<UTC-timestamp>.{swarm,
# local-data}/`, mv'd rather than copied so nothing is left for the
# `git worktree remove --force` that follows to race against. Over the
# cap, `.local-data/` is left in place — and is still destroyed by that
# same removal, exactly as before this issue — but its size and path are
# logged (reap.worktree.skipped_localdata) and printed, so the loss is at
# least diagnosable afterward from events.log or the reaper's preserved
# pane capture, and a human watching the pane live has a chance to copy it
# out first.
#
# Sets ARCHIVE_SWARM / ARCHIVE_LOCALDATA / LOCALDATA_SKIPPED as call-site
# globals (bash has no clean multi-value return) for the caller to
# log/print — same "local since scripts here are self-contained" pattern
# as mtime_epoch above; reap-orphan-worktrees.sh's reap_dangling and
# swarm-merge.sh's fallback removal each carry their own copy of this
# function rather than sourcing it, since neither can rely on this file
# being on disk in every caller's context (dangling registration; a bare
# checkout without this script's sibling files).
archive_worktree_scratch() {
    local project_dir="$1" issue="$2" wt="$3"
    ARCHIVE_SWARM=""
    ARCHIVE_LOCALDATA=""
    LOCALDATA_SKIPPED=""
    ARCHIVE_MV_FAILED=""
    ARCHIVE_EVENT_FIELD="none"
    [ -d "$wt/.swarm" ] || [ -d "$wt/.local-data" ] || return 0

    local ts base max_mb size_mb
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    base="$project_dir/.swarm/reaped/iss-$issue-$ts"
    mkdir -p "$project_dir/.swarm/reaped" 2>/dev/null || true

    if [ -d "$wt/.swarm" ]; then
        if mv "$wt/.swarm" "$base.swarm" 2>/dev/null; then
            ARCHIVE_SWARM="$base.swarm"
        else
            ARCHIVE_MV_FAILED="swarm"
        fi
    fi

    if [ -d "$wt/.local-data" ]; then
        max_mb="${SWARM_REAP_LOCALDATA_MAX_MB:-512}"
        size_mb="$(du -sm "$wt/.local-data" 2>/dev/null | cut -f1)"
        size_mb="${size_mb:-0}"
        if [ "$size_mb" -le "$max_mb" ] 2>/dev/null; then
            if mv "$wt/.local-data" "$base.local-data" 2>/dev/null; then
                ARCHIVE_LOCALDATA="$base.local-data"
            else
                ARCHIVE_MV_FAILED="${ARCHIVE_MV_FAILED:+$ARCHIVE_MV_FAILED,}local-data"
            fi
        else
            LOCALDATA_SKIPPED="size=${size_mb}MB path=$wt/.local-data"
        fi
    fi

    # self-review (PR #500): the events.log archive= field used to report
    # ARCHIVE_SWARM alone, so a reap that archived ONLY .local-data/ (no
    # .swarm/ dir at all — the iss-1103 shape) logged archive=none, exactly
    # as if nothing had been preserved. Report both, comma-joined.
    if [ -n "$ARCHIVE_SWARM" ] || [ -n "$ARCHIVE_LOCALDATA" ]; then
        ARCHIVE_EVENT_FIELD="${ARCHIVE_SWARM:+swarm=$ARCHIVE_SWARM}"
        if [ -n "$ARCHIVE_LOCALDATA" ]; then
            ARCHIVE_EVENT_FIELD="${ARCHIVE_EVENT_FIELD:+$ARCHIVE_EVENT_FIELD,}local_data=$ARCHIVE_LOCALDATA"
        fi
    fi
}

# --- Saved work (G1) + reap grace (G2) — see the header comment ------------

# Worker scratch is archived separately (archive_worktree_scratch), so it is
# kept out of the "is there unsaved code?" question and out of the patch.
SAVE_PATHSPEC=(-- . ':(exclude).swarm' ':(exclude).local-data')

# True when merging HEAD into the default branch would change nothing — the
# branch was squash-merged (or its content otherwise landed) even though its
# own commits are on no remote ref any more. swarm-merge.sh deletes the
# remote branch with `git push origin --delete`, which drops the local
# remote-tracking ref too, so without this every merged worker would look
# like it had unpushed commits. Fetches the default branch first (best
# effort, SWARM_REAP_FETCH=0 skips) so a merge seconds ago is visible.
head_already_landed() {
    local wt="$1" default="$2" target merged
    if [ "${SWARM_REAP_FETCH:-1}" = "1" ] && git -C "$wt" remote get-url origin >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 60 git -C "$wt" fetch -q origin "$default" >/dev/null 2>&1 || true
        else
            git -C "$wt" fetch -q origin "$default" >/dev/null 2>&1 || true
        fi
    fi
    if git -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$default" >/dev/null; then
        target="refs/remotes/origin/$default"
    elif git -C "$wt" rev-parse --verify --quiet "refs/heads/$default" >/dev/null; then
        target="refs/heads/$default"
    else
        return 1
    fi
    merged="$(git -C "$wt" merge-tree --write-tree "$target" HEAD 2>/dev/null | head -1)" || return 1
    [ -n "$merged" ] && [ "$merged" = "$(git -C "$wt" rev-parse "$target^{tree}" 2>/dev/null)" ]
}

# Sets UNSAVED_COMMITS (commits on no remote ref nor the local default
# branch, minus already-landed work), UNREACHABLE_COMMITS (the same count
# before the landed check — what a bundle must carry to keep HEAD
# restorable), LANDED_COMMITS, TRACKED_CHANGES, UNTRACKED_FILES and
# HAS_UNSAVED. Commits already pushed to the PR branch are safe on origin
# and are deliberately not counted.
compute_unsaved_state() {
    local wt="$1" default="$2"
    NOT_REFS=(--remotes)
    if git -C "$wt" show-ref --verify --quiet "refs/heads/$default"; then
        NOT_REFS+=("refs/heads/$default")
    fi
    UNREACHABLE_COMMITS="$(git -C "$wt" rev-list --count HEAD --not "${NOT_REFS[@]}" 2>/dev/null || echo 0)"
    UNSAVED_COMMITS="$UNREACHABLE_COMMITS"
    LANDED_COMMITS=0
    if [ "$UNSAVED_COMMITS" -gt 0 ] && head_already_landed "$wt" "$default"; then
        LANDED_COMMITS="$UNSAVED_COMMITS"
        UNSAVED_COMMITS=0
    fi
    TRACKED_CHANGES="$(git -C "$wt" diff HEAD --name-only "${SAVE_PATHSPEC[@]}" 2>/dev/null | wc -l | tr -d ' ')"
    UNTRACKED_FILES="$(git -C "$wt" ls-files --others --exclude-standard "${SAVE_PATHSPEC[@]}" 2>/dev/null | wc -l | tr -d ' ')"
    HAS_UNSAVED=0
    if [ "$UNSAVED_COMMITS" -gt 0 ] || [ "$TRACKED_CHANGES" -gt 0 ] || [ "$UNTRACKED_FILES" -gt 0 ]; then
        HAS_UNSAVED=1
    fi
}

# Identity of the unsaved state, so a deferred worktree nobody touched
# during its grace is not saved (and announced on the PR) a second time.
work_fingerprint() {
    local wt="$1"
    {
        git -C "$wt" rev-parse HEAD 2>/dev/null
        git -C "$wt" diff HEAD --binary "${SAVE_PATHSPEC[@]}" 2>/dev/null
        git -C "$wt" ls-files --others --exclude-standard "${SAVE_PATHSPEC[@]}" 2>/dev/null \
            | while IFS= read -r f; do
                printf '%s %s\n' "$f" "$(cd "$wt" && { stat -c '%s.%Y' "$f" 2>/dev/null || stat -f '%z.%m' "$f" 2>/dev/null; })"
            done
    } | git hash-object --stdin
}

# Writes the G1 save set and sets SAVED_FILES (space-separated), SAVED_BUNDLE/PATCH/TGZ
# and SAVED_MANIFEST. Each piece is best effort: a failure is printed and
# logged, never fatal — the caller decides whether to remove anyway.
save_unsaved_work() {
    local wt="$1" issue="$2" branch="$3" project_dir="$4"
    local ts base ref head max_mb size_b
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    base="$project_dir/.swarm/reaped/iss-$issue-$ts"
    mkdir -p "$project_dir/.swarm/reaped" 2>/dev/null || true
    SAVED_FILES=""
    SAVED_BUNDLE=""
    SAVED_PATCH=""
    SAVED_TGZ=""
    SAVE_FAILED=""
    head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo unknown)"
    ref="$(git -C "$wt" symbolic-ref --quiet HEAD 2>/dev/null || echo HEAD)"

    if [ "$UNREACHABLE_COMMITS" -gt 0 ]; then
        if git -C "$wt" bundle create "$base.bundle" "$ref" --not "${NOT_REFS[@]}" >/dev/null 2>&1; then
            SAVED_BUNDLE="$base.bundle"
        else
            SAVE_FAILED="bundle"
        fi
    fi
    if [ "$TRACKED_CHANGES" -gt 0 ]; then
        if git -C "$wt" diff HEAD --binary "${SAVE_PATHSPEC[@]}" > "$base.patch" 2>/dev/null; then
            SAVED_PATCH="$base.patch"
        else
            rm -f "$base.patch"
            SAVE_FAILED="${SAVE_FAILED:+$SAVE_FAILED,}patch"
        fi
    fi
    UNTRACKED_SKIPPED=""
    if [ "$UNTRACKED_FILES" -gt 0 ]; then
        max_mb="${SWARM_REAP_SAVE_UNTRACKED_MAX_MB:-100}"
        size_b="$(git -C "$wt" ls-files -z --others --exclude-standard "${SAVE_PATHSPEC[@]}" 2>/dev/null \
            | (cd "$wt" && du -cb --files0-from=- 2>/dev/null) | tail -1 | cut -f1)"
        size_b="${size_b:-0}"
        if [ "$size_b" -le $((max_mb * 1024 * 1024)) ] 2>/dev/null; then
            if git -C "$wt" ls-files -z --others --exclude-standard "${SAVE_PATHSPEC[@]}" 2>/dev/null \
                | tar -C "$wt" --null -T - -czf "$base.untracked.tgz" 2>/dev/null; then
                SAVED_TGZ="$base.untracked.tgz"
            else
                rm -f "$base.untracked.tgz"
                SAVE_FAILED="${SAVE_FAILED:+$SAVE_FAILED,}untracked"
            fi
        else
            UNTRACKED_SKIPPED="$UNTRACKED_FILES file(s), $((size_b / 1024 / 1024))MB > ${max_mb}MB cap"
        fi
    fi

    SAVED_MANIFEST="$base.saved.txt"
    {
        echo "# Work saved by kill-worktree.sh before removing $wt"
        echo "issue=$issue"
        echo "branch=$branch"
        echo "head=$head"
        echo "unpushed_commits=$UNSAVED_COMMITS"
        echo "tracked_changes=$TRACKED_CHANGES"
        echo "untracked_files=$UNTRACKED_FILES"
        [ -n "$UNTRACKED_SKIPPED" ] && echo "untracked_skipped=$UNTRACKED_SKIPPED"
        [ -n "$SAVE_FAILED" ] && echo "save_failed=$SAVE_FAILED"
        echo
        echo "# Restore (run on the swarm host):"
        restore_commands "$issue" "$head" "$ref"
    } > "$SAVED_MANIFEST" 2>/dev/null || SAVED_MANIFEST=""

    local f
    for f in "$SAVED_BUNDLE" "$SAVED_PATCH" "$SAVED_TGZ" "$SAVED_MANIFEST"; do
        [ -n "$f" ] && SAVED_FILES="${SAVED_FILES:+$SAVED_FILES }$f"
    done
    return 0
}

# Prints the restore commands for the files save_unsaved_work just wrote.
restore_commands() {
    local issue="$1" head="$2" ref="$3" dir
    dir="\$(dirname $PROJECT_DIR)/rescue-issue-$issue"
    if [ -n "$SAVED_BUNDLE" ]; then
        printf 'git -C %s fetch %s %s:refs/heads/rescue/issue-%s\n' "$PROJECT_DIR" "$SAVED_BUNDLE" "$ref" "$issue"
        printf 'git -C %s worktree add %s rescue/issue-%s\n' "$PROJECT_DIR" "$dir" "$issue"
    else
        printf 'git -C %s worktree add -b rescue/issue-%s %s %s\n' "$PROJECT_DIR" "$issue" "$dir" "$head"
    fi
    [ -n "$SAVED_PATCH" ] && printf 'git -C %s apply %s\n' "$dir" "$SAVED_PATCH"
    [ -n "$SAVED_TGZ" ] && printf 'tar -xzf %s -C %s\n' "$SAVED_TGZ" "$dir"
    return 0
}

# Best effort, same contract as notify_pr_brief_orphaned: no gh, no PR, or
# any failure is swallowed. $2 is "deferred until <UTC> ..." or "removed".
notify_pr_work_saved() {
    local branch="$1" disposition="$2"
    command -v gh >/dev/null 2>&1 || return 0
    local pr
    pr="$(gh pr view "$branch" --json number -q .number 2>/dev/null)" || return 0
    [ -n "$pr" ] || return 0
    local -a body=()
    body+=('<!-- SWARM_WORK_SAVED -->')
    body+=(':floppy_disk: **Swarm: the worker had unsaved work when this PR finished — it was saved, not lost**')
    body+=('')
    body+=("$(printf 'When the worker was reaped (`kill-worktree.sh`), its worktree held %s commit(s) not on any remote, %s changed tracked file(s) and %s untracked file(s). The worktree is %s.' \
        "$UNSAVED_COMMITS" "$TRACKED_CHANGES" "$UNTRACKED_FILES" "$disposition")")
    body+=('')
    body+=('**Saved files** (on the swarm host):')
    local f
    for f in $SAVED_FILES; do
        body+=("$(printf -- '- `%s`' "$f")")
    done
    [ -n "$UNTRACKED_SKIPPED" ] && body+=("$(printf -- '- untracked files NOT saved: %s' "$UNTRACKED_SKIPPED")")
    body+=('')
    body+=('**Restore** into a fresh worktree:')
    body+=('```bash')
    body+=("$(restore_commands "$ISSUE" "$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo HEAD)" \
        "$(git -C "$WT" symbolic-ref --quiet HEAD 2>/dev/null || echo HEAD)")")
    body+=('```')
    body+=('If none of it matters, delete the files above.')
    body+=('')
    body+=('<sub>scripts/kill-worktree.sh — saved work before reap (SWARM_REAP_GRACE_SECS).</sub>')
    gh pr comment "$pr" --body "$(printf '%s\n' "${body[@]}")" >/dev/null 2>&1 || true
}

# Closes the worker's tmux window(s). Shared by normal removal and by a
# grace deferral, which closes the window but keeps the worktree.
close_worker_windows() {
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
            tmux kill-window -t "$SESSION_NAME:iss-$ISSUE"
            echo "  ✓ killed tmux window"
        else
            echo "  - tmux window not present (skipped)"
        fi
        # issue #550: a check-on-done run normally lives as a PANE inside
        # iss-$ISSUE (killed above, pane and all) — this only catches the
        # fallback `chk-$ISSUE` WINDOW execute_check falls back to when no
        # iss-$ISSUE window existed to host the pane.
        swarm_close_chk_windows "$SESSION_NAME" "$ISSUE"
    else
        echo "  - tmux session not running (skipped window cleanup)"
    fi
}

ISSUE="${1:?usage: kill-worktree.sh <issue-number> [project-dir] [--no-compose-down] [--refuse-nonempty-inbox] [--grace] [--now]}"
PROJECT_DIR="${2:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Source the env loader to (a) pick up SWARM_WORKTREE_GROUPING from
# <project>/.swarm/.env or sandbox .env.example, and (b) get
# swarm_worktree_dir() to derive WT correctly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

# Append-only structured event log — same format/location as
# coordinator-watch.sh / kill-finished-workers.sh (EVENTS_LOG, log_event).
# issue #439: this is where a `git worktree remove` for a healthy
# (non-dangling) registration happens for every caller that reaps one — a
# human running this script directly, reap-orphan-worktrees.sh's
# healthy-registration path, or kill-finished-workers.sh's --with-worktree
# path all route through here. It is NOT the only site in this codebase
# that removes a worktree, though: reap-orphan-worktrees.sh's reap_dangling
# bypasses this script entirely for a dangling registration (git commands
# don't work inside one), and swarm-merge.sh has its own fallback removal
# for when the watcher hasn't reaped in time — both log their own
# `reap.worktree` event directly, same shape as this one (issue #446).
# Logging it at each of those three independent sites, all with the same
# event shape, is what lets coordinator-watch.sh's worktree-vanish sweep
# (worktree_vanish_sweep_pass) tell a script-driven removal apart from a
# bare `git worktree remove` run outside all of this tooling — the failure
# mode issue #439 exists to catch.
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

WT="$(swarm_worktree_dir "$PROJECT_DIR" "$ISSUE")"
BRANCH="fix/issue-$ISSUE"
WT="$(resolve_worktree_path "$PROJECT_DIR" "$BRANCH" "$WT")"
SESSION_NAME="llm-$(basename "$PROJECT_DIR")"
REAP_MARKER="$PROJECT_DIR/.swarm/reap-deferred/iss-$ISSUE"

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

    # Saved work (G1) / reap grace (G2) — see the header comment.
    compute_unsaved_state "$WT" "$DEFAULT_BRANCH"
    LANDED_NOTE=""
    [ "$LANDED_COMMITS" -gt 0 ] && LANDED_NOTE=" ($LANDED_COMMITS more already landed on $DEFAULT_BRANCH)"
    echo "  Unsaved work: $UNSAVED_COMMITS commit(s) on no remote$LANDED_NOTE, $TRACKED_CHANGES changed tracked file(s), $UNTRACKED_FILES untracked file(s) (.swarm/.local-data excluded)"

    GRACE_SECS="${SWARM_REAP_GRACE_SECS:-14400}"
    [[ "$GRACE_SECS" =~ ^[0-9]+$ ]] || GRACE_SECS=14400
    NEW_SAVE=0
    PRIOR_MARKER=0
    PRIOR_FINGERPRINT=""
    PRIOR_SAVED=""
    if [ -f "$REAP_MARKER" ]; then
        PRIOR_MARKER=1
        PRIOR_FINGERPRINT="$(sed -n 's/^fingerprint=//p' "$REAP_MARKER" | head -1)"
        PRIOR_SAVED="$(sed -n 's/^saved=//p' "$REAP_MARKER" | head -1)"
        grace_until="$(sed -n 's/^until=//p' "$REAP_MARKER" | head -1)"
        grace_until_utc="$(sed -n 's/^until_utc=//p' "$REAP_MARKER" | head -1)"
        if [ "$HAS_UNSAVED" = "0" ]; then
            echo "  - reap grace marker present, but nothing is unsaved any more — removing now"
        elif tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$ISSUE"; then
            # The worktree was re-provisioned during its grace (provision-
            # worker.sh reuses an existing worktree): the marker no longer
            # describes it. Judge this call afresh.
            echo "  - stale reap grace marker (live iss-$ISSUE window) — ignoring it"
            rm -f "$REAP_MARKER"
            PRIOR_MARKER=0
            PRIOR_FINGERPRINT=""
        elif [ "$REMOVE_NOW" = "1" ] || [ "$GRACE_SECS" = "0" ]; then
            echo "  - reap grace overridden (--now or SWARM_REAP_GRACE_SECS=0) — saving and removing now"
        elif [[ "$grace_until" =~ ^[0-9]+$ ]] && [ "$(date +%s)" -lt "$grace_until" ]; then
            echo "  ⏸ reap grace: unsaved work kept in place until ${grace_until_utc:-$grace_until} (saved copies: ${PRIOR_SAVED:-none}) — retry next reap pass; --now removes it immediately"
            exit 75
        else
            echo "  - reap grace over (${grace_until_utc:-$grace_until}) — saving and removing now"
        fi
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

    # G1: save unsaved code before anything can remove it. Skipped when a
    # deferred worktree is unchanged since the save made at deferral time.
    SAVED_FILES=""
    if [ "$HAS_UNSAVED" = "1" ]; then
        FINGERPRINT="$(work_fingerprint "$WT")"
        if [ -n "$PRIOR_FINGERPRINT" ] && [ "$FINGERPRINT" = "$PRIOR_FINGERPRINT" ] && [ -n "$PRIOR_SAVED" ]; then
            SAVED_FILES="$PRIOR_SAVED"
            echo "  - unchanged since the save at deferral time: $PRIOR_SAVED"
        else
            save_unsaved_work "$WT" "$ISSUE" "${ACTUAL_BRANCH:-$BRANCH}" "$PROJECT_DIR"
            echo "  ⚠ SAVED WORK: $SAVED_FILES"
            [ -n "$UNTRACKED_SKIPPED" ] && echo "  ⚠ untracked files NOT saved ($UNTRACKED_SKIPPED, SWARM_REAP_SAVE_UNTRACKED_MAX_MB)"
            if [ -n "$SAVE_FAILED" ]; then
                echo "  ✗ WARN: failed to save: $SAVE_FAILED"
                log_event reap.worktree.save_failed "issue=$ISSUE which=$SAVE_FAILED"
            fi
            log_event reap.worktree.saved_work "issue=$ISSUE branch=${ACTUAL_BRANCH:-$BRANCH} commits=$UNSAVED_COMMITS tracked=$TRACKED_CHANGES untracked=$UNTRACKED_FILES files=${SAVED_FILES// /,}${UNTRACKED_SKIPPED:+ untracked_skipped=yes}"
            NEW_SAVE=1
        fi

        # G2: the unattended PR-state reap closes the window but leaves the
        # worktree for a human to rescue in place, for GRACE_SECS.
        if [ "$GRACE_REQUESTED" = "1" ] && [ "$PRIOR_MARKER" = "0" ] && [ "$REMOVE_NOW" = "0" ] && [ "$GRACE_SECS" -gt 0 ]; then
            now_s="$(date +%s)"
            until_s=$((now_s + GRACE_SECS))
            until_utc="$(date -u -d "@$until_s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$until_s" +%Y-%m-%dT%H:%M:%SZ)"
            mkdir -p "$(dirname "$REAP_MARKER")"
            {
                echo "deferred_at=$now_s"
                echo "until=$until_s"
                echo "until_utc=$until_utc"
                echo "dir=$WT"
                echo "branch=${ACTUAL_BRANCH:-$BRANCH}"
                echo "fingerprint=$FINGERPRINT"
                echo "saved=$SAVED_FILES"
            } > "$REAP_MARKER.tmp.$$" && mv "$REAP_MARKER.tmp.$$" "$REAP_MARKER"
            notify_pr_work_saved "${ACTUAL_BRANCH:-$BRANCH}" "kept in place until $until_utc (\`$WT\`), then removed by the next reap pass"
            log_event reap.worktree.deferred "issue=$ISSUE branch=${ACTUAL_BRANCH:-$BRANCH} dir=$WT until=$until_utc marker=$REAP_MARKER"
            echo "  ⏸ reap grace: worktree + branch kept until $until_utc (SWARM_REAP_GRACE_SECS=$GRACE_SECS) — marker $REAP_MARKER"
            close_worker_windows
            exit 75
        fi
        [ "$NEW_SAVE" = "1" ] && notify_pr_work_saved "${ACTUAL_BRANCH:-$BRANCH}" "removed"
    fi

    # issue #495: archive .swarm/ (and, size permitting, .local-data/)
    # before the force-removal below discards them for good. See
    # archive_worktree_scratch's own comment for the full rationale.
    archive_worktree_scratch "$PROJECT_DIR" "$ISSUE" "$WT"
    if [ -n "$ARCHIVE_SWARM" ] || [ -n "$ARCHIVE_LOCALDATA" ]; then
        ARCHIVE_MSG="$ARCHIVE_SWARM"
        if [ -n "$ARCHIVE_LOCALDATA" ]; then
            ARCHIVE_MSG="${ARCHIVE_MSG:+$ARCHIVE_MSG + }$ARCHIVE_LOCALDATA"
        fi
        echo "  ⚠ ARCHIVED: $ARCHIVE_MSG"
    fi
    if [ -n "$LOCALDATA_SKIPPED" ]; then
        echo "  ⚠ SKIPPED .local-data (over SWARM_REAP_LOCALDATA_MAX_MB cap): $LOCALDATA_SKIPPED — copy it out now if it matters, it will not survive the removal below"
        log_event reap.worktree.skipped_localdata "issue=$ISSUE $LOCALDATA_SKIPPED"
    fi
    if [ -n "$ARCHIVE_MV_FAILED" ]; then
        echo "  ✗ WARN: failed to archive: $ARCHIVE_MV_FAILED (mv failed — check permissions/disk space); not preserved, will be destroyed with the worktree"
        log_event reap.worktree.archive_failed "issue=$ISSUE which=$ARCHIVE_MV_FAILED"
    fi

    # issue #446 self-review: logged AFTER a successful removal, not before.
    # An earlier issue #439 self-review moved this ahead of the removal to
    # close a sub-second race against coordinator-watch.sh's
    # worktree_vanish_sweep_pass (dir gone, event not yet written) — but
    # that traded a rare false positive for a real false negative: under
    # `set -euo pipefail`, a `git worktree remove` failure here would abort
    # the script right after a blessed reap.worktree event was already on
    # record for a worktree that's still sitting there, masking a
    # genuinely unblessed removal of the same directory within the sweep's
    # lookback window. That's strictly worse than reopening the sub-second
    # race: this reordering brings back a tiny window where a sweep tick
    # landing between `git worktree remove` completing and this log line
    # executing sees the dir gone with no event yet — the sweep's 2x
    # WATCH_WORKTREE_SWEEP_SECS lookback padding (round 7) doesn't close
    # that (it can't find an event that hasn't been written yet, no matter
    # how far back `since` is padded), so worst case is one spurious
    # coord-inbox "worktree vanished" entry for a perfectly blessed
    # removal — noise, not data loss (the salvage/removal itself already
    # happened correctly by this point). Accepted trade: a rare false
    # positive here beats a false negative that could hide a real
    # unblessed removal.
    if git worktree remove --force "$WT"; then
        log_event reap.worktree "issue=$ISSUE branch=${ACTUAL_BRANCH:-$BRANCH} dir=$WT archive=$ARCHIVE_EVENT_FIELD"
        echo "  ✓ removed worktree"
        rm -f "$REAP_MARKER"
    else
        log_event reap.worktree.error "issue=$ISSUE branch=${ACTUAL_BRANCH:-$BRANCH} dir=$WT reason=remove_failed archive=$ARCHIVE_EVENT_FIELD"
        echo "  ✗ ERROR: git worktree remove failed for $WT — left in place, no reap.worktree event logged" >&2
        exit 1
    fi
else
    echo "  - worktree dir not present (skipped)"
    rm -f "$REAP_MARKER"
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

close_worker_windows

echo
echo "Done."
