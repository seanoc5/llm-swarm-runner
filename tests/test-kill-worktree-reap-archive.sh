#!/usr/bin/env bash
#
# test-kill-worktree-reap-archive.sh — Non-LLM regression test for issue
# #495: kill-worktree.sh archived the #317 task-queue salvage
# (inbox/processing/outbox) but nothing else a worker wrote under the
# worktree — `.swarm/logs/`, `.swarm/tasks/status/`, or `.local-data/`
# working output — before `git worktree remove --force` destroyed it.
# Two fand-etl incidents on 2026-09-28 lost exactly this: corrected output
# data under `.local-data/` (iss-1103, reaped by the watcher's sanctioned
# autoclose) and incident-evidence logs under `.swarm/logs/` (iss-1010,
# reaped by #489's gh-side removal).
#
# Covers kill-worktree.sh (the direct call every other reaper routes
# through, except reap-orphan-worktrees.sh's dangling-registration path,
# covered separately below since it can't route through kill-worktree.sh
# at all — no working git inside a dangling registration).
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_WT="$SCRIPT_DIR/../scripts/kill-worktree.sh"
REAP_ORPHAN="$SCRIPT_DIR/../scripts/reap-orphan-worktrees.sh"
[ -x "$KILL_WT" ] || red "kill-worktree.sh not executable: $KILL_WT"
[ -x "$REAP_ORPHAN" ] || red "reap-orphan-worktrees.sh not executable: $REAP_ORPHAN"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t kill-wt-reap-archive-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

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
heading "Test 1: .swarm/ (logs + a queued brief) and under-cap .local-data/ are both archived"
# ============================================================================

PROJ1="$TEST_DIR/proj1"
new_project "$PROJ1"
git -C "$PROJ1" worktree add -q -b fix/issue-71 "$TEST_DIR/wt-issue-71"
WT1="$TEST_DIR/wt-issue-71"

mkdir -p "$WT1/.swarm/logs" "$WT1/.swarm/tasks/inbox" "$WT1/.local-data/output"
echo "incident evidence"      > "$WT1/.swarm/logs/incident.log"
echo "queued follow-up brief" > "$WT1/.swarm/tasks/inbox/20260101-000000-71.md"
echo "corrected numbers"      > "$WT1/.local-data/output/corrected.csv"

RUN1="$TEST_DIR/run1.log"
set +e
(cd "$PROJ1" && "$KILL_WT" 71 "$PROJ1") > "$RUN1" 2>&1
RC1=$?
set -e
[ "$RC1" -eq 0 ] || red "expected exit 0, got $RC1. Output:
$(cat "$RUN1")"

grep -q '⚠ ARCHIVED:' "$RUN1" \
    || red "expected an ARCHIVED line. Output:
$(cat "$RUN1")"
green "kill-worktree.sh printed an ARCHIVED line"

ARCHIVE_SWARM_DIR="$(find "$PROJ1/.swarm/reaped" -maxdepth 1 -name 'iss-71-*.swarm' -type d 2>/dev/null | head -1)"
[ -n "$ARCHIVE_SWARM_DIR" ] \
    || red ".swarm/ was not archived under $PROJ1/.swarm/reaped/"
[ -f "$ARCHIVE_SWARM_DIR/logs/incident.log" ] \
    || red "incident.log did not survive the .swarm/ archive: $ARCHIVE_SWARM_DIR"
green ".swarm/logs/incident.log survived the reap under .swarm/reaped/"

# The #317 salvage runs first and moves the queued brief to
# .swarm/salvaged/, NOT into the .swarm/reaped/ archive — both must be
# satisfied, and the salvage must not be regressed by the archive step
# running right after it.
[ -f "$PROJ1/.swarm/salvaged/iss-71/inbox/20260101-000000-71.md" ] \
    || red "the #317 salvage of the queued inbox brief regressed"
green "the #317 inbox salvage still runs (and isn't clobbered by the new archive step)"

ARCHIVE_LOCALDATA_DIR="$(find "$PROJ1/.swarm/reaped" -maxdepth 1 -name 'iss-71-*.local-data' -type d 2>/dev/null | head -1)"
[ -n "$ARCHIVE_LOCALDATA_DIR" ] \
    || red ".local-data/ was not archived under $PROJ1/.swarm/reaped/"
[ -f "$ARCHIVE_LOCALDATA_DIR/output/corrected.csv" ] \
    || red "corrected.csv did not survive the .local-data/ archive: $ARCHIVE_LOCALDATA_DIR"
green ".local-data/output/corrected.csv survived the reap under .swarm/reaped/"

[ ! -d "$WT1" ] || red "worktree dir still present after removal: $WT1"
green "worktree still removed as normal despite the archive step"

EVENTS_LOG1="$PROJ1/.swarm/events.log"
[ -f "$EVENTS_LOG1" ] || red "no events.log written: $EVENTS_LOG1"
grep -qE "reap\.worktree +issue=71 .*archive=$PROJ1/\.swarm/reaped/iss-71-[0-9TZ]+\.swarm( |\$)" "$EVENTS_LOG1" \
    || red "reap.worktree event did not name the archive location. Log:
$(cat "$EVENTS_LOG1")"
green "reap.worktree event names the archive location"

# ============================================================================
heading "Test 2: .local-data/ over the size cap is skipped (logged + printed), not silently archived"
# ============================================================================

PROJ2="$TEST_DIR/proj2"
new_project "$PROJ2"
git -C "$PROJ2" worktree add -q -b fix/issue-72 "$TEST_DIR/wt-issue-72"
WT2="$TEST_DIR/wt-issue-72"

