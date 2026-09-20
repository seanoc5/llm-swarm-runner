#!/usr/bin/env bash
#
# test-shape-worktree-watch-sweeps.sh — Non-LLM shape test for issue #439's
# two coordinator-watch.sh sweeps:
#
#   1. worktree_vanish_sweep_pass / wt_reap_event_since — detects a
#      worktree removed OUTSIDE every blessed reap path (kill-worktree.sh,
#      reap-orphan-worktrees.sh's dangling path, and swarm-merge.sh's
#      fallback removal all now log a `reap.worktree` event on removal —
#      see kill-worktree.sh's own header comment). A disappearance with no
#      matching reap.worktree event since it was last seen is the
#      signature of a bare `git worktree remove`/`rm -rf` run outside all
#      of this tooling (the SAMlytics wt-issue-296 incident this issue
#      exists to catch), and gets flagged via a coord-inbox write.
#      Deliberately NOT reap.window too — see wt_reap_event_since's own
#      header comment for why that would be a false-negative risk.
#
#   2. pending_brief_marker_sweep_pass / post_pending_brief_marker_sweep —
#      backstop for requeue.sh's SWARM_PENDING_BRIEF marker: a brief queued
#      before its target branch had a PR never gets a marker at all (the
#      other half of the same SAMlytics timeline). This sweep catches up
#      once the PR exists.
#
# Same technique as test-shape-stranded-worktree-briefs.sh: extracts each
# function's body verbatim (sed, not a hand-retyped copy) and exercises it
# against real (throwaway) git worktrees, so a rename/edit of any function
# under test is caught rather than silently drifting from reality.
# log_event/coord_inbox_write are reimplemented minimally here (matching
# their real output contracts exactly — see each's comment below) rather
# than extracted, since coordinator-watch.sh's real log_event also carries
# ~80 lines of glyph/pane-echo formatting this test has no reason to pull
# in; gh is stubbed via a PATH shim, same technique as test-pr-brief-marker.sh.
set -euo pipefail

export SWARM_WORKTREE_GROUPING=flat

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"
[ -r "$WATCH" ]     || red "coordinator-watch.sh not readable: $WATCH"
[ -f "$LOAD_ENV" ]  || red "not found: $LOAD_ENV"

