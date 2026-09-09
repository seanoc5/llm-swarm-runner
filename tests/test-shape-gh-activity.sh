#!/usr/bin/env bash
#
# test-shape-gh-activity.sh — coordinator-watch.sh's out-of-band GitHub
# activity poll (issue #392).
#
# The behavior under test: a PR merged or an issue closed by the OPERATOR
# (typically in the web UI) produces no worker outcome file, so nothing in
# the existing wake channel ever tells the coordinator. It parks forever on a
# decision that was already made — observed on fand-app 2026-09-09, waiting
# on "#1070/#1064 merge decision" 35 minutes after both were resolved.
#
# gh_activity_pass is extracted with sed (never hand-copied — a rename or a
# contract change must fail here, not drift), and its collaborators
# (log_event, has_live_window, maybe_auto_compact) are shimmed so the
# assertions are about this function's own logic: first-run silence,
# dedup, live-window suppression, debounce, and the wake itself.
#
# `gh` is stubbed on PATH; no network, no GitHub auth, no tmux server.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -x "$WATCH" ] || red "coordinator-watch.sh not executable: $WATCH"

TEST_DIR=$(mktemp -d -t shape-ghact-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ───────────────────────────── stub gh on PATH ──────────────────────────────
# Serves whatever the current fixture files say. `gh pr list` and
# `gh issue list` are distinguished by their first two args.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
    "pr list")    cat "$TEST_DIR/fixture-prs.txt"    2>/dev/null || true ;;
    "issue list") cat "$TEST_DIR/fixture-issues.txt" 2>/dev/null || true ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"

# ──────────────────────── extract the function under test ───────────────────
body="$(sed -n '/^gh_activity_pass() {/,/^}/p' "$WATCH")"
[ -n "$body" ] || red "could not extract 'gh_activity_pass' from $WATCH — renamed?"
eval "$body"

# ─────────────────────────────── collaborators ──────────────────────────────
PROJECT_DIR="$TEST_DIR/project"
mkdir -p "$PROJECT_DIR/.swarm"
LLM_START="$TEST_DIR/bin/fake-llm-start"   # never executed: DRY_RUN=1
DRY_RUN=1
DEBOUNCE_SECS=30
LAST_GH_ACTIVITY_WAKE=0
EVENTS="$TEST_DIR/events.txt"; : > "$EVENTS"
LIVE_WINDOWS=""

log_event()          { echo "$1 ${2:-}" >> "$EVENTS"; }
maybe_auto_compact() { :; }
has_live_window()    { case " $LIVE_WINDOWS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

STATE="$PROJECT_DIR/.swarm/gh-activity.state"
run_pass() { gh_activity_pass > "$TEST_DIR/out.txt" 2>&1; }
woke()     { grep -q '\[DRY\] would:' "$TEST_DIR/out.txt"; }

heading "Test 1: first pass records state and does NOT wake"
printf 'pr:900\tOld thing merged before the watcher started\n' > "$TEST_DIR/fixture-prs.txt"
printf 'issue:901\tOld issue closed earlier today\n'           > "$TEST_DIR/fixture-issues.txt"
run_pass
[ -f "$STATE" ] || red "expected state file at $STATE"
woke && red "first pass must not wake — a fresh watcher would announce all of today's history as news"
grep -q 'watch.gh_activity reason=initialized' "$EVENTS" \
    || red "expected watch.gh_activity reason=initialized; got: $(cat "$EVENTS")"
grep -qxF 'pr:900' "$STATE"    || red "pre-existing PR not recorded in state"
grep -qxF 'issue:901' "$STATE" || red "pre-existing issue not recorded in state"
green "first pass initializes silently"

heading "Test 2: a newly merged PR wakes the coordinator"
: > "$EVENTS"
printf 'pr:900\tOld thing\npr:1070\tfix(security): the thing the operator merged in the web UI\n' \
    > "$TEST_DIR/fixture-prs.txt"
run_pass
woke || red "expected a wake for pr:1070; output was: $(cat "$TEST_DIR/out.txt")"
grep -q 'coord.wake trigger=gh_activity' "$EVENTS" \
    || red "expected coord.wake trigger=gh_activity; got: $(cat "$EVENTS")"
grep -q 'watch.gh_activity reason=terminal_detected' "$EVENTS" \
    || red "expected terminal_detected event; got: $(cat "$EVENTS")"
grep -q '1070' "$TEST_DIR/out.txt" || red "wake prompt should name the item that changed"
green "new merged PR → wake naming it"

heading "Test 3: the same PR on the next pass does NOT wake again"
: > "$EVENTS"; LAST_GH_ACTIVITY_WAKE=0
run_pass
woke && red "dedup failed — already-reported pr:1070 woke the coordinator twice"
green "already-reported item stays quiet"

heading "Test 4: item owned by a LIVE worker window is recorded, not announced"
: > "$EVENTS"; LAST_GH_ACTIVITY_WAKE=0
LIVE_WINDOWS="1066"
printf 'pr:900\tOld\npr:1070\tAlready seen\npr:1066\tstill has a live iss-1066 window\n' \
    > "$TEST_DIR/fixture-prs.txt"
run_pass
woke && red "a PR whose worker window is still live must not wake — the outcome channel owns it"
grep -qxF 'pr:1066' "$STATE" || red "live-window item should still be recorded so it never re-fires later"
green "live-window item suppressed but recorded"

heading "Test 5: debounce suppresses a second wake inside the window"
: > "$EVENTS"
LIVE_WINDOWS=""
LAST_GH_ACTIVITY_WAKE=$(date +%s)     # pretend we just woke
printf 'pr:900\tOld\npr:1070\tSeen\npr:1066\tSeen\npr:1099\tbrand new merge\n' \
    > "$TEST_DIR/fixture-prs.txt"
run_pass
woke && red "expected debounce to suppress the wake"
grep -q 'coord.wake.skip .*trigger=gh_activity' "$EVENTS" \
    || red "expected coord.wake.skip with trigger=gh_activity; got: $(cat "$EVENTS")"
green "debounce honored"

heading "Test 6: gh failure is survivable (poll skipped, watcher lives)"
: > "$EVENTS"; LAST_GH_ACTIVITY_WAKE=0
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TEST_DIR/bin/gh"
run_pass || red "gh_activity_pass must not propagate a gh failure to the caller"
grep -q 'gh_activity.error' "$EVENTS" \
    || red "expected gh_activity.error to be logged; got: $(cat "$EVENTS")"
woke && red "must not wake when the gh query failed"
green "gh failure logged, no wake, non-fatal"

printf '\n\033[1;32mAll checks passed.\033[0m\n'
