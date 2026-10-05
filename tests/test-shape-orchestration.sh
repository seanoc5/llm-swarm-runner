#!/usr/bin/env bash
#
# test-shape-orchestration.sh — Non-LLM shape tests for the 3 orchestration
# helpers that aren't covered elsewhere:
#
#   - provision-worker.sh    (creates worktree, queue, brief, tmux window)
#   - coordinator-watch.sh   (wakes coordinator on done/*.json events)
#   - sandbox-worktrees.sh   (lists worktrees; sanity-checks args)
#
# Stubs `gh` and `tmux` via PATH override so tests don't require GitHub
# auth or a live tmux server. Coordinator-watch runs in DRY_RUN=1 + ONCE=1
# so it doesn't actually invoke llm-start.sh.
set -euo pipefail

# These assertions exercise the legacy flat layout. Do not inherit an
# operator's project-grouped swarm setting from the calling shell.
export SWARM_WORKTREE_GROUPING=flat

# Freeze "now" for provision-worker.sh's TASK_ID base so the Test 3
# collision-suffix assertion doesn't depend on two real invocations landing
# within the same wall-clock second (was flaky — see #192). All provision
# calls below share this frozen epoch, so re-dispatching the same issue
# deterministically collides on BASE_ID and exercises the -2 suffix path.
export PROVISION_NOW_EPOCH="$(date +%s)"

# This suite's stubbed tmux/docker (below) never simulate a genuinely live
# pane or a running container — they only log calls and replay canned
# `docker ps` output. Issue #493's post-spawn health check would therefore
# treat every successful provision call here as a failed spawn; it's
# exercised for real against a real tmux server in
# test-shape-provision-stale-container.sh instead.
export PROVISION_SPAWN_CHECK_SECS=0

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
LIST="$SCRIPT_DIR/../scripts/sandbox-worktrees.sh"
SWEEP="$SCRIPT_DIR/../scripts/sweep-swarm-outcomes.sh"
for s in "$PROVISION" "$WATCH" "$LIST" "$SWEEP"; do
    [ -x "$s" ] || red "not executable: $s"
done

TEST_DIR=$(mktemp -d -t shape-orch-XXXXXX)
# Host admission (provision-worker.sh, 2026-09-29) reads the real host's
# load and memory and staggers spawns; under stubs that is noise, so pin
# the state dir into the test tree and switch the three checks off.
export HOST_STATE_DIR="$TEST_DIR/host-state" HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0
cleanup() {
    [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ────────────────────────── Stub gh + tmux on PATH ──────────────────────────

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub: only handles `gh issue view <N>` — emits a fake body.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    echo "FAKE-GH issue #${3:-?}: synthetic body for shape test"
    exit 0
fi
echo "stub-gh: unhandled args: $*" >&2
exit 1
EOF
cat > "$TEST_DIR/bin/tmux" <<EOF
#!/usr/bin/env bash
# Stub: provision-worker.sh uses has-session + list-windows + new-window
# (+ list-panes/kill-window for the issue #493 dead-pane reclaim path).
# Pretend the session always exists, no windows yet, log new-window/
# kill-window calls. list-windows/capture-pane also serve
# bg_violation_sweep_pass's Test 15 fixtures below (\$TEST_DIR/
# tmux-windows.txt, tmux-pane-<win>.txt) — both are absent for every
# earlier test, so those two cases fall back to their original no-output
# behavior until Test 15 populates them. list-panes is controlled the same
# way via \$TEST_DIR/tmux-pane-dead-<win>.txt (absent/"0" = alive, "1" =
# dead), used only by the Test 3e/3f dead-pane-reclaim cases below.
TMUX_LOG="$TEST_DIR/tmux.log"
case "\${1:-}" in
    has-session)   exit 0 ;;
    list-windows)  [ -f "$TEST_DIR/tmux-windows.txt" ] && cat "$TEST_DIR/tmux-windows.txt"; exit 0 ;;
    capture-pane)
        win=""; prev=""
        for a in "\$@"; do [ "\$prev" = "-t" ] && win="\${a##*:}"; prev="\$a"; done
        [ -f "$TEST_DIR/tmux-pane-\$win.txt" ] && cat "$TEST_DIR/tmux-pane-\$win.txt"
        exit 0 ;;
    list-panes)
        win=""; prev=""
        for a in "\$@"; do [ "\$prev" = "-t" ] && win="\${a##*:}"; prev="\$a"; done
        win="\${win##*:}"
        [ -f "$TEST_DIR/tmux-pane-dead-\$win.txt" ] && cat "$TEST_DIR/tmux-pane-dead-\$win.txt"
        exit 0 ;;
    new-window)    echo "\$*" >> "\$TMUX_LOG" ;;
    kill-window)   echo "\$*" >> "\$TMUX_LOG" ;;
    *)             echo "stub-tmux: ignored: \$*" >> "\$TMUX_LOG" ;;
esac
exit 0
EOF
cat > "$TEST_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
# Stub: provision-worker.sh's HOST_MAX_WORKERS check calls
#   docker ps --filter 'name=^swarm-' --format '{{.Names}}'
# Container count is controlled via $TEST_DIR/docker-containers.txt (one
# name per line; absent = 0, matching a host with no swarm containers).
# Tests toggle its contents to simulate the host at/under cap (issue #464).
if [ "\${1:-}" = "ps" ]; then
    cat "$TEST_DIR/docker-containers.txt" 2>/dev/null
fi
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/tmux" "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH"

# ──────────────────────── Fixture: repo with worktrees ────────────────────────

heading "Setup: fixture git repo"
cd "$TEST_DIR"
mkdir myproject && cd myproject
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"
git clone -q --bare . "$TEST_DIR/origin.git"
git remote add origin "$TEST_DIR/origin.git"
git fetch -q origin
PROJECT_DIR="$TEST_DIR/myproject"
green "fixture ready at $PROJECT_DIR"

# ────────────────────────── provision-worker.sh ──────────────────────────

heading "Test 1: provision-worker.sh creates worktree + branch + brief"
cd "$PROJECT_DIR"
WORKER_CMD=codex WORKER_HEADLESS=1 WORKER_MODEL=test-codex WORKER_SELF_REVIEW=0 \
SELF_REVIEW_CMD=codex SELF_REVIEW_MODEL=test-sol \
    "$PROVISION" 99 > "$TEST_DIR/prov-1.log" 2>&1 || red "provision-worker exit non-zero: $(cat $TEST_DIR/prov-1.log)"
WT="$TEST_DIR/wt-issue-99"
[ -d "$WT" ] || red "worktree not created at $WT"
git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/fix/issue-99 \
    || red "branch fix/issue-99 not created"