TEST_DIR=$(mktemp -d -t shape-worktree-watch-sweeps-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

extract_fn() {
    local fn="$1" file="$2"
    sed -n "/^${fn}() {/,/^}/p" "$file"
}

PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR/.swarm"
git -C "$PROJECT_DIR" init -q -b master 2>/dev/null || (mkdir -p "$PROJECT_DIR" && cd "$PROJECT_DIR" && git init -q -b master)
git -C "$PROJECT_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# shellcheck source=/dev/null
. "$LOAD_ENV" "$PROJECT_DIR" >/dev/null 2>&1

WORKSPACE="$TEST_DIR"
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
DRY_RUN=0
# worktree_vanish_sweep_pass's since-buffer (round 6 self-review) reads
# this directly; the real script only ever calls the function with it set.
WATCH_WORKTREE_SWEEP_SECS=60
: > "$EVENTS_LOG"

# Minimal stand-in matching the real log_event's on-disk contract exactly
# (the one thing wt_reap_event_since's awk actually parses): fixed-width
# ISO8601 timestamp, category, then k=v pairs — see coordinator-watch.sh's
# own log_event for the full version (this omits its glyph/pane-echo half).
log_event() {
    local cat="$1"; shift
    printf '%s  %-15s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$cat" "$*" >> "$EVENTS_LOG"
}

# Real coord_inbox_write is this small already — extracted verbatim rather
# than reimplemented, since drift here would be silent (a test that
# reimplements it could pass while the real one broke).
eval "$(extract_fn coord_inbox_write "$WATCH")"
[ "$(type -t coord_inbox_write)" = "function" ] || red "could not extract coord_inbox_write from $WATCH — has it been renamed?"

for fn in is_own_worktree_dir own_worktree_dirs_for_scan wt_reap_event_since \
          unblessed_worktree_vanish_notify worktree_vanish_sweep_pass \
          worker_pending_brief_path worker_pending_brief \
          post_pending_brief_marker_sweep pending_brief_marker_sweep_pass; do
    body="$(extract_fn "$fn" "$WATCH")"
    [ -n "$body" ] || red "could not extract '$fn' from $WATCH — has it been renamed?"
    eval "$body"
    [ "$(type -t "$fn")" = "function" ] || red "'$fn' did not eval into a function"
done

# ============================================================================
heading "Test 1: first tick only seeds the inventory — no log, no notify"
# ============================================================================
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-296 "$TEST_DIR/wt-issue-296" master
declare -A KNOWN_WORKTREE_SEEN=()
WT_INVENTORY_SEEDED=0

worktree_vanish_sweep_pass
[ "$WT_INVENTORY_SEEDED" = "1" ] || red "expected WT_INVENTORY_SEEDED=1 after the first tick"
[ -n "${KNOWN_WORKTREE_SEEN[$TEST_DIR/wt-issue-296]:-}" ] || red "expected wt-issue-296 seeded into KNOWN_WORKTREE_SEEN"
[ ! -s "$EVENTS_LOG" ] || red "expected no events.log output on the seeding tick, got: $(cat "$EVENTS_LOG")"
[ -z "$(find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null)" ] || red "expected no coord-inbox entry on the seeding tick"
green "first tick seeds the inventory silently, no false alarm for a pre-existing worktree"

# ============================================================================
heading "Test 2: worktree removed via kill-worktree.sh (reap.worktree logged) → not flagged"
# ============================================================================
"$SCRIPT_DIR/../scripts/kill-worktree.sh" 296 "$PROJECT_DIR" >/dev/null
grep -q 'reap.worktree.*issue=296' "$EVENTS_LOG" \
    || red "expected kill-worktree.sh to log a reap.worktree event for issue 296, events.log: $(cat "$EVENTS_LOG")"

worktree_vanish_sweep_pass
grep -q 'watch.worktree_vanished' "$EVENTS_LOG" \
    && red "blessed removal (reap.worktree logged) must NOT be flagged as vanished, events.log: $(cat "$EVENTS_LOG")"
[ -z "$(find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null)" ] \
    || red "blessed removal must not write a coord-inbox entry"
green "removal through kill-worktree.sh (reap.worktree logged) is recognized as blessed — no false alarm"

# ============================================================================
heading "Test 3: worktree removed with a bare 'git worktree remove' (no event) → flagged"
# ============================================================================
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-297 "$TEST_DIR/wt-issue-297" master
declare -A KNOWN_WORKTREE_SEEN=()
WT_INVENTORY_SEEDED=0
worktree_vanish_sweep_pass   # seed
: > "$EVENTS_LOG"

git -C "$PROJECT_DIR" worktree remove --force "$TEST_DIR/wt-issue-297"
worktree_vanish_sweep_pass

grep -q 'watch.worktree_vanished.*issue=297.*reason=no_reap_event' "$EVENTS_LOG" \
    || red "expected watch.worktree_vanished for the unblessed removal, events.log: $(cat "$EVENTS_LOG")"
inbox_file="$(find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null | head -1)"
[ -n "$inbox_file" ] || red "expected a coord-inbox entry for the unblessed removal"
grep -q 'issue #297' "$inbox_file" || red "coord-inbox entry should name issue #297: $(cat "$inbox_file")"
grep -q 'reap.worktree' "$inbox_file" || red "coord-inbox entry should point at the reap.worktree mechanism: $(cat "$inbox_file")"
green "a bare 'git worktree remove' with no reap event is flagged: events.log entry + coord-inbox write"

# ============================================================================
heading "Test 4: DRY_RUN=1 detects but writes nothing to the coord-inbox"
# ============================================================================
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-298 "$TEST_DIR/wt-issue-298" master
declare -A KNOWN_WORKTREE_SEEN=()
WT_INVENTORY_SEEDED=0
worktree_vanish_sweep_pass   # seed
: > "$EVENTS_LOG"
rm -rf "$COORD_INBOX_DIR"

git -C "$PROJECT_DIR" worktree remove --force "$TEST_DIR/wt-issue-298"
DRY_RUN=1
worktree_vanish_sweep_pass
DRY_RUN=0

grep -q 'watch.worktree_vanished.*issue=298' "$EVENTS_LOG" \
    || red "expected watch.worktree_vanished to still log under DRY_RUN=1"
[ ! -d "$COORD_INBOX_DIR" ] || [ -z "$(find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null)" ] \
    || red "DRY_RUN=1 must not write a real coord-inbox entry"
green "DRY_RUN=1 still detects and logs, but writes no coord-inbox entry"

# ============================================================================
heading "Test 5: worktree destroyed via bare 'rm -rf' (registration left dangling) -> still flagged"
# ============================================================================
# Self-review round 3 finding: 'git worktree list' (what
# own_worktree_dirs_for_scan reads) keeps listing a worktree whose
# directory was rm -rf'd directly until something prunes the registration —
# the earlier tests only ever exercised the 'git worktree remove' path,
# where git's own registry drops the entry immediately.
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-299 "$TEST_DIR/wt-issue-299" master
declare -A KNOWN_WORKTREE_SEEN=()
WT_INVENTORY_SEEDED=0
worktree_vanish_sweep_pass   # seed
: > "$EVENTS_LOG"

git -C "$PROJECT_DIR" worktree list --porcelain | grep -q "wt-issue-299" \
    || red "test setup: expected wt-issue-299 registered before the rm -rf"
rm -rf "$TEST_DIR/wt-issue-299"
git -C "$PROJECT_DIR" worktree list --porcelain | grep -q "wt-issue-299" \
    || red "test setup: registration should still list wt-issue-299 right after a bare rm -rf (that's the whole point of this test)"

worktree_vanish_sweep_pass

grep -q 'watch.worktree_vanished.*issue=299.*reason=no_reap_event' "$EVENTS_LOG" \
    || red "expected a bare 'rm -rf' (registration still present) to be flagged as vanished, events.log: $(cat "$EVENTS_LOG")"
inbox_file="$(find "$COORD_INBOX_DIR" -maxdepth 1 -type f -newer "$EVENTS_LOG" 2>/dev/null | head -1)"
[ -n "$inbox_file" ] || inbox_file="$(find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null | grep -v 297 | tail -1)"
[ -n "$inbox_file" ] || red "expected a coord-inbox entry for the rm -rf'd worktree"
grep -q 'issue #299' "$inbox_file" || red "coord-inbox entry should name issue #299: $(cat "$inbox_file")"
green "a bare 'rm -rf' (git registration left dangling) is detected exactly like 'git worktree remove'"

git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true

# ============================================================================
heading "Test 6: a transient git failure does NOT flag every tracked worktree as vanished"
# ============================================================================
# Self-review round 5 finding: own_worktree_dirs_for_scan can legitimately
# return empty with rc 0 when git is healthy but there truly are zero
# worktrees (its own git-common-dir check) — this test instead breaks git
# itself for PROJECT_DIR, which is the failure mode the guard exists for.
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-300 "$TEST_DIR/wt-issue-300" master
declare -A KNOWN_WORKTREE_SEEN=()
WT_INVENTORY_SEEDED=0
worktree_vanish_sweep_pass   # seed
[ -n "${KNOWN_WORKTREE_SEEN[$TEST_DIR/wt-issue-300]:-}" ] || red "test setup: expected wt-issue-300 seeded before breaking git"
: > "$EVENTS_LOG"
rm -rf "$COORD_INBOX_DIR"

mv "$PROJECT_DIR/.git" "$PROJECT_DIR/.git.disabled"
rc=0; worktree_vanish_sweep_pass || rc=$?
mv "$PROJECT_DIR/.git.disabled" "$PROJECT_DIR/.git"

[ "$rc" -ne 0 ] || red "expected worktree_vanish_sweep_pass to return non-zero when git is unavailable"
grep -q 'watch.worktree_sweep.error.*reason=git_unavailable' "$EVENTS_LOG" \
    || red "expected watch.worktree_sweep.error logged, events.log: $(cat "$EVENTS_LOG")"
grep -q 'watch.worktree_vanished' "$EVENTS_LOG" \
    && red "a transient git failure must NOT flag anything as vanished, events.log: $(cat "$EVENTS_LOG")"
[ -z "$(find "$COORD_INBOX_DIR" -maxdepth 1 -type f 2>/dev/null)" ] \
    || red "a transient git failure must not write any coord-inbox entry"
[ -n "${KNOWN_WORKTREE_SEEN[$TEST_DIR/wt-issue-300]:-}" ] \
    || red "expected wt-issue-300 to remain tracked (untouched) after a skipped tick"
green "a transient git failure skips the whole tick instead of mass-flagging every known worktree"

# ============================================================================
heading "Test 7: a slow removal spanning a tick is NOT misread as unblessed"
# ============================================================================
# Self-review round 6 finding: kill-worktree.sh logs reap.worktree BEFORE
# `git worktree remove`, which can itself take real wall-clock time on a
# big worktree — long enough for a sweep tick to land WHILE it's still
# running (dir still present, so last-seen keeps advancing past the
# already-logged event's timestamp). Reproduced directly here: seed,
# manually log reap.worktree for issue 301, then advance its last-seen
# timestamp PAST that log line (simulating exactly that mid-removal tick)
# before the directory actually disappears.
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-301 "$TEST_DIR/wt-issue-301" master
declare -A KNOWN_WORKTREE_SEEN=()
WT_INVENTORY_SEEDED=0
worktree_vanish_sweep_pass   # seed
: > "$EVENTS_LOG"

reap_epoch=$(date +%s)
log_event reap.worktree "issue=301 branch=fix/issue-301 dir=$TEST_DIR/wt-issue-301"
# Simulate a last-seen bump 45s after the log line (within the
# WATCH_WORKTREE_SWEEP_SECS=60 buffer, but still later than reap_epoch) —
# without the round-6 padding fix this alone reproduces the false alarm.
KNOWN_WORKTREE_SEEN["$TEST_DIR/wt-issue-301"]=$(( reap_epoch + 45 ))
rm -rf "$TEST_DIR/wt-issue-301"
git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true

worktree_vanish_sweep_pass

grep -q 'watch.worktree_vanished.*issue=301' "$EVENTS_LOG" \
    && red "a slow-but-blessed removal (last-seen bumped past its own reap.worktree log) must NOT be flagged, events.log: $(cat "$EVENTS_LOG")"
green "the since-buffer tolerates a last-seen bump landing after the removal's own reap.worktree log"

# ─────────────────────────── gh stub (ask 2) ────────────────────────────────

SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
GH_LOG="$TEST_DIR/gh.log"
COMMENTS_LOG="$TEST_DIR/comments.log"
: > "$GH_LOG"
: > "$COMMENTS_LOG"

# fix/issue-90 -> PR #77, OPEN. Every other branch -> no PR.
cat > "$SHIM_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    target="\$3"
    json=""
    prev=""
    for a in "\$@"; do
        [ "\$prev" = "--json" ] && json="\$a"
        prev="\$a"
    done
    case "\$json" in
        number,state)
            if [ "\$target" = "fix/issue-90" ]; then printf '77\tOPEN\n'; exit 0; fi
            exit 1
            ;;
        comments)
            [ "\$target" = "77" ] || exit 1
            if [ -s "$COMMENTS_LOG" ]; then
                tail -n1 "$COMMENTS_LOG" | base64 -d
            fi
            exit 0
            ;;
        *) exit 1 ;;
    esac
