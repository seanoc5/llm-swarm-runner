#!/usr/bin/env bash
#
# test-shape-own-worktrees.sh — Non-LLM shape test for issue #357:
# coordinator/monitoring triage globbing "$parent/wt-issue-*" used to match
# ANY directory of that name under a shared flat-grouping parent, including
# a SIBLING project's worker worktree — issue numbers carry no project
# identity, so the collision is silent.
#
# Fixture: two independent git repos ("proj" — the project under test, and
# "other" — a stand-in for a sibling swarm's repo) both checked out under
# the same flat-grouping parent dir, each with their own `wt-issue-N`
# worktree, including a DELIBERATE issue-number collision (both have a
# wt-issue-999 — different origin, different repo).
#
# Asserts that:
#   1. swarm_own_worktree_dirs() (scripts/_load-env.sh) lists only "proj"'s
#      own worktrees — never "other"'s, even at the colliding number.
#   2. scripts/list-own-worktrees.sh (the CLI wrapper) agrees.
#   3. scripts/reap-orphan-worktrees.sh's dry-run scan never mentions
#      "other"'s worktrees and its FOUND count matches "proj"'s own count.
#   4. scripts/kill-finished-workers.sh's dry-run touches "proj"'s own
#      windows only — "other"'s same-numbered worktree is never referenced,
#      because the script iterates tmux windows within THIS project's own
#      session, never a directory glob.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"
LIST_OWN="$SCRIPT_DIR/../scripts/list-own-worktrees.sh"
REAP_ORPHAN="$SCRIPT_DIR/../scripts/reap-orphan-worktrees.sh"
KILL_FINISHED="$SCRIPT_DIR/../scripts/kill-finished-workers.sh"
[ -f "$LOAD_ENV" ]      || red "not found: $LOAD_ENV"
[ -x "$LIST_OWN" ]      || red "not found/executable: $LIST_OWN"
[ -x "$REAP_ORPHAN" ]   || red "not found/executable: $REAP_ORPHAN"
[ -x "$KILL_FINISHED" ] || red "not found/executable: $KILL_FINISHED"

REAL_TMUX="$(command -v tmux)" || red "tmux not installed"
command -v git >/dev/null || red "git not installed"

TEST_DIR=$(mktemp -d -t shape-own-worktrees-XXXXXX)
TEST_SOCK="sow-test-$$"
cleanup() {
    "$REAL_TMUX" -L "$TEST_SOCK" kill-server 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────── Fixture: two sibling git repos ──────────────────────
# Flat grouping: both projects' worktrees are siblings under the same
# parent dir ($TEST_DIR/main), exactly the layout issue #357 is about.

mkdir -p "$TEST_DIR/main"
export SWARM_WORKTREE_GROUPING=flat

PROJECT_DIR="$TEST_DIR/main/proj"
git init -q -b master "$PROJECT_DIR"
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name "Test"
git -C "$PROJECT_DIR" commit -q --allow-empty -m init
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-1 "$TEST_DIR/main/wt-issue-1" master
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-2 "$TEST_DIR/main/wt-issue-2" master

OTHER_DIR="$TEST_DIR/main/other"
git init -q -b master "$OTHER_DIR"
git -C "$OTHER_DIR" config user.email test@example.com
git -C "$OTHER_DIR" config user.name "Test"
git -C "$OTHER_DIR" commit -q --allow-empty -m init
# Deliberate collision: "other"'s own issue-999 worktree lands at the exact
# same path a "proj" issue-999 worktree would use under flat grouping.
git -C "$OTHER_DIR" worktree add -q -b fix/issue-999 "$TEST_DIR/main/wt-issue-999" master

# ─────────────────────── gh shim: always "no PR" (offline-safe, deterministic) ──
SHIM_DIR="$TEST_DIR/shims"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TEST_SOCK" "\$@"
EOF
chmod +x "$SHIM_DIR/tmux"
cat > "$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SHIM_DIR/gh"

# ============================================================================
heading "Test 1: swarm_own_worktree_dirs() lists proj's own worktrees only"
# ============================================================================
OUT="$(
    . "$LOAD_ENV" "$PROJECT_DIR" >/dev/null 2>&1
    swarm_own_worktree_dirs "$PROJECT_DIR" | sort
)"
EXPECTED="$(printf '%s\n%s' "$TEST_DIR/main/wt-issue-1" "$TEST_DIR/main/wt-issue-2")"
[ "$OUT" = "$EXPECTED" ] || red "swarm_own_worktree_dirs mismatch:
got:
$OUT
want:
$EXPECTED"
echo "$OUT" | grep -q wt-issue-999 && red "swarm_own_worktree_dirs leaked other's wt-issue-999"
green "swarm_own_worktree_dirs() excludes other's colliding wt-issue-999"

# ============================================================================
heading "Test 2: list-own-worktrees.sh (CLI wrapper) agrees"
# ============================================================================
OUT2="$("$LIST_OWN" "$PROJECT_DIR" | sort)"
[ "$OUT2" = "$EXPECTED" ] || red "list-own-worktrees.sh mismatch:
got:
$OUT2
want:
$EXPECTED"
green "list-own-worktrees.sh excludes other's colliding wt-issue-999"