[ -d "$WT/.swarm/tasks/inbox" ] || red "queue inbox dir not created"
[ -d "$WT/.swarm/tasks/status" ] || red "queue status dir not created (see #129: worker status-file hand-off)"
[ -d "$WT/.swarm/tasks/outbox" ] || red "queue outbox dir not created (see #129: worker→coordinator outbox)"
brief=$(ls "$WT"/.swarm/tasks/inbox/*.md | head -1)
[ -n "$brief" ] || red "no brief file in inbox"
grep -q "FAKE-GH issue #99" "$brief" || red "stub gh body not embedded in brief"
grep -qE 'new-window .* iss-99' "$TEST_DIR/tmux.log" \
    || red "expected tmux new-window for iss-99; got: $(cat $TEST_DIR/tmux.log)"
grep -q 'WORKER_CMD=codex .*WORKER_MODEL=test-codex .*WORKER_HEADLESS=1 .*WORKER_SELF_REVIEW=0' "$TEST_DIR/tmux.log" \
    || red "expected worker backend env in tmux spawn; got: $(cat "$TEST_DIR/tmux.log")"
grep -q 'SELF_REVIEW_CMD=codex SELF_REVIEW_MODEL=test-sol' "$TEST_DIR/tmux.log" \
    || red "expected review model in tmux spawn; got: $(cat "$TEST_DIR/tmux.log")"
green "worktree, branch, queue (incl. status/), brief, tmux window, and worker backend env all created"

heading "Test 2: provision-worker.sh embeds .swarm-policy.md when present"
cd "$PROJECT_DIR"
echo "RULE: only touch src/" > .swarm-policy.md
git rm -q --cached . 2>/dev/null || true   # keep policy untracked, doesn't matter
"$PROVISION" 100 > "$TEST_DIR/prov-2.log" 2>&1 || red "provision-worker #100 exit non-zero"
WT100="$TEST_DIR/wt-issue-100"
brief100=$(ls "$WT100"/.swarm/tasks/inbox/*.md | head -1)
grep -q "Project Guardrails (MUST OBEY)" "$brief100" \
    || red "policy header missing from brief"
grep -q "RULE: only touch src/" "$brief100" \
    || red "policy body missing from brief"
green "embeds .swarm-policy.md under 'Project Guardrails' heading"

heading "Test 3: provision-worker.sh idempotent re-run reuses worktree"
cd "$PROJECT_DIR"
# Rapid re-dispatch (within the same second) — collision counter should
# kick in and append -2 to TASK_ID. No sleep needed.
"$PROVISION" 99 > "$TEST_DIR/prov-3.log" 2>&1 || red "provision-worker re-run exit non-zero"
grep -q "worktree already exists — reusing" "$TEST_DIR/prov-3.log" \
    || red "expected 'worktree already exists' message"
# A second brief should now exist for issue 99
count=$(ls "$WT"/.swarm/tasks/inbox/*.md | wc -l)
[ "$count" -ge 2 ] || red "expected ≥2 briefs in inbox after re-run, got $count"
# Verify at least one of the briefs has the -2 collision-counter suffix
collision_brief=$(ls "$WT"/.swarm/tasks/inbox/*-99-2.md 2>/dev/null | head -1 || true)
[ -n "$collision_brief" ] \
    || red "expected a *-99-2.md collision-suffix brief; got: $(ls $WT/.swarm/tasks/inbox/)"
green "re-run reuses worktree, queues follow-up with -2 collision suffix"

heading "Test 3b: provision-worker.sh reuses a stale branch with no unique commits (and fast-forwards it)"
cd "$PROJECT_DIR"
# Simulate branch sweep leftover: fix/issue-101 exists but was never (or no
# longer is) attached to a worktree — e.g. the worktree dir was removed by
# hand, or a grouping-mode change orphaned it (#174). Advance master
# afterward so the branch is genuinely stale (0 ahead, N behind) — this
# exercises the fast-forward-on-reuse path, not just the identical-tip case.
git branch fix/issue-101
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "master moves on without issue-101"
git push -q origin master
git fetch -q origin
old_tip="$(git rev-parse fix/issue-101)"
new_default="$(git rev-parse origin/master)"
[ "$old_tip" != "$new_default" ] || red "fixture bug: fix/issue-101 should be behind origin/master"
"$PROVISION" 101 > "$TEST_DIR/prov-3b.log" 2>&1 || red "provision-worker exit non-zero for stale-but-clean branch: $(cat "$TEST_DIR/prov-3b.log")"
grep -q "reused stale branch fix/issue-101" "$TEST_DIR/prov-3b.log" \
    || red "expected 'reused stale branch' message; got: $(cat "$TEST_DIR/prov-3b.log")"
[ -d "$TEST_DIR/wt-issue-101" ] || red "worktree not created for reused stale branch"
reused_tip="$(git rev-parse fix/issue-101)"
[ "$reused_tip" = "$new_default" ] \
    || red "expected fix/issue-101 fast-forwarded to $new_default, got $reused_tip"
green "stale branch with no unique commits is reused (no -b) and fast-forwarded to the latest default ref"

heading "Test 3c: provision-worker.sh refuses a stale branch with unique commits (never exit 0)"
cd "$PROJECT_DIR"
# This time the stale branch has real work on it — refuse to silently
# discard or reuse it. Must exit non-zero and must NOT spawn a window or
# worktree (the original #174 bug: exited 0, no worktree, no window).
git checkout -q -b fix/issue-102
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unmerged work on stale branch"
git checkout -q master
set +e
"$PROVISION" 102 > "$TEST_DIR/prov-3c.log" 2>&1
prov_exit=$?
set -e
[ "$prov_exit" -ne 0 ] || red "provision-worker should exit non-zero for a stale branch with unique commits, got 0: $(cat "$TEST_DIR/prov-3c.log")"
grep -q "already exists with 1 commit(s) not on" "$TEST_DIR/prov-3c.log" \
    || red "expected diverged-branch error message; got: $(cat "$TEST_DIR/prov-3c.log")"
[ -d "$TEST_DIR/wt-issue-102" ] && red "worktree should NOT have been created for the refused branch"
grep -qE 'new-window .* iss-102' "$TEST_DIR/tmux.log" \
    && red "tmux window should NOT have been spawned for the refused branch"
green "stale branch with unique commits refuses with nonzero exit, no worktree, no tmux window"

heading "Test 3d: provision-worker.sh refused by a cap leaves no brief; retry queues exactly one (#464)"
cd "$PROJECT_DIR"
# Simulate the host already at HOST_MAX_WORKERS=1 (one fake swarm-*
# container running) so the new-capacity path in provision-worker.sh
# refuses with exit 3 — same code path as the fand-etl 2026-09-25 incident
# (#995/#996/#997 refused by host_max_workers each left a stray brief).
echo "swarm-other-iss-1" > "$TEST_DIR/docker-containers.txt"
set +e
HOST_MAX_WORKERS=1 "$PROVISION" 103 > "$TEST_DIR/prov-3d-refused.log" 2>&1
prov_exit=$?
set -e
[ "$prov_exit" -eq 3 ] \
    || red "expected exit 3 on cap refusal, got $prov_exit: $(cat "$TEST_DIR/prov-3d-refused.log")"
grep -q "HOST_MAX_WORKERS cap reached" "$TEST_DIR/prov-3d-refused.log" \
    || red "expected HOST_MAX_WORKERS refusal message; got: $(cat "$TEST_DIR/prov-3d-refused.log")"
WT103="$TEST_DIR/wt-issue-103"
# Decision (issue #464): the worktree from step 1 is harmless and left in
# place even on refusal — a retry reuses it instead of recreating it.
[ -d "$WT103" ] || red "expected worktree to still be created despite the cap refusal (see #464 decision)"
# The core fix: a cap refusal must leave NO brief behind.
briefs_after_refusal=$(find "$WT103/.swarm/tasks/inbox" -maxdepth 1 -name '*.md' | wc -l)
[ "$briefs_after_refusal" -eq 0 ] \
    || red "cap refusal should leave zero briefs in inbox/, found $briefs_after_refusal"
grep -qE 'new-window .* iss-103' "$TEST_DIR/tmux.log" \
    && red "tmux window should NOT have been spawned for the cap-refused issue"

# Free up capacity (host now has 0 running swarm-* containers) and retry —
# this must queue exactly ONE brief, not a duplicate of a phantom first one.
# Earlier admitted spawns in this file left pending-spawn markers that the
# docker stub never resolves (no container ever appears); under a cap of 1
# they count as in flight, so clear them: "capacity freed" means both.
: > "$TEST_DIR/docker-containers.txt"
rm -f "$HOST_STATE_DIR"/pending-*
HOST_MAX_WORKERS=1 "$PROVISION" 103 > "$TEST_DIR/prov-3d-retry.log" 2>&1 \
    || red "retry after freeing capacity should succeed: $(cat "$TEST_DIR/prov-3d-retry.log")"
briefs_after_retry=$(find "$WT103/.swarm/tasks/inbox" -maxdepth 1 -name '*.md' | wc -l)
[ "$briefs_after_retry" -eq 1 ] \
    || red "expected exactly 1 brief after refused-then-successful retry, got $briefs_after_retry"
grep -qE 'new-window .* iss-103' "$TEST_DIR/tmux.log" \
    || red "expected tmux new-window for iss-103 after capacity freed; got: $(cat "$TEST_DIR/tmux.log")"
rm -f "$TEST_DIR/docker-containers.txt"
green "cap refusal (exit 3) leaves no brief and no tmux window; worktree persists; retry queues exactly 1 brief"

# Remove this test's worktree so it doesn't inflate Test 6's worktree count
# below (which asserts an exact count of 4: main + wt-issue-99/100/101).
git -C "$PROJECT_DIR" worktree remove --force "$WT103" 2>/dev/null || rm -rf "$WT103"

heading "Test 3e: provision-worker.sh reclaims a listed-but-dead-paned window instead of queuing a follow-up (issue #493)"
cd "$PROJECT_DIR"
# Simulate re-provisioning issue #204 while a crashed prior spawn's window
# is still listed (remain-on-exit=failed) with a dead pane — the exact
# fand-etl shape: nothing live would ever pick up the follow-up brief this
# call is about to queue if it took the "already exists" path instead.
echo "iss-204" > "$TEST_DIR/tmux-windows.txt"
echo "1" > "$TEST_DIR/tmux-pane-dead-iss-204.txt"
: > "$TEST_DIR/tmux.log"
"$PROVISION" 204 > "$TEST_DIR/prov-3e.log" 2>&1 \
    || red "provision-worker exit non-zero reclaiming a dead-paned window: $(cat "$TEST_DIR/prov-3e.log")"
grep -q "window iss-204 exists but its pane is dead — reclaiming" "$TEST_DIR/prov-3e.log" \
    || red "expected the reclaim message; got: $(cat "$TEST_DIR/prov-3e.log")"
grep -qE 'kill-window .*iss-204' "$TEST_DIR/tmux.log" \
    || red "expected the dead window to be killed; tmux.log: $(cat "$TEST_DIR/tmux.log")"
grep -qE 'new-window .* iss-204' "$TEST_DIR/tmux.log" \
    || red "expected a fresh tmux new-window for iss-204 after reclaim; tmux.log: $(cat "$TEST_DIR/tmux.log")"
WT204="$TEST_DIR/wt-issue-204"
briefs204=$(find "$WT204/.swarm/tasks/inbox" -maxdepth 1 -name '*.md' | wc -l)
[ "$briefs204" -eq 1 ] || red "expected exactly 1 brief after the reclaim+respawn, got $briefs204"
green "a listed-but-dead-paned window is killed and reclaimed; provisioning respawns fresh instead of stranding a follow-up brief"
rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-dead-iss-204.txt"
git -C "$PROJECT_DIR" worktree remove --force "$WT204" 2>/dev/null || rm -rf "$WT204"

heading "Test 3f: provision-worker.sh leaves a genuinely alive window alone (control for Test 3e)"
cd "$PROJECT_DIR"
# Same shape as Test 3e, but the pane is alive — must take the existing
# "listener will pick up the new task" path, not kill a live worker.
echo "iss-205" > "$TEST_DIR/tmux-windows.txt"
echo "0" > "$TEST_DIR/tmux-pane-dead-iss-205.txt"
: > "$TEST_DIR/tmux.log"
"$PROVISION" 205 > "$TEST_DIR/prov-3f.log" 2>&1 \
    || red "provision-worker exit non-zero queuing a follow-up onto a live window: $(cat "$TEST_DIR/prov-3f.log")"
grep -q "already exists — listener will pick up the new task" "$TEST_DIR/prov-3f.log" \
    || red "expected the existing-window requeue message; got: $(cat "$TEST_DIR/prov-3f.log")"
grep -qE 'kill-window .*iss-205' "$TEST_DIR/tmux.log" \
    && red "a genuinely alive window must never be killed; tmux.log: $(cat "$TEST_DIR/tmux.log")"
grep -qE 'new-window .* iss-205' "$TEST_DIR/tmux.log" \
    && red "a genuinely alive window must not get a second tmux new-window; tmux.log: $(cat "$TEST_DIR/tmux.log")"
green "a genuinely alive window is left running; the follow-up is queued for its own listener to pick up, not reclaimed"
WT205="$TEST_DIR/wt-issue-205"
rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-dead-iss-205.txt"
git -C "$PROJECT_DIR" worktree remove --force "$WT205" 2>/dev/null || rm -rf "$WT205"

heading "Test 3g: a dead-pane reclaim salvages stale inbox/processing briefs instead of letting the fresh listener re-run them (self-review, 12th pass)"
cd "$PROJECT_DIR"
# First, an ordinary spawn creates the worktree and queues its one brief —
# nothing claims it (no real listener runs in this stub), the same shape as
# a worker that crashed before ever picking up its first task.
"$PROVISION" 206 > "$TEST_DIR/prov-3g-first.log" 2>&1 \
    || red "initial spawn for issue 206 should succeed: $(cat "$TEST_DIR/prov-3g-first.log")"
WT206="$TEST_DIR/wt-issue-206"
# A second brief, abandoned mid-task, would sit in processing/ instead —
# simulate that too (nothing in this stub ever claims a brief for real).
mkdir -p "$WT206/.swarm/tasks/processing"
echo "claimed but abandoned when the worker crashed" > "$WT206/.swarm/tasks/processing/stale-claimed.md"
# Now the window dies and a follow-up is dispatched — the fand-etl
# re-provision shape: the operator re-sends the same task.
echo "iss-206" > "$TEST_DIR/tmux-windows.txt"
echo "1" > "$TEST_DIR/tmux-pane-dead-iss-206.txt"
: > "$TEST_DIR/tmux.log"
"$PROVISION" 206 > "$TEST_DIR/prov-3g-reclaim.log" 2>&1 \
    || red "reclaim+respawn for issue 206 should succeed: $(cat "$TEST_DIR/prov-3g-reclaim.log")"
briefs206=$(find "$WT206/.swarm/tasks/inbox" -maxdepth 1 -name '*.md' | wc -l)
[ "$briefs206" -eq 1 ] \
    || red "expected exactly 1 brief in inbox/ after the reclaim (the fresh one, stale one salvaged out), got $briefs206: $(ls "$WT206/.swarm/tasks/inbox")"
processing206=$(find "$WT206/.swarm/tasks/processing" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
[ "$processing206" -eq 0 ] \
    || red "expected processing/ emptied by the salvage, got $processing206 file(s) left behind"
SALVAGE206="$PROJECT_DIR/.swarm/salvaged/iss-206"
salvaged206=$(find "$SALVAGE206/inbox" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
[ "$salvaged206" -ge 1 ] \
    || red "expected the stale unclaimed brief salvaged to $SALVAGE206/inbox/, found: $(ls "$SALVAGE206/inbox" 2>&1)"
[ -f "$SALVAGE206/processing/stale-claimed.md" ] \
    || red "expected the stale claimed brief salvaged to $SALVAGE206/processing/stale-claimed.md"
grep -q 'worker.dead_pane_reclaimed.*issue=206.*stale_briefs_salvaged=2' "$PROJECT_DIR/.swarm/events.log" \
    || red "expected stale_briefs_salvaged=2 in the reclaim event, got: $(grep 'issue=206' "$PROJECT_DIR/.swarm/events.log")"
green "a dead-pane reclaim salvages both the unclaimed inbox/ brief and the abandoned processing/ brief instead of letting a fresh listener silently re-run them"
rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-dead-iss-206.txt"
git -C "$PROJECT_DIR" worktree remove --force "$WT206" 2>/dev/null || rm -rf "$WT206"

# ============================================================================
heading "Test 3h: a cap refusal right after a dead-pane reclaim still surfaces the salvaged briefs (self-review, 14th pass)"
# ============================================================================
# The reclaim-and-salvage above runs BEFORE the cap/admission checks below
# it in provision-worker.sh. If one of those then refuses this same
# re-provision attempt, the issue ends up with no window and no queued
# brief -- the salvaged copy is the only trace, and the refusal's own
# stderr said nothing about it until the 14th-pass EXIT trap fix.
cd "$PROJECT_DIR"
"$PROVISION" 207 > "$TEST_DIR/prov-3h-first.log" 2>&1 \
    || red "initial spawn for issue 207 should succeed: $(cat "$TEST_DIR/prov-3h-first.log")"
WT207="$TEST_DIR/wt-issue-207"
echo "iss-207" > "$TEST_DIR/tmux-windows.txt"
echo "1" > "$TEST_DIR/tmux-pane-dead-iss-207.txt"
: > "$TEST_DIR/tmux.log"
# Saturate the host-wide container cap so host_admission_check refuses
# (exit 3) right after the reclaim's salvage runs — same mechanism as
# Test 3d, just landing after a reclaim instead of a plain first spawn.
echo "swarm-other-iss-1" > "$TEST_DIR/docker-containers.txt"
set +e
HOST_MAX_WORKERS=1 "$PROVISION" 207 > "$TEST_DIR/prov-3h-refused.log" 2>&1
prov207_exit=$?
set -e
[ "$prov207_exit" -eq 3 ] \
    || red "expected exit 3 (cap refusal) after the reclaim, got $prov207_exit: $(cat "$TEST_DIR/prov-3h-refused.log")"
grep -q "Note: issue #207 still has 1 brief(s) salvaged to .*salvaged/iss-207/" "$TEST_DIR/prov-3h-refused.log" \
    || red "expected the refusal to mention the salvaged brief; got: $(cat "$TEST_DIR/prov-3h-refused.log")"
green "a cap refusal right after a dead-pane reclaim still tells the operator where the salvaged brief went"
rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-dead-iss-207.txt" "$TEST_DIR/docker-containers.txt"
rm -f "$HOST_STATE_DIR"/pending-*
git -C "$PROJECT_DIR" worktree remove --force "$WT207" 2>/dev/null || rm -rf "$WT207"

# ────────────────────────── coordinator-watch.sh ──────────────────────────

heading "Test 4: coordinator-watch.sh detects new outcome JSON (DRY_RUN, ONCE)"
# coordinator-watch scans WORKSPACE/wt-issue-*/.swarm/tasks/done/ — i.e.
# sibling worktrees of PROJECT_DIR (matching what provision-worker creates).
# wt-issue-99 already exists from Test 1; ensure the done dir is present.
mkdir -p "$WT/.swarm/tasks/done"

# Use a fake llm-start that we'll never actually invoke (DRY_RUN=1)
FAKE_LLM_START="$TEST_DIR/bin/fake-llm-start.sh"
cat > "$FAKE_LLM_START" <<'EOF'
#!/usr/bin/env bash
echo "FAKE-LLM-START invoked: $*"
EOF
chmod +x "$FAKE_LLM_START"

# Start watch in background. Polling backend is fine — gives us deterministic
# semantics, doesn't depend on inotify-tools.
cd "$PROJECT_DIR"
DRY_RUN=1 ONCE=1 POLL_SECS=1 LLM_START="$FAKE_LLM_START" \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch.log" 2>&1 &
WATCH_PID=$!

# Give the watch time to baseline existing files
sleep 1.5

# Drop a NEW outcome JSON in a sibling worktree (real-world layout)
echo '{"task_id":"t1","outcome":"ok"}' > "$WT/.swarm/tasks/done/t1.ok.json"

# Wait up to 10s for ONCE=1 watch to exit (it should after first wake)
for ((i=0; i<20; i++)); do
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
done
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

grep -q '\[DRY\] would:' "$TEST_DIR/watch.log" \
    || red "expected dry-run log line; full log: $(cat $TEST_DIR/watch.log)"
grep -q "ONCE=1 — exiting after first wake" "$TEST_DIR/watch.log" \
    || red "expected ONCE exit message"
green "polling backend detected new .ok.json, would-wake logged, ONCE=1 exited"

# Clean up the trigger outcome so it doesn't leak into the sweep tests
rm -f "$WT/.swarm/tasks/done/t1.ok.json"

heading "Test 4b: coordinator-watch.sh detects new outbox message (DRY_RUN, ONCE)"
# Same fixture as Test 4, but the trigger is a worker→coordinator message
# file in outbox/ (issue #129) rather than an outcome JSON in done/.
mkdir -p "$WT/.swarm/tasks/outbox"
cd "$PROJECT_DIR"
DRY_RUN=1 ONCE=1 POLL_SECS=1 LLM_START="$FAKE_LLM_START" \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-outbox.log" 2>&1 &
WATCH_PID=$!
sleep 1.5   # let the watch baseline existing files

# Atomic-write convention: temp WITHOUT .md suffix, then mv to the final name.
TMPMSG="$(mktemp -p "$WT/.swarm/tasks/outbox" .tmp.XXXXXX)"
printf -- '---\nkind: fyi\ntask_id: t1\nts: 2026-01-01T00:00:00Z\n---\nshape-test message\n' > "$TMPMSG"
mv "$TMPMSG" "$WT/.swarm/tasks/outbox/20260101T000000Z-shape-test.md"

for ((i=0; i<20; i++)); do
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
done
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

grep -q 'waking coordinator (outbox)' "$TEST_DIR/watch-outbox.log" \
    || red "expected outbox wake line; full log: $(cat $TEST_DIR/watch-outbox.log)"
# issue #430: the doorbell paste itself is now a generic one-line inbox
# nudge (no longer names the outbox path) — the outbox path instead shows
# up in the coord-inbox DRY-RUN write line, which happens unconditionally
# before the doorbell is even considered.
grep -q '\[DRY\] would write coord-inbox entry:.*outbox' "$TEST_DIR/watch-outbox.log" \
    || red "expected dry-run coord-inbox write naming the outbox; full log: $(cat $TEST_DIR/watch-outbox.log)"
grep -q '\[DRY\] would:.*Inbox:' "$TEST_DIR/watch-outbox.log" \
    || red "expected the generic one-line inbox doorbell nudge; full log: $(cat $TEST_DIR/watch-outbox.log)"
grep -q "ONCE=1 — exiting after first wake" "$TEST_DIR/watch-outbox.log" \
    || red "expected ONCE exit message after outbox wake"
green "polling backend detected new outbox *.md, message wake logged, ONCE=1 exited"

# Clean up so later watcher tests don't baseline-then-ignore a stale message
rm -f "$WT/.swarm/tasks/outbox/20260101T000000Z-shape-test.md"

heading "Test 5: coordinator-watch.sh rejects missing project dir"
# realpath bails first under set -e, so we just check non-zero exit + a
# message on stderr (either realpath's or the script's own ERROR).
if "$WATCH" /no/such/dir > "$TEST_DIR/watch-err.log" 2>&1; then
    red "should have failed for missing project dir"
fi
[ -s "$TEST_DIR/watch-err.log" ] || red "expected error output on missing dir"
green "exits non-zero on missing project dir"

# ────────────────────────── sandbox-worktrees.sh ──────────────────────────

heading "Test 6: sandbox-worktrees.sh lists worktrees of a multi-worktree repo"
# We already have 3 extra worktrees (wt-issue-99, wt-issue-100, and
# wt-issue-101 from the stale-branch-reuse fixture in Test 3b) plus the main
# repo, so listing should find 4. wt-issue-102 is intentionally absent — that
# fixture (Test 3c) asserts provision-worker refused to create it.
cd "$PROJECT_DIR"
out=$(env -u TMUX "$LIST" "$PROJECT_DIR" 2>&1) || red "list mode exit non-zero: $out"
grep -q "Found 4 worktree(s)" <<< "$out" || red "expected 4 worktrees; got: $out"
grep -q "myproject" <<< "$out" || red "expected main worktree 'myproject' listed"
grep -q "wt-issue-99" <<< "$out" || red "expected 'wt-issue-99' listed"
green "lists 4 worktrees (main + 3 wt-issue)"

heading "Test 6b: provision-worker.sh propagates SANDBOX_DEP_CACHE from <project>/.swarm/.env to the tmux spawn (#337)"
cd "$PROJECT_DIR"
# Set ONLY in the project .env file, never in this shell's env — #333's
# BLOCK finding was that the whitelist prefix silently dropped it, so
# sandbox.sh only ever saw it when the invoking shell already had it set.
# Reuses issue 99's existing worktree (re-dispatch, like Test 3) so this
# doesn't perturb Test 6's worktree count.
mkdir -p "$PROJECT_DIR/.swarm"
echo "SANDBOX_DEP_CACHE=/fake/dep-cache" > "$PROJECT_DIR/.swarm/.env"
env -u SANDBOX_DEP_CACHE "$PROVISION" 99 > "$TEST_DIR/prov-6b.log" 2>&1 \
    || red "provision-worker exit non-zero: $(cat "$TEST_DIR/prov-6b.log")"
rm -f "$PROJECT_DIR/.swarm/.env"
grep -q 'SANDBOX_DEP_CACHE=/fake/dep-cache' "$TEST_DIR/tmux.log" \
    || red "expected SANDBOX_DEP_CACHE in tmux spawn env; got: $(cat "$TEST_DIR/tmux.log")"
green "SANDBOX_DEP_CACHE set only in .swarm/.env reaches the tmux new-window env"

heading "Test 6c: provision-worker.sh propagates SANDBOX_ALLOW_BACKGROUND_TASKS from <project>/.swarm/.env to the tmux spawn (#298)"
cd "$PROJECT_DIR"
# Same #333 failure mode as Test 6b, applied to the foreground-only opt-out:
# set ONLY in the project .env file, never in this shell's env, so a silently
# dropped whitelist entry can't hide behind an already-exported value.
mkdir -p "$PROJECT_DIR/.swarm"
echo "SANDBOX_ALLOW_BACKGROUND_TASKS=1" > "$PROJECT_DIR/.swarm/.env"
env -u SANDBOX_ALLOW_BACKGROUND_TASKS "$PROVISION" 99 > "$TEST_DIR/prov-6c.log" 2>&1 \
    || red "provision-worker exit non-zero: $(cat "$TEST_DIR/prov-6c.log")"
rm -f "$PROJECT_DIR/.swarm/.env"
grep -q 'SANDBOX_ALLOW_BACKGROUND_TASKS=1' "$TEST_DIR/tmux.log" \
    || red "expected SANDBOX_ALLOW_BACKGROUND_TASKS in tmux spawn env; got: $(cat "$TEST_DIR/tmux.log")"
green "SANDBOX_ALLOW_BACKGROUND_TASKS set only in .swarm/.env reaches the tmux new-window env"

heading "Test 7: sandbox-worktrees.sh rejects non-git directory"
if env -u TMUX "$LIST" /tmp > "$TEST_DIR/list-err.log" 2>&1; then
    red "should have failed for non-git dir"
fi
grep -q "not a git repository" "$TEST_DIR/list-err.log" \
    || red "expected 'not a git repository' error"
green "exits non-zero with 'not a git repository' error"

heading "Test 8: sandbox-worktrees.sh -t outside tmux session is rejected"
if env -u TMUX "$LIST" -t "$PROJECT_DIR" > "$TEST_DIR/list-err.log" 2>&1; then
    red "should have failed for -t without TMUX env"
fi
grep -q "not inside a tmux session" "$TEST_DIR/list-err.log" \
    || red "expected 'not inside a tmux session' error"
green "exits non-zero with 'not inside a tmux session' error"

# ────────────────────────── sweep-swarm-outcomes.sh ──────────────────────────

# Stage outcome JSONs in two of the existing worktrees so the sweep has
# something to find. wt-issue-99 + wt-issue-100 already exist from the
# provision tests above; add a 3rd worker without an outcome to confirm
# the sweep skips empty done/ dirs.
heading "Setup: stage outcome JSONs in 2 worktrees"
mkdir -p "$TEST_DIR/wt-issue-99/.swarm/tasks/done"
mkdir -p "$TEST_DIR/wt-issue-100/.swarm/tasks/done"
echo '{"task_id":"t99","outcome":"ok"}'  > "$TEST_DIR/wt-issue-99/.swarm/tasks/done/t99.ok.json"
echo '{"task_id":"t100","outcome":"err","exit_code":1}' > "$TEST_DIR/wt-issue-100/.swarm/tasks/done/t100.err.json"
green "staged 1 .ok.json + 1 .err.json"

heading "Test 9: sweep with default dry-run hook posts both outcomes"
cd "$PROJECT_DIR"
"$SWEEP" "$PROJECT_DIR" > "$TEST_DIR/sweep-1.log" 2>&1 || red "sweep exit non-zero: $(cat $TEST_DIR/sweep-1.log)"
grep -qE 'Posted: 2  Skipped \(already posted\): 0  Failed: 0' "$TEST_DIR/sweep-1.log" \
    || red "expected 'Posted: 2 Skipped: 0 Failed: 0'; got: $(grep -E 'Posted:' $TEST_DIR/sweep-1.log)"
[ -f "$TEST_DIR/wt-issue-99/.swarm/tasks/done/t99.ok.json.posted" ] \
    || red ".posted marker not written for t99"
[ -f "$TEST_DIR/wt-issue-100/.swarm/tasks/done/t100.err.json.posted" ] \
    || red ".posted marker not written for t100"
grep -q '\[dry-run\] would post:' "$TEST_DIR/sweep-1.log" || red "dry-run hook output missing"
green "default hook posted 2 outcomes; .posted markers written"

heading "Test 10: sweep skips outcomes that already have .posted markers"
"$SWEEP" "$PROJECT_DIR" > "$TEST_DIR/sweep-2.log" 2>&1 || red "sweep re-run exit non-zero"
grep -qE 'Posted: 0  Skipped \(already posted\): 2  Failed: 0' "$TEST_DIR/sweep-2.log" \
    || red "expected 'Posted: 0 Skipped: 2 Failed: 0'; got: $(grep -E 'Posted:' $TEST_DIR/sweep-2.log)"
green "second sweep posts nothing — both outcomes skipped via marker"

heading "Test 11: SWEEP_FORCE=1 re-posts despite existing markers"
SWEEP_FORCE=1 "$SWEEP" "$PROJECT_DIR" > "$TEST_DIR/sweep-3.log" 2>&1 || red "sweep force exit non-zero"
grep -qE 'Posted: 2  Skipped \(already posted\): 0  Failed: 0' "$TEST_DIR/sweep-3.log" \
    || red "expected forced re-post of 2; got: $(grep -E 'Posted:' $TEST_DIR/sweep-3.log)"
green "SWEEP_FORCE=1 re-posts both outcomes despite markers"

heading "Test 12: sweep with custom OUTCOME_HOOK invokes it per outcome"
HOOK="$TEST_DIR/bin/custom-hook.sh"
cat > "$HOOK" <<EOF
#!/usr/bin/env bash
echo "HOOK-CALLED wt=\$1 outcome=\$2" >> "$TEST_DIR/hook-calls.log"
EOF
chmod +x "$HOOK"
SWEEP_FORCE=1 OUTCOME_HOOK="$HOOK" "$SWEEP" "$PROJECT_DIR" > "$TEST_DIR/sweep-4.log" 2>&1 \
    || red "sweep with custom hook exit non-zero"
calls=$(wc -l < "$TEST_DIR/hook-calls.log")
[ "$calls" -eq 2 ] || red "expected hook called 2 times, got $calls"
grep -q 'HOOK-CALLED wt=.*wt-issue-99 outcome=.*t99\.ok\.json' "$TEST_DIR/hook-calls.log" \
    || red "missing expected hook call for t99"
grep -q 'HOOK-CALLED wt=.*wt-issue-100 outcome=.*t100\.err\.json' "$TEST_DIR/hook-calls.log" \
    || red "missing expected hook call for t100"
green "custom hook invoked once per outcome with (wt, outcome-json) args"

heading "Test 13: sweep reports failure when hook returns non-zero"
FAIL_HOOK="$TEST_DIR/bin/failing-hook.sh"
cat > "$FAIL_HOOK" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$FAIL_HOOK"
# Add a fresh outcome that has no .posted marker yet
echo '{"task_id":"tFAIL","outcome":"ok"}' > "$TEST_DIR/wt-issue-99/.swarm/tasks/done/tFAIL.ok.json"
if OUTCOME_HOOK="$FAIL_HOOK" "$SWEEP" "$PROJECT_DIR" > "$TEST_DIR/sweep-5.log" 2>&1; then
    red "sweep should exit non-zero when any hook call fails"
fi
grep -qE 'Failed: 1' "$TEST_DIR/sweep-5.log" || red "expected 'Failed: 1' in summary"
[ ! -e "$TEST_DIR/wt-issue-99/.swarm/tasks/done/tFAIL.ok.json.posted" ] \
    || red "marker should NOT be written when hook fails"
green "failed hook → exit non-zero, no marker, summary reports failure"

# ───────────────── coordinator-watch.sh + sweep integration ─────────────────

heading "Test 14: coordinator-watch.sh POST_OUTCOMES=1 invokes sweep on event"
# Stage a fresh outcome in a registered sibling worktree (where sweep looks).
# coordinator-watch scopes events to `git worktree list`, so a bare sibling
# directory is intentionally ignored as foreign.
git -C "$PROJECT_DIR" worktree add -q -b fix/issue-77 "$TEST_DIR/wt-issue-77" master
mkdir -p "$TEST_DIR/wt-issue-77/.swarm/tasks/done"
echo '{"task_id":"t77","outcome":"ok"}' > "$TEST_DIR/wt-issue-77/.swarm/tasks/done/t77.ok.json"

# Custom hook records each call
INTEGRATION_HOOK="$TEST_DIR/bin/integration-hook.sh"
cat > "$INTEGRATION_HOOK" <<EOF
#!/usr/bin/env bash
echo "INTEGRATION-HOOK: \$1 \$2" >> "$TEST_DIR/integration-hook.log"
EOF
chmod +x "$INTEGRATION_HOOK"

# Stage queue dirs in wt-issue-77 (already done above) — that's where the
# watch will fire its event AND where the sweep will scan. Single layout.
cd "$PROJECT_DIR"
DRY_RUN=0 ONCE=1 POLL_SECS=1 \
    POST_OUTCOMES=1 OUTCOME_HOOK="$INTEGRATION_HOOK" \
    LLM_START="$FAKE_LLM_START" \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-integration.log" 2>&1 &
INT_WATCH_PID=$!

# Baseline scan
sleep 1.5

# Drop NEW outcome in a sibling worktree — watch detects it AND sweep posts it
echo '{"task_id":"trigger","outcome":"ok"}' > "$TEST_DIR/wt-issue-77/.swarm/tasks/done/trigger.ok.json"

# Wait up to 10s for ONCE=1 exit
for ((i=0; i<20; i++)); do
    if ! kill -0 "$INT_WATCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
done
wait "$INT_WATCH_PID" 2>/dev/null || true

grep -q 'sweep: posting outcomes' "$TEST_DIR/watch-integration.log" \
    || red "expected 'sweep: posting outcomes' line; got: $(cat $TEST_DIR/watch-integration.log)"
grep -q 'INTEGRATION-HOOK:.*wt-issue-77.*t77.ok.json' "$TEST_DIR/integration-hook.log" \
    || red "integration hook not called for t77; got: $(cat $TEST_DIR/integration-hook.log 2>/dev/null || echo none)"
[ -f "$TEST_DIR/wt-issue-77/.swarm/tasks/done/t77.ok.json.posted" ] \
    || red ".posted marker missing — sweep should have written it"
green "POST_OUTCOMES=1 fires sweep on event; hook called; .posted marker written"

heading "Test 15a: bg_violation_sweep_pass flags a real background-shell marker (#298)"
# Reuses wt-issue-77's worktree (issue number must be numeric, dir must
# exist) as the sweep's target; iss-77 is a fresh window name not used by
# any earlier test's tmux new-window assertions. DRY_RUN=0: this test
# exercises the real outbox write, not just the log line (see Test 15c).
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
echo 'some worker output here' > "$TEST_DIR/tmux-pane-iss-77.txt"
echo 'Running in the background' >> "$TEST_DIR/tmux-pane-iss-77.txt"
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_BG_VIOLATION_SWEEP_SECS=1 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-bgviol-a.log" 2>&1 &
WATCH_PID=$!

outbox_file=""
for ((i=0; i<20; i++)); do
    outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
    [ -n "$outbox_file" ] && break
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ -n "$outbox_file" ] || red "expected a bg-violation outbox message; log: $(cat "$TEST_DIR/watch-bgviol-a.log")"
grep -q 'kind: fyi' "$outbox_file" || red "expected kind: fyi in $outbox_file"
grep -q 'iss-77' "$outbox_file" || red "expected issue reference in $outbox_file"
green "real background-shell marker -> outbox fyi message dropped for iss-77"

