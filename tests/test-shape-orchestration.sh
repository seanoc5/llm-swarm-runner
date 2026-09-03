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
# Stub: provision-worker.sh uses has-session + list-windows + new-window.
# Pretend the session always exists, no windows yet, log new-window calls.
TMUX_LOG="$TEST_DIR/tmux.log"
case "\${1:-}" in
    has-session)   exit 0 ;;
    list-windows)  exit 0 ;;
    new-window)    echo "\$*" >> "\$TMUX_LOG" ;;
    *)             echo "stub-tmux: ignored: \$*" >> "\$TMUX_LOG" ;;
esac
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/tmux"
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
grep -q '\[DRY\] would:.*outbox' "$TEST_DIR/watch-outbox.log" \
    || red "expected dry-run outbox wake prompt naming the outbox; full log: $(cat $TEST_DIR/watch-outbox.log)"
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

# ────────────────────────── Done ──────────────────────────

heading "All shape-orchestration tests passed"
echo "  provision-worker.sh:     worktree+branch+brief, policy embedding, idempotent re-run"
echo "  coordinator-watch.sh:    polling backend detects .ok.json; error on missing dir;"
echo "                           POST_OUTCOMES=1 invokes sweep with custom hook"
echo "  sandbox-worktrees.sh:    list mode, non-git error, -t-without-TMUX error"
echo "  sweep-swarm-outcomes.sh: default hook, .posted idempotency, SWEEP_FORCE, custom hook, hook failure"
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