mkdir -p "$WT2/.local-data"
echo "some output" > "$WT2/.local-data/big.csv"

RUN2="$TEST_DIR/run2.log"
set +e
(cd "$PROJ2" && SWARM_REAP_LOCALDATA_MAX_MB=0 "$KILL_WT" 72 "$PROJ2") > "$RUN2" 2>&1
RC2=$?
set -e
[ "$RC2" -eq 0 ] || red "expected exit 0, got $RC2. Output:
$(cat "$RUN2")"

grep -q 'SKIPPED .local-data' "$RUN2" \
    || red "expected a SKIPPED .local-data line under a zero cap. Output:
$(cat "$RUN2")"
green "kill-worktree.sh printed a SKIPPED .local-data line under SWARM_REAP_LOCALDATA_MAX_MB=0"

[ ! -d "$(find "$PROJ2/.swarm/reaped" -maxdepth 1 -name 'iss-72-*.local-data' -type d 2>/dev/null | head -1)" 2>/dev/null ] \
    || red ".local-data/ should NOT have been archived over the cap"

grep -qE 'reap\.worktree\.skipped_localdata +issue=72 size=' "$PROJ2/.swarm/events.log" \
    || red "expected a reap.worktree.skipped_localdata event. Log:
$(cat "$PROJ2/.swarm/events.log" 2>/dev/null || echo '(missing)')"
green "reap.worktree.skipped_localdata event logged with a size"

[ ! -d "$WT2" ] || red "worktree dir still present after removal: $WT2"
green "worktree still removed as normal even though .local-data/ was skipped"

# ============================================================================
heading "Test 3: no .swarm/ or .local-data/ reaps exactly as before (no archive output, no reaped/ dir)"
# ============================================================================

PROJ3="$TEST_DIR/proj3"
new_project "$PROJ3"
git -C "$PROJ3" worktree add -q -b fix/issue-73 "$TEST_DIR/wt-issue-73"

RUN3="$TEST_DIR/run3.log"
set +e
(cd "$PROJ3" && "$KILL_WT" 73 "$PROJ3") > "$RUN3" 2>&1
RC3=$?
set -e
[ "$RC3" -eq 0 ] || red "expected exit 0, got $RC3. Output:
$(cat "$RUN3")"
grep -qi 'ARCHIVED\|SKIPPED .local-data' "$RUN3" \
    && red "empty worktree reap must not mention archive/skip. Output:
$(cat "$RUN3")"
[ ! -d "$PROJ3/.swarm/reaped" ] \
    || red "empty worktree reap must not create a .swarm/reaped/ dir"
green "reap with nothing to archive produced no archive output and no reaped/ dir"

# ============================================================================
heading "Test 4: reap-orphan-worktrees.sh's dangling-registration path also archives .swarm/"
# ============================================================================
# Mirrors test-scripts.sh's test_dangling_registration_reap fixture (issue
# #225): corrupt the worktree's git registration so no git command run
# inside it works, then verify reap_dangling's own copy of the archive
# step (it cannot route through kill-worktree.sh at all) still preserves
# .swarm/ before the rm -rf that follows.

PROJ4="$TEST_DIR/proj4"
new_project "$PROJ4"
WT4="$TEST_DIR/wt-issue-74"
git -C "$PROJ4" worktree add -q -b fix/issue-74 "$WT4"
mkdir -p "$WT4/.swarm/logs"
echo "dangling-path evidence" > "$WT4/.swarm/logs/incident.log"

rm -rf "$PROJ4/.git/worktrees/wt-issue-74"
git -C "$WT4" rev-parse --git-dir >/dev/null 2>&1 \
    && red "fixture setup didn't actually corrupt the registration"

FAKEBIN="$TEST_DIR/fakebin4"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    printf 'fix/issue-74\tMERGED\n'
    exit 0
fi
exit 1
FAKEGH
chmod +x "$FAKEBIN/gh"

RUN4="$TEST_DIR/run4.log"
set +e
(cd "$PROJ4" && PATH="$FAKEBIN:$PATH" "$REAP_ORPHAN" --yes --min-age-days 0 --project "$PROJ4") > "$RUN4" 2>&1
RC4=$?
set -e
[ "$RC4" -eq 0 ] || red "expected exit 0, got $RC4. Output:
$(cat "$RUN4")"

[ ! -d "$WT4" ] || red "dangling worktree directory was not removed"

ARCHIVE4_DIR="$(find "$PROJ4/.swarm/reaped" -maxdepth 1 -name 'iss-74-*.swarm' -type d 2>/dev/null | head -1)"
[ -n "$ARCHIVE4_DIR" ] \
    || red "dangling-path .swarm/ was not archived. Output:
$(cat "$RUN4")"
[ -f "$ARCHIVE4_DIR/logs/incident.log" ] \
    || red "incident.log did not survive the dangling-path .swarm/ archive: $ARCHIVE4_DIR"
green "reap_dangling archived .swarm/logs/incident.log before the rm -rf"

grep -qE "reap\.worktree +issue=74 .*archive=$PROJ4/\.swarm/reaped/iss-74-[0-9TZ]+\.swarm( |\$)" "$PROJ4/.swarm/events.log" \
    || red "reap.worktree event (dangling path) did not name the archive location. Log:
$(cat "$PROJ4/.swarm/events.log")"
green "reap.worktree event (dangling path) names the archive location"

echo
green "ALL TESTS PASSED"