heading "Test 15b: bg_violation_sweep_pass self-match guard suppresses a documentation quote (#298)"
# Same marker text, but on a line that also carries this feature's own
# identifying token — as it would if a worker cats/greps docs/advanced-
# usage.md or this file's own header comment describing the sweep.
# DRY_RUN=0 (same as 15a) so an outbox file's absence proves the guard,
# not merely DRY_RUN's own suppression (see Test 15c for that).
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
scans every iss-* worker pane for the background-shell UI markers Claude
Code leaves behind ("Running in the background", "N shells still running"
at rest) — see SANDBOX_ALLOW_BACKGROUND_TASKS for the opt-out.
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_BG_VIOLATION_SWEEP_SECS=1 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-bgviol-b.log" 2>&1 &
WATCH_PID=$!

# No positive wait condition here (we're proving absence) — give the sweep
# several ticks to have fired, same order of magnitude as Test 15a's wait.
sleep 5
still_running=0
kill -0 "$WATCH_PID" 2>/dev/null && still_running=1
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$still_running" = "1" ] || red "watch process exited unexpectedly; log: $(cat "$TEST_DIR/watch-bgviol-b.log")"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "self-match guard failed to suppress a documentation quote; got: $(cat "$outbox_file")"
green "documentation quote of the marker text does NOT produce a false-positive outbox message"