fi
if [ "\$1" = "pr" ] && [ "\$2" = "comment" ]; then
    body=""
    prev=""
    for a in "\$@"; do
        [ "\$prev" = "--body" ] && body="\$a"
        prev="\$a"
    done
    printf '%s' "\$body" | base64 -w0 >> "$COMMENTS_LOG"
    printf '\n' >> "$COMMENTS_LOG"
    exit 0
fi
exit 1
EOF
chmod +x "$SHIM_DIR/gh"
gh_comment_count() { wc -l < "$COMMENTS_LOG" | tr -d ' '; }
gh_last_comment()  { tail -n1 "$COMMENTS_LOG" | base64 -d; }

git -C "$PROJECT_DIR" worktree add -q -b fix/issue-90 "$TEST_DIR/wt-issue-90" master
mkdir -p "$TEST_DIR/wt-issue-90/.swarm/tasks/inbox"

# ============================================================================
heading "Test 8: pending brief + OPEN PR + no existing marker -> posts SWARM_PENDING_BRIEF: queued"
# ============================================================================
echo "follow-up: fix the thing" > "$TEST_DIR/wt-issue-90/.swarm/tasks/inbox/20260919-183600-90.md"
: > "$EVENTS_LOG"

PATH="$SHIM_DIR:$PATH" pending_brief_marker_sweep_pass