# ============================================================================
heading "Test 3: reap-orphan-worktrees.sh --dry-run never judges other's worktrees"
# ============================================================================
# reap-orphan-worktrees.sh still globs the shared parent (it needs to, to
# find worktrees whose git registration is itself dangling — see its
# issue #357 comment), but must verify ownership before judging a
# candidate any further: other's wt-issue-999 may be NAMED in a transparent
# "registered to a different repo → skip" line, but must never be decided
# as a reap candidate, and must never count toward "found" (which reflects
# only proj's own worktrees).
REAP_LOG="$TEST_DIR/reap.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" \
    "$REAP_ORPHAN" --project "$PROJECT_DIR" --dry-run --yes --min-age-days 0) > "$REAP_LOG" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || { cat "$REAP_LOG" >&2; red "reap-orphan-worktrees.sh --dry-run exited $RC"; }
grep -qE 'wt-issue-999.*(reap|clean|dangling)' "$REAP_LOG" && { cat "$REAP_LOG" >&2; red "reap-orphan-worktrees.sh judged other's wt-issue-999 as a real worktree"; }
if grep -q 'wt-issue-999' "$REAP_LOG"; then
    grep -q 'wt-issue-999.*registered to a different repo' "$REAP_LOG" \
        || { cat "$REAP_LOG" >&2; red "wt-issue-999 mentioned but not via the expected ownership-skip line"; }
fi
grep -qE 'wt-issue-1\b' "$REAP_LOG" || { cat "$REAP_LOG" >&2; red "reap-orphan-worktrees.sh did not scan its own wt-issue-1"; }
grep -qE 'wt-issue-2\b' "$REAP_LOG" || { cat "$REAP_LOG" >&2; red "reap-orphan-worktrees.sh did not scan its own wt-issue-2"; }
grep -qE '\(2 skipped of 2 scanned\.?\)' "$REAP_LOG" || { cat "$REAP_LOG" >&2; red "expected 'found' count to be proj's own 2 worktrees only, other's 999 not counted"; }
green "reap-orphan-worktrees.sh --dry-run never judges other's wt-issue-999 as a real candidate; found-count excludes it"

# ============================================================================
heading "Test 4: kill-finished-workers.sh dry paths never touch other's worktrees"
# ============================================================================
# proj's own tmux session has a window for issue 1 only — no window (and no
# worktree) for issue 999 exists under proj's own git registration. The
# script iterates LIVE tmux windows in $SESSION_NAME (llm-proj), never a
# directory glob, so other's colliding wt-issue-999 is structurally
# unreachable regardless of what happens to be on disk beside it.
SESSION="llm-proj"
"$SHIM_DIR/tmux" new-session -d -s "$SESSION" -n iss-1
"$SHIM_DIR/tmux" list-windows -t "$SESSION" -F '#W' | grep -qx 'iss-1' \
    || red "fixture: tmux session/window did not come up on private socket"

KFW_LOG="$TEST_DIR/kfw.log"
set +e
(cd "$PROJECT_DIR" && PATH="$SHIM_DIR:$PATH" \
    "$KILL_FINISHED" --pr-finalized --idle-min 0 --yes) > "$KFW_LOG" 2>&1
RC=$?
set -e
[ "$RC" -eq 0 ] || { cat "$KFW_LOG" >&2; red "kill-finished-workers.sh exited $RC"; }
grep -q '999' "$KFW_LOG" && { cat "$KFW_LOG" >&2; red "kill-finished-workers.sh referenced other's issue 999"; }
[ -d "$TEST_DIR/main/wt-issue-999" ] || red "other's wt-issue-999 worktree was removed — cross-project damage!"
green "kill-finished-workers.sh never references other's colliding wt-issue-999; its worktree survives untouched"

# ============================================================================
heading "Test 5: dangling-registration worktrees — own recovered, foreign still excluded"
# ============================================================================
# A self-review on this issue's own fix caught a regression: routing
# sweep-swarm-outcomes.sh/swarm-scoreboard.sh through a `git worktree
# list`-only listing silently stopped them seeing a worktree whose git
# registration went dangling (issue #225 — the main repo's
# .git/worktrees/<name> admin dir gone while the directory survives; `git
# worktree list` no longer lists it at all). swarm_own_worktree_dirs() now
# recovers a dangling worktree via its own .git file's gitdir: target
# (same technique reap-orphan-worktrees.sh's reap_dangling() already
# relies on) — but ONLY when that target resolves into THIS project's own
# admin dir; a same-numbered foreign dangling worktree must still be
# excluded, or issue #357's original bug would just reappear via this
# fallback path.
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-3 "$TEST_DIR/main/wt-issue-3" master
rm -rf "$PROJECT_DIR/.git/worktrees/wt-issue-3"
git -C "$OTHER_DIR" worktree add -q -b fix/issue-998 "$TEST_DIR/main/wt-issue-998" master
rm -rf "$OTHER_DIR/.git/worktrees/wt-issue-998"

OUT5="$("$LIST_OWN" "$PROJECT_DIR" | sort)"
EXPECTED5="$(printf '%s\n%s\n%s' "$TEST_DIR/main/wt-issue-1" "$TEST_DIR/main/wt-issue-2" "$TEST_DIR/main/wt-issue-3")"
[ "$OUT5" = "$EXPECTED5" ] || red "list-own-worktrees.sh with a dangling own worktree present mismatch:
got:
$OUT5
want:
$EXPECTED5"
green "dangling own wt-issue-3 recovered; dangling foreign wt-issue-998 (and healthy foreign 999) still excluded"

echo
green "All own-worktree scoping tests passed (issue #357)."