heading "Test 15c: bg_violation_sweep_pass under DRY_RUN=1 logs but does not write a real outbox message (#298)"
# Self-review finding: every other side-effecting pass in this file
# (autoclose, orphan_sweep_pass) threads DRY_RUN so a log-only watcher run
# never mutates a worker's worktree — bg_violation_sweep_pass must too.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
rm -f "$PROJECT_DIR/.swarm/events.log"
echo 'iss-77' > "$TEST_DIR/tmux-windows.txt"
printf 'some worker output here\nRunning in the background\n' > "$TEST_DIR/tmux-pane-iss-77.txt"

cd "$PROJECT_DIR"
DRY_RUN=1 WATCH_BG_VIOLATION_SWEEP_SECS=1 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-bgviol-c.log" 2>&1 &
WATCH_PID=$!

logged=0
for ((i=0; i<20; i++)); do
    if grep -q 'watch.bg_violation.*dry_run=1' "$PROJECT_DIR/.swarm/events.log" 2>/dev/null; then
        logged=1
        break
    fi
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$logged" = "1" ] || red "expected a dry_run=1 watch.bg_violation event; log: $(cat "$PROJECT_DIR/.swarm/events.log" 2>/dev/null || echo none)"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "DRY_RUN=1 should not write a real outbox message; got: $(cat "$outbox_file")"
green "DRY_RUN=1 logs the violation but writes no real outbox message"

