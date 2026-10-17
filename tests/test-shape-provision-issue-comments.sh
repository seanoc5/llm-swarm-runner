#!/usr/bin/env bash
#
# test-shape-provision-issue-comments.sh — Regression test for issue #634:
# provision-worker.sh built a worker's brief from `gh issue view N` alone,
# which prints only the issue BODY. Any correction the issue's author
# posted afterward as a comment (a wording fix, a revised scope, a table
# that needed updating) never reached the brief, so the worker built from
# the stale body and the coordinator caught the gap only on review.
#
# Covers the fix: provision-worker.sh now also fetches
# `gh issue view N --json comments` and appends a formatted
# "## Issue comments (may supersede the body)" section (format_issue_comments)
# — author + timestamp, oldest first / newest last, truncated from the
# oldest end with a note when the section would exceed its budget.
#
# Full end-to-end run of the real provision-worker.sh (not an extracted
# function), same harness shape as test-shape-host-admission.sh: a real git
# project + stubbed gh/tmux/docker on PATH.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEST_DIR=$(mktemp -d -t shape-provision-issue-comments-XXXXXX)
cleanup() { [ "${KEEP:-0}" = "1" ] && { echo "KEEP=1: leaving $TEST_DIR" >&2; return; }; rm -rf "$TEST_DIR"; }
trap cleanup EXIT
mkdir -p "$TEST_DIR/bin"

# Minimal project: a git repo with one commit, a .swarm dir, no .swarm/.env.
PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR/.swarm"
git -C "$PROJECT_DIR" init -q -b master
git -C "$PROJECT_DIR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git clone -q --bare "$PROJECT_DIR" "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" remote add origin "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" fetch -q origin

# gh stub: `issue view N` prints a fixed body; `issue view N --json comments`
# prints whatever JSON this test dropped at $TEST_DIR/comments-<N>.json (a
# missing fixture means "no comments", like a real issue with none).
cat > "$TEST_DIR/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "view" ]; then
    n="\${3:-}"
    if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
        # comments-fail-<N>: the BODY call (plain 'issue view N') succeeds
        # but this second, comments-only call fails on its own — distinct
        # from a 404 on the first call, which test-shape-host-admission.sh
        # already covers.
        [ -e "$TEST_DIR/comments-fail-\$n" ] && { echo "stub-gh: synthetic --json comments failure" >&2; exit 1; }
        f="$TEST_DIR/comments-\$n.json"
        [ -f "\$f" ] && cat "\$f" || echo '{"comments":[]}'
        exit 0
    fi
    echo "FAKE-GH issue #\$n: synthetic body for shape test"
    exit 0
fi
echo "stub-gh: unhandled args: \$*" >&2; exit 1
STUB
cat > "$TEST_DIR/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    has-session)   exit 0 ;;
    list-windows)  echo "coordinator"; echo "util" ;;
    new-window)    echo "\$*" >> "$TEST_DIR/tmux.log" ;;