[ "$(gh_comment_count)" -eq 1 ] || red "expected exactly 1 posted comment, got $(gh_comment_count)"
gh_last_comment | grep -q 'SWARM_PENDING_BRIEF: queued' \
    || red "posted comment missing SWARM_PENDING_BRIEF: queued marker: $(gh_last_comment)"
gh_last_comment | grep -q 'follow-up: fix the thing' \
    || red "expected the brief's own text excerpted into the comment: $(gh_last_comment)"
gh_last_comment | grep -qi 'issue #439' \
    || red "expected the sweep's own comment to reference issue #439: $(gh_last_comment)"
grep -q 'watch.pending_brief_sweep.*pr=77.*reason=posted' "$EVENTS_LOG" \
    || red "expected watch.pending_brief_sweep logged, events.log: $(cat "$EVENTS_LOG")"
green "an inbox brief queued before its PR existed gets caught up by the sweep"

# ============================================================================
heading "Test 9: a second sweep tick while still 'queued' does NOT re-post (idempotent)"
# ============================================================================
: > "$EVENTS_LOG"
PATH="$SHIM_DIR:$PATH" pending_brief_marker_sweep_pass
[ "$(gh_comment_count)" -eq 1 ] || red "expected still exactly 1 posted comment (no duplicate), got $(gh_comment_count)"
[ -z "$(grep 'watch.pending_brief_sweep' "$EVENTS_LOG" || true)" ] \
    || red "expected no watch.pending_brief_sweep line on the idempotent no-op tick"
green "sweep is idempotent — does not re-post while the marker already says queued"

# ============================================================================
heading "Test 10: empty inbox -> sweep does not post anything"
# ============================================================================
rm -f "$TEST_DIR/wt-issue-90/.swarm/tasks/inbox"/*.md
: > "$COMMENTS_LOG"
: > "$EVENTS_LOG"
PATH="$SHIM_DIR:$PATH" pending_brief_marker_sweep_pass
[ "$(gh_comment_count)" -eq 0 ] || red "expected no comment posted for an empty inbox"
green "an empty inbox is silently skipped"

green "ALL TESTS PASSED"