heading "Test 15d: self-match guard does not mask a real, distant violation (#298)"
# Self-review finding on the first guard version: scanning the WHOLE
# 200-line capture for a guard token would let an unrelated, distant
# appearance of one — e.g. prompts/worker.md's own description of this
# feature sitting in scrollback from earlier in the session — mask a real
# violation happening elsewhere in the same pane. Puts a guard token >3
# lines away from the marker (outside the windowed check) and asserts the
# violation still fires.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo 'iss-77' > "$TEST_DIR/tmux-windows.txt"
{
    echo 'earlier in this session the worker read prompts/worker.md,'
    echo 'which explains SANDBOX_ALLOW_BACKGROUND_TASKS at length here'
    echo '(filler filler filler filler filler filler filler filler)'
    echo '(filler filler filler filler filler filler filler filler)'
    echo '(filler filler filler filler filler filler filler filler)'
    echo '(filler filler filler filler filler filler filler filler)'
    echo 'Running in the background'
} > "$TEST_DIR/tmux-pane-iss-77.txt"

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_BG_VIOLATION_SWEEP_SECS=1 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-bgviol-d.log" 2>&1 &
WATCH_PID=$!

outbox_file=""
for ((i=0; i<20; i++)); do
    outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
    [ -n "$outbox_file" ] && break
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ -n "$outbox_file" ] \
    || red "a distant guard-token mention wrongly suppressed a real violation; log: $(cat "$TEST_DIR/watch-bgviol-d.log")"