esac
exit 0
STUB
cat > "$TEST_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TEST_DIR"/bin/*
export PATH="$TEST_DIR/bin:$PATH"
export HOST_STATE_DIR="$TEST_DIR/host-state"
export LLM_SWARM_DIR="$TEST_DIR/sandbox"
mkdir -p "$LLM_SWARM_DIR/scripts" "$HOST_STATE_DIR"
cp "$SCRIPT_DIR/../sandbox.sh" "$LLM_SWARM_DIR/sandbox.sh"
cp "$SCRIPT_DIR"/../scripts/_load-env.sh "$LLM_SWARM_DIR/scripts/"
cp "$SCRIPT_DIR"/../scripts/_window-flags.sh "$LLM_SWARM_DIR/scripts/"
cp "$SCRIPT_DIR"/../scripts/provision-worker.sh "$LLM_SWARM_DIR/scripts/"
cp "$SCRIPT_DIR"/../scripts/lint-brief.sh "$LLM_SWARM_DIR/scripts/" 2>/dev/null || true
PROVISION="$LLM_SWARM_DIR/scripts/provision-worker.sh"

# Bypass every host/session cap this test isn't about (same knobs as
# test-shape-host-admission.sh's "off").
off=(HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0 PROVISION_SPAWN_CHECK_SECS=0 BRIEF_LINT=0)

run_prov() {  # $1 issue, rest = env assignments; prints exit code
    local issue="$1"; shift
    set +e
    ( cd "$PROJECT_DIR" && env "$@" bash "$PROVISION" "$issue" > "$TEST_DIR/prov-$issue.log" 2>&1 )
    local rc=$?
    set -e
    echo "$rc"
}

brief_for() {  # $1 issue -> prints the single brief file's path, or errors
    local issue="$1" f
    # SWARM_WORKTREE_GROUPING defaults to flat: $TEST_DIR/wt-issue-N, a
    # sibling of $PROJECT_DIR ($TEST_DIR/proj) — see swarm_worktree_dir().
    f="$(find "$TEST_DIR" -maxdepth 6 -path "*wt-issue-$issue/.swarm/tasks/inbox/*.md" 2>/dev/null | head -1)"
    [ -n "$f" ] || red "no brief found for issue #$issue under $TEST_DIR (check: $(cat "$TEST_DIR/prov-$issue.log"))"
    printf '%s' "$f"
}

# ============================================================================
heading "1: no comments -> no 'Issue comments' section at all"
# ============================================================================
rm -f "$TEST_DIR/comments-21.json"
rc=$(run_prov 21 "${off[@]}")
[ "$rc" -eq 0 ] || red "expected admitted spawn, rc=$rc: $(cat "$TEST_DIR/prov-21.log")"
BRIEF="$(brief_for 21)"
grep -q 'Issue comments' "$BRIEF" && red "no-comments brief should not have an Issue comments section: $BRIEF"
green "an issue with 0 comments gets no Issue comments section"

# ============================================================================
heading "2: a single comment appears in the brief with author + timestamp"
# ============================================================================
cat > "$TEST_DIR/comments-22.json" <<'JSON'
{"comments":[
  {"createdAt":"2026-10-15T09:00:00Z","author":{"login":"seanoc5"},"body":"Correction: the table needs all five groups, not three."}
]}
JSON
rc=$(run_prov 22 "${off[@]}")
[ "$rc" -eq 0 ] || red "expected admitted spawn, rc=$rc: $(cat "$TEST_DIR/prov-22.log")"
BRIEF="$(brief_for 22)"
grep -q '^## Issue comments (may supersede the body)$' "$BRIEF" || red "missing Issue comments heading in $BRIEF"
grep -q '### 2026-10-15T09:00:00Z — seanoc5' "$BRIEF" || red "missing author+timestamp line in $BRIEF"
grep -q 'the table needs all five groups' "$BRIEF" || red "comment body missing from $BRIEF"
green "a comment on the issue appears in the written brief, with author and timestamp"

# ============================================================================
heading "3: two comments appear newest LAST"
# ============================================================================
cat > "$TEST_DIR/comments-23.json" <<'JSON'
{"comments":[
  {"createdAt":"2026-10-15T09:00:00Z","author":{"login":"seanoc5"},"body":"FIRST: original wording fix."},
  {"createdAt":"2026-10-15T11:00:00Z","author":{"login":"seanoc5"},"body":"SECOND: supersedes the first, use the new deck revision."}
]}
JSON
rc=$(run_prov 23 "${off[@]}")
[ "$rc" -eq 0 ] || red "expected admitted spawn, rc=$rc: $(cat "$TEST_DIR/prov-23.log")"
BRIEF="$(brief_for 23)"
first_line="$(grep -n 'FIRST:' "$BRIEF" | head -1 | cut -d: -f1)"
second_line="$(grep -n 'SECOND:' "$BRIEF" | head -1 | cut -d: -f1)"
[ -n "$first_line" ] && [ -n "$second_line" ] || red "both comments should appear in $BRIEF"
[ "$second_line" -gt "$first_line" ] || red "expected newest comment (SECOND) after the oldest (FIRST), got FIRST@$first_line SECOND@$second_line"
green "comments appear oldest first / newest last"

# ============================================================================
heading "4: truncation drops the OLDEST comment and says so, keeping the newest"
# ============================================================================
cat > "$TEST_DIR/comments-24.json" <<'JSON'
{"comments":[
  {"createdAt":"2026-10-15T09:00:00Z","author":{"login":"seanoc5"},"body":"OLDEST comment, long enough to matter for the byte budget below."},
  {"createdAt":"2026-10-15T11:00:00Z","author":{"login":"seanoc5"},"body":"NEWEST comment, the one that must survive truncation."}
]}
JSON
rc=$(run_prov 24 "${off[@]}" BRIEF_COMMENTS_MAX_CHARS=90)
[ "$rc" -eq 0 ] || red "expected admitted spawn, rc=$rc: $(cat "$TEST_DIR/prov-24.log")"
BRIEF="$(brief_for 24)"
grep -q 'OLDEST comment' "$BRIEF" && red "oldest comment should have been dropped from $BRIEF"
grep -q 'NEWEST comment' "$BRIEF" || red "newest comment should survive truncation in $BRIEF"
grep -qi 'omitted here for length' "$BRIEF" || red "truncation should be noted in $BRIEF"
green "truncation drops the oldest comment, keeps the newest, and says so in the brief"

# ============================================================================
heading "5: the swarm's own SWARM_PENDING_BRIEF marker comment is filtered out (self-review finding)"
# ============================================================================
# requeue.sh / worker-listener.sh post these from the operator's own gh
# account, which is often the issue author — without filtering, a queued
# marker would outrank (and crowd out) a real correction under the "issue
# author's latest comment wins" rule in worker.md.
cat > "$TEST_DIR/comments-25.json" <<'JSON'
{"comments":[
  {"createdAt":"2026-10-15T09:00:00Z","author":{"login":"seanoc5"},"body":"REAL correction: use the new deck revision."},
  {"createdAt":"2026-10-15T11:00:00Z","author":{"login":"seanoc5"},"body":"<!-- SWARM_PENDING_BRIEF: queued -->\nA follow-up brief has been queued."}
]}
JSON
rc=$(run_prov 25 "${off[@]}")
[ "$rc" -eq 0 ] || red "expected admitted spawn, rc=$rc: $(cat "$TEST_DIR/prov-25.log")"
BRIEF="$(brief_for 25)"
grep -q 'REAL correction' "$BRIEF" || red "the real correction should still appear in $BRIEF"
grep -q 'SWARM_PENDING_BRIEF' "$BRIEF" && red "the swarm's own marker comment should be filtered out of $BRIEF"
green "a SWARM_PENDING_BRIEF marker comment is filtered out; the real correction survives"

# ============================================================================
heading "6: a comment with a null body does not crash the whole run (self-review finding)"
# ============================================================================
# jq's test() errors on a null input; under set -e that would have aborted
# the entire provision run (not just dropped the comments section) before
# this was guarded with (.body // "").
cat > "$TEST_DIR/comments-26.json" <<'JSON'
{"comments":[
  {"createdAt":"2026-10-15T09:00:00Z","author":{"login":"seanoc5"},"body":null},
  {"createdAt":"2026-10-15T11:00:00Z","author":{"login":"seanoc5"},"body":"SURVIVES: a real comment after a null-body one."}
]}
JSON
rc=$(run_prov 26 "${off[@]}")
[ "$rc" -eq 0 ] || red "a null-body comment should not abort the whole run, rc=$rc: $(cat "$TEST_DIR/prov-26.log")"
BRIEF="$(brief_for 26)"
grep -q 'SURVIVES: a real comment' "$BRIEF" || red "the real comment after the null-body one should still appear in $BRIEF"
green "a null-body comment is tolerated; the run completes and the next real comment still appears"

# ============================================================================
heading "7: the body fetch succeeds but the comments fetch fails -> exit 2, nothing queued (self-review finding)"
# ============================================================================
: > "$TEST_DIR/comments-fail-27"
rc=$(run_prov 27 "${off[@]}")
[ "$rc" -eq 2 ] || red "a failed --json comments call should exit 2 like the body-fetch failure does, rc=$rc: $(cat "$TEST_DIR/prov-27.log")"
[ -z "$(find "$TEST_DIR" -path "*wt-issue-27/.swarm/tasks/inbox/*" -type f 2>/dev/null)" ] || red "no brief (or .tmp file) should be left in inbox/ when the comments fetch fails"
green "a comments-fetch failure (body fetch already succeeded) exits 2 with nothing queued, same contract as a body-fetch failure"

echo
green "all provision-worker.sh issue-comments shape tests passed"