green "a guard token more than 3 lines from the marker does not suppress a real violation"

heading "Test 15e: a guarded later match does not hide a real earlier one in the same pane (#298)"
# Self-review finding: taking only the LAST match (tail -1) meant a real
# marker earlier in the capture could be hidden behind a LATER
# documentation quote that the guard correctly disqualifies — the sweep
# never even looked at the earlier, real one. Puts a real marker first,
# then a guarded doc quote further down in the same pane, and asserts the
# earlier real one still gets flagged.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo 'iss-77' > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
Running in the background
some worker output here
some more worker output here
scans every iss-* worker pane for the background-shell UI markers Claude
Code leaves behind ("Running in the background", "N shells still running"
at rest) — see SANDBOX_ALLOW_BACKGROUND_TASKS for the opt-out.
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_BG_VIOLATION_SWEEP_SECS=1 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-bgviol-e.log" 2>&1 &
WATCH_PID=$!

outbox_file=""
for ((i=0; i<20; i++)); do
    outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
    [ -n "$outbox_file" ] && break
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ -n "$outbox_file" ] \
    || red "an earlier real marker was hidden behind a later guarded match; log: $(cat "$TEST_DIR/watch-bgviol-e.log")"
green "a guarded later match does not hide an earlier real marker in the same pane"

heading "Test 15f: bg_violation_sweep_pass also scans the coordinator's own window (#385)"
# The #298 incident this whole sweep exists to catch was a coordinator
# pane, not a worker one — the original sweep only ever looked at iss-*
# windows. A "coordinator" window (no wt-issue-N worktree behind it) should
# still get flagged, but delivered only via the events.log line (no outbox
# to drop a message into for a window that isn't a worker's).
rm -f "$PROJECT_DIR/.swarm/events.log"
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "coordinator" > "$TEST_DIR/tmux-windows.txt"
printf 'coordinator scrollback\nRunning in the background\n' > "$TEST_DIR/tmux-pane-coordinator.txt"

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_BG_VIOLATION_SWEEP_SECS=1 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-bgviol-f.log" 2>&1 &
WATCH_PID=$!

logged=0
for ((i=0; i<20; i++)); do
    if grep -q 'watch.bg_violation.*window=coordinator' "$PROJECT_DIR/.swarm/events.log" 2>/dev/null; then
        logged=1
        break
    fi
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$logged" = "1" ] \
    || red "expected a window=coordinator watch.bg_violation event; log: $(cat "$PROJECT_DIR/.swarm/events.log" 2>/dev/null || echo none)"
grep -q 'dry_run=1' "$PROJECT_DIR/.swarm/events.log" \
    && red "coordinator sighting logged as dry_run=1 under DRY_RUN=0"
# Self-review catch: the log line alone doesn't prove the `is_coordinator`
# outbox skip in bg_violation_sweep_pass actually fired — a wt_dir="" for
# the coordinator window makes the (skipped) outbox path
# "$wt_dir/.swarm/tasks/outbox" evaluate to the absolute "/.swarm/tasks/outbox",
# so assert directly that nothing landed there, and that no outbox message
# appeared anywhere under $TEST_DIR (this test's tmux-windows.txt has no
# iss-* window at all, so an outbox file anywhere would only come from a
# broken coordinator skip).
[ -e "/.swarm" ] \
    && red "coordinator sighting wrote to /.swarm — is_coordinator outbox skip did not fire: $(find /.swarm 2>/dev/null)"
outbox_stray="$(find "$TEST_DIR" -path '*/outbox/*.md' 2>/dev/null)" || true
[ -z "$outbox_stray" ] \
    || red "coordinator sighting unexpectedly wrote an outbox message: $outbox_stray"
green "a real background-shell marker on the coordinator's own pane is logged, with no outbox write anywhere (is_coordinator skip verified)"

heading "Test 15g: a WORKER's logged violation, tailed into the coordinator window, is not reattributed as a coordinator sighting (#385)"
# demo-driver.sh's Beat 6 (`tmux split-window ... "tail -F .swarm/events.log"`)
# splits a pane off the coordinator window (window 0, named "coordinator" by
# llm-start.sh's `new-session -n coordinator`) that live-tails this
# project's own events.log — so a WORKER's own watch.bg_violation line can
# end up rendered inside the coordinator window bg_violation_sweep_pass now
# scans. Simulates that by putting a real events.log-shaped line for
# iss-77's violation directly into the coordinator's captured pane text (as
# if `tail -F` had rendered it there) and asserting the sweep does NOT
# relog it as a fresh window=coordinator sighting — proving the
# "(WATCH_BG_VIOLATION_PATTERN)" tag embedded in the logged line itself
# (not just in prompts/coordinator.md's prose) is what keeps this safe
# regardless of how/where the line gets rendered back into a pane.
rm -f "$PROJECT_DIR/.swarm/events.log"
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
printf 'iss-77\ncoordinator\n' > "$TEST_DIR/tmux-windows.txt"
printf 'some worker output here\nRunning in the background\n' > "$TEST_DIR/tmux-pane-iss-77.txt"
tailed_line="$(printf '%s  %-15s %s' "2026-09-09T00:00:00Z" "watch.bg_violation" \
    "issue=77 window=iss-77 marker=Running in the background (WATCH_BG_VIOLATION_PATTERN)")"
printf '=== .swarm/events.log ===\n%s\n' "$tailed_line" > "$TEST_DIR/tmux-pane-coordinator.txt"

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_BG_VIOLATION_SWEEP_SECS=1 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-bgviol-g.log" 2>&1 &
WATCH_PID=$!

# Positive wait: the real iss-77 marker should still fire normally.
outbox_file=""
for ((i=0; i<20; i++)); do
    outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
    [ -n "$outbox_file" ] && break
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ -n "$outbox_file" ] \
    || red "iss-77's own violation should still fire normally; log: $(cat "$TEST_DIR/watch-bgviol-g.log")"
grep -q 'window=coordinator' "$PROJECT_DIR/.swarm/events.log" \
    && red "iss-77's violation, tailed into the coordinator pane, was wrongly reattributed as window=coordinator: $(cat "$PROJECT_DIR/.swarm/events.log")"
green "a worker's own violation line, rendered inside the coordinator window (as demo-driver.sh's events.log tail would), is not reattributed as a coordinator sighting"

rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-iss-77.txt" "$TEST_DIR/tmux-pane-coordinator.txt"

heading "Test 16a: timeout_retry_sweep_pass flags a worker stuck retrying a command past its own timeout (#467)"
# Canned pane capture: 3 WATCH_TIMEOUT_HIT markers (the prompts/worker.md
# "Stop after two timeouts on the same command" rule's echoed marker),
# meeting the default WATCH_TIMEOUT_RETRY_MIN_COUNT=3 threshold. The third
# marker is prefixed the way Claude Code actually renders a Bash tool's
# stdout in the pane (indented under a glyph, never at column 0) — the
# pattern match is unanchored, so this proves real indentation doesn't
# break it, not just the plain-text form the other markers use.
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
  ⎿ WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=3 ran=595s
PANE
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-a.log" 2>&1 &
WATCH_PID=$!

outbox_file=""
for ((i=0; i<20; i++)); do
    outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
    [ -n "$outbox_file" ] && break
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ -n "$outbox_file" ] || red "expected a timeout-retry outbox message; log: $(cat "$TEST_DIR/watch-timeoutretry-a.log")"
grep -q 'kind: fyi' "$outbox_file" || red "expected kind: fyi in $outbox_file"
grep -q 'iss-77' "$outbox_file" || red "expected issue reference in $outbox_file"
green "3 WATCH_TIMEOUT_HIT markers -> outbox fyi message dropped for iss-77"

heading "Test 16b: timeout_retry_sweep_pass does not fire below WATCH_TIMEOUT_RETRY_MIN_COUNT (#467)"
# Same marker, but only 2 occurrences against the default min count of 3 —
# a single retry (one timeout, one legitimate reattempt) should not page
# anyone.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-b.log" 2>&1 &
WATCH_PID=$!

sleep 5
still_running=0
kill -0 "$WATCH_PID" 2>/dev/null && still_running=1
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$still_running" = "1" ] || red "watch process exited unexpectedly; log: $(cat "$TEST_DIR/watch-timeoutretry-b.log")"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "2 markers (below MIN_COUNT=3) wrongly fired an outbox message; got: $(cat "$outbox_file")"
green "2 WATCH_TIMEOUT_HIT markers (below the default min count of 3) do not fire"

heading "Test 16c: timeout_retry_sweep_pass under DRY_RUN=1 logs but does not write a real outbox message (#467)"
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
rm -f "$PROJECT_DIR/.swarm/events.log"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=3 ran=595s
PANE

cd "$PROJECT_DIR"
DRY_RUN=1 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-c.log" 2>&1 &
WATCH_PID=$!

logged=0
for ((i=0; i<20; i++)); do
    if grep -q 'watch.timeout_retry.*dry_run=1' "$PROJECT_DIR/.swarm/events.log" 2>/dev/null; then
        logged=1
        break
    fi
    sleep 0.5
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$logged" = "1" ] || red "expected a dry_run=1 watch.timeout_retry event; log: $(cat "$PROJECT_DIR/.swarm/events.log" 2>/dev/null || echo none)"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "DRY_RUN=1 should not write a real outbox message; got: $(cat "$outbox_file")"
green "DRY_RUN=1 logs the timeout-retry sighting but writes no real outbox message"

heading "Test 16d: a rendered command SOURCE line (not real output) does not false-positive (#467, self-review finding)"
# Claude Code renders the command text it ran into the pane verbatim — if
# prompts/worker.md's example wrote the literal token in the command
# source, every run of that snippet (timed out or not) would render
# "WATCH_TIMEOUT_HIT" in the pane and get counted, even with no real
# timeout and no real echoed output. The shipped worker.md snippet avoids
# this by building the marker from two concatenated string literals
# ("WATCH_TIMEOUT" "_HIT ...") so the whole token never appears contiguous
# in the command source — only in the actual printed output. This fixture
# reproduces worker.md's exact current command source (redirect, exit-code
# echo, if-block) three times with the `if` condition always false (as if
# the command never actually timed out), and asserts the sweep does not
# fire. Keep this in sync with worker.md's example if that changes again.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
echo "exit=$ec"
if [ "$ec" = 124 ]; then
    echo "WATCH_TIMEOUT""_HIT cmd=\"restore.sh\" attempt=1 ran=595s"
fi
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
echo "exit=$ec"
if [ "$ec" = 124 ]; then
    echo "WATCH_TIMEOUT""_HIT cmd=\"restore.sh\" attempt=2 ran=595s"
fi
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
echo "exit=$ec"
if [ "$ec" = 124 ]; then
    echo "WATCH_TIMEOUT""_HIT cmd=\"restore.sh\" attempt=3 ran=595s"
fi
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-d.log" 2>&1 &
WATCH_PID=$!

sleep 5
still_running=0
kill -0 "$WATCH_PID" 2>/dev/null && still_running=1
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$still_running" = "1" ] || red "watch process exited unexpectedly; log: $(cat "$TEST_DIR/watch-timeoutretry-d.log")"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "a rendered command SOURCE line (no real timeout, no real output) wrongly fired an outbox message; got: $(cat "$outbox_file")"
green "three renderings of the split-token command source (no real timeout output) do not false-positive"

rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-iss-77.txt"

heading "Test 16e: a worker's own prose about the marker does not false-positive an obedient worker (#467, self-review finding)"
# Second self-review finding: a worker that obeys the rule (2 real timeouts,
# then stops) can still get flagged if it later writes about the marker in
# its own summary or decision-needed narration, e.g. "that's a second
# WATCH_TIMEOUT_HIT, stopping per the rule" — 2 real + 1 narrated = 3,
# tripping WATCH_TIMEOUT_RETRY_MIN_COUNT on a worker that did everything
# right. Line-anchoring the pattern was tried and reverted (a THIRD
# self-review finding): Claude Code indents real tool stdout under a `⎿`
# glyph, never column 0, so an anchor would have missed real sightings too.
# Fixed instead with a context self-match guard, same mechanism
# bg_violation_sweep_pass already uses (see test 15b) — a candidate within 3
# lines of "decision-needed" or "worker.md" is prose, not a real sighting.
# This fixture has exactly 2 real markers plus one prose line mentioning the
# token and both guard tokens, and asserts the sweep does not fire.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
That's a second WATCH_TIMEOUT_HIT, so per worker.md I'm stopping and filing
a decision-needed message instead of retrying a third time.
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-e.log" 2>&1 &
WATCH_PID=$!

sleep 5
still_running=0
kill -0 "$WATCH_PID" 2>/dev/null && still_running=1
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$still_running" = "1" ] || red "watch process exited unexpectedly; log: $(cat "$TEST_DIR/watch-timeoutretry-e.log")"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "an obedient worker's own prose about the marker wrongly tipped the sweep over; got: $(cat "$outbox_file")"
green "2 real markers + 1 guarded prose mention of the token do not false-positive"

rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-iss-77.txt"

heading "Test 16f: the self-match guard does not mask a real, distant violation (#467)"
# Mirrors test 15d for bg_violation_sweep_pass's own guard: a guard token
# (here "worker.md", from an unrelated earlier line) more than 3 lines away
# from a real marker must not suppress it. Scrollback has "worker.md" once
# at the top, then 3 real markers all more than 3 lines below it — the
# sweep should still fire.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
Reading prompts/worker.md to check the task conventions before starting.
filler line 1
filler line 2
filler line 3
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=3 ran=595s
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-f.log" 2>&1 &
WATCH_PID=$!

outbox_file=""
for _ in $(seq 1 10); do
    outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
    [ -n "$outbox_file" ] && break
    sleep 1
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ -n "$outbox_file" ] \
    || red "a guard token 4+ lines from 3 real markers wrongly suppressed the sighting; log: $(cat "$TEST_DIR/watch-timeoutretry-f.log")"
grep -q 'kind: fyi' "$outbox_file" || red "outbox file missing 'kind: fyi': $(cat "$outbox_file")"
grep -q 'iss-77' "$outbox_file" || red "outbox file doesn't name iss-77: $(cat "$outbox_file")"
green "a guard token more than 3 lines from 3 real markers does not suppress the sighting"

rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-iss-77.txt"

heading "Test 16g: a decision-needed body that retypes the marker DOES fire, unguarded by distance (#467, round-10 self-review finding)"
# Fourth self-review finding (round 10): test 16e's prose line sat right
# next to both guard tokens, closer than the real outbox template ever
# would — self-review caught that in that fixture, "kind: decision-needed"
# landed only 3 lines after the second real marker, inside the guard
# window, which silently dropped that real marker from the count without
# either test noticing. To show the actual risk (and that the guard really
# doesn't reach this far), this fixture spaces 2 real markers AND a third,
# retyped mention of the marker inside a rendered decision-needed heredoc
# all more than 3 lines from every guard token (verified below) — proving
# that if a worker ignored the new instruction and retyped the literal
# marker in that message's body, the sweep would still correctly fire.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
Two attempts in a row have now hit the wall.
Writing the outbox message next.
cat > "$tmp" <<EOF
---
kind: decision-needed
task_id: wt-issue-77
ts: 2026-10-05T00:00:00Z
---
This is the second WATCH_TIMEOUT_HIT on restore.sh in a row, so per the
rule I am stopping instead of retrying a third time.
EOF
PANE
# Sanity-check the fixture's own spacing before trusting the sweep's
# verdict on it: every candidate line must be >3 lines from every guard
# token, i.e. genuinely unguarded, or this test would prove nothing.
awk '
    /WATCH_TIMEOUT_HIT/ { markers[NR] = 1 }
    /WATCH_TIMEOUT_RETRY_SWEEP_SECS|WATCH_TIMEOUT_RETRY_PATTERN|WATCH_TIMEOUT_RETRY_MIN_COUNT|decision-needed|worker\.md/ { guards[NR] = 1 }
    END {
        for (m in markers) for (g in guards) {
            d = m - g; if (d < 0) d = -d
            if (d <= 3) { print "fixture bug: marker line " m " is within " d " lines of guard line " g; bad = 1 }
        }
        exit bad
    }
' "$TEST_DIR/tmux-pane-iss-77.txt" \
    || red "test 16g's own fixture doesn't actually test an unguarded case — fix the spacing"

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-g.log" 2>&1 &
WATCH_PID=$!

outbox_file=""
for _ in $(seq 1 10); do
    outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
    [ -n "$outbox_file" ] && break
    sleep 1
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ -n "$outbox_file" ] \
    || red "an unguarded, retyped third marker in a decision-needed body did not fire; log: $(cat "$TEST_DIR/watch-timeoutretry-g.log")"
green "2 real markers + an unguarded retyped mention in a decision-needed body DOES fire (3 unguarded hits)"

rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-iss-77.txt"

heading "Test 16h: the same decision-needed body, worded per the fix, does not false-positive (#467, round-10 self-review finding)"
# Same two real markers and the same spacing as 16g (so the 2 real hits are
# genuinely unguarded, not accidentally swallowed by proximity to
# "decision-needed" the way the original, now-replaced 16g fixture was) —
# but the body now follows worker.md's round-10 instruction: it describes
# the stop in words instead of retyping the literal marker. That leaves
# only 2 real, unguarded hits, under WATCH_TIMEOUT_RETRY_MIN_COUNT=3, so
# this proves the fix (not the guard) is what keeps an obedient worker
# clean here — the guard never had to reach across the YAML frontmatter.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
Two attempts in a row have now hit the wall.
Writing the outbox message next.
cat > "$tmp" <<EOF
---
kind: decision-needed
task_id: wt-issue-77
ts: 2026-10-05T00:00:00Z
---
Hit the timeout twice in a row on restore.sh (two attempts, ~595s each).
A full restore needs about 26 minutes per the dev-db size; handing this to
the util pane, which has no timeout, is the usual fix. Parking as blocked.
EOF
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-h.log" 2>&1 &
WATCH_PID=$!

sleep 5
still_running=0
kill -0 "$WATCH_PID" 2>/dev/null && still_running=1
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$still_running" = "1" ] || red "watch process exited unexpectedly; log: $(cat "$TEST_DIR/watch-timeoutretry-h.log")"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "a realistically-spaced, non-retyping decision-needed body wrongly tipped the sweep over; got: $(cat "$outbox_file")"
green "2 real, genuinely unguarded markers + a decision-needed body that never retypes the marker do not false-positive"

rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-iss-77.txt"

heading "Test 16i: plain pane narration with no nearby guard words, worded per the fix, does not false-positive (#467, round-12 self-review finding)"
# Fifth self-review finding (round 12): round 10's fix only told the
# worker not to retype the marker in the decision-needed outbox message —
# but round 2's original finding was about ANY narration, including plain
# pane prose with no "decision-needed" or "worker.md" nearby to guard it.
# worker.md's instruction was widened to cover typing the bare token
# anywhere outside the echo commands, not just the outbox message. This
# fixture is round 2's exact original failure shape — a plain narration
# line right after the second marker, with no guard word within 3 lines —
# but worded per the widened fix (describes the stop, never retypes the
# token), proving the fix itself is what keeps this clean, since there is
# no guard token anywhere in this fixture for the self-match guard to use.
rm -rf "$TEST_DIR/wt-issue-77/.swarm/tasks/outbox"
echo "iss-77" > "$TEST_DIR/tmux-windows.txt"
cat > "$TEST_DIR/tmux-pane-iss-77.txt" <<'PANE'
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=1 ran=595s
timeout 595 ./restore.sh >/tmp/restore.log 2>&1; ec=$?
exit=124
WATCH_TIMEOUT_HIT cmd="restore.sh" attempt=2 ran=595s
That's two timeouts in a row on restore.sh, so I'm stopping here instead
of retrying a third time, and filing a message about it next.
PANE

cd "$PROJECT_DIR"
DRY_RUN=0 WATCH_TIMEOUT_RETRY_SWEEP_SECS=1 WATCH_BG_VIOLATION_SWEEP_SECS=0 WATCH_PR_POLL_SECS=0 \
    WATCH_ORPHAN_SWEEP_SECS=0 WATCH_CHECK_ON_DONE=0 POLL_SECS=1 \
    "$WATCH" "$PROJECT_DIR" > "$TEST_DIR/watch-timeoutretry-i.log" 2>&1 &
WATCH_PID=$!

sleep 5
still_running=0
kill -0 "$WATCH_PID" 2>/dev/null && still_running=1
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
unset WATCH_PID

[ "$still_running" = "1" ] || red "watch process exited unexpectedly; log: $(cat "$TEST_DIR/watch-timeoutretry-i.log")"
outbox_file="$(ls "$TEST_DIR"/wt-issue-77/.swarm/tasks/outbox/*.md 2>/dev/null | head -1)" || true
[ -z "$outbox_file" ] \
    || red "plain narration with no guard word nearby, worded per the fix, wrongly tipped the sweep over; got: $(cat "$outbox_file")"
green "2 real markers + unguarded plain narration that never retypes the token do not false-positive"

rm -f "$TEST_DIR/tmux-windows.txt" "$TEST_DIR/tmux-pane-iss-77.txt"

# ────────────────────────── Done ──────────────────────────

heading "All shape-orchestration tests passed"
echo "  provision-worker.sh:     worktree+branch+brief, policy embedding, idempotent re-run"
echo "  coordinator-watch.sh:    polling backend detects .ok.json; error on missing dir;"
echo "                           POST_OUTCOMES=1 invokes sweep with custom hook"
echo "  sandbox-worktrees.sh:    list mode, non-git error, -t-without-TMUX error"
echo "  sweep-swarm-outcomes.sh: default hook, .posted idempotency, SWEEP_FORCE, custom hook, hook failure"
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
