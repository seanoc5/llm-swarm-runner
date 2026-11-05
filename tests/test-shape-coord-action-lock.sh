#!/usr/bin/env bash
#
# test-shape-coord-action-lock.sh — issue #766 (ADR 0006 §3):
#   A. two concurrent swarm-merge.sh runs on one PR merge it exactly once
#   B. a head that moved between the gates and the merge is refused
#   C. a normal single merge still merges (and takes no lock beyond the call)
#   D. provision-worker.sh refuses a duplicate dispatch for a live worker,
#      but still re-provisions after a crash (no window)
#   E. requeue.sh refuses a byte-identical brief that is already pending
#   E2. requeue.sh dispatch-lock timeout exits 7, not the duplicate code 5
#   H. --auto-low/--auto-medium refuse when the action lock is unavailable
# gh/tmux/docker are stubbed on PATH.
set -euo pipefail
green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TEST_DIR=$(mktemp -d -t shape-coord-action-lock-XXXXXX)
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"

# ---- stubs ------------------------------------------------------------
cat > "$TEST_DIR/bin/gh" <<STUB
#!/usr/bin/env bash
S="$TEST_DIR/state"; mkdir -p "\$S"
case "\${1:-} \${2:-}" in
  "api repos/{owner}/{repo}/issues/600") echo true; exit 0 ;;
  "pr view")
    if [ -e "\$S/merged" ]; then st=MERGED; else st=OPEN; fi
    head=aaa1111
    case "\$*" in *"--jq .headRefOid"*) echo aaa1111; exit 0 ;; esac
    # the re-read under the action lock asks for exactly "state,headRefOid"
    if [ "\$*" = "pr view 600 --json state,headRefOid" ]; then
      [ -e "\$S/fail-reread" ] && exit 1
      if [ -e "\$S/move-head" ]; then head=bbb2222; fi
    fi
    body=""; [ -e "\$S/body-low" ] && body="<!-- BLIND_MERGE_RISK: low -->"
    printf '{"state":"%s","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"fix/issue-600","title":"t","closingIssuesReferences":[],"body":"%s","isDraft":false,"reviewDecision":"","baseRefName":"master","headRefOid":"%s"}\n' "\$st" "\$body" "\$head"
    exit 0 ;;
  "pr merge")
    sleep 1
    echo "\$\$" >> "\$S/merge-calls"
    touch "\$S/merged"; exit 0 ;;
  "pr list") echo "[]"; exit 0 ;;
  "issue view")
    case "\$*" in *comments*) echo '{"comments":[]}' ;; *) echo "FAKE issue body" ;; esac; exit 0 ;;
esac
exit 0
STUB
cat > "$TEST_DIR/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  has-session) exit 0 ;;
  list-panes) echo 0 ;;
  new-window) sleep 1; echo "\$6" >> "$TEST_DIR/windows" ;;   # window exists once spawned
  list-windows) cat "$TEST_DIR/windows" 2>/dev/null ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/docker"
chmod +x "$TEST_DIR"/bin/*
export PATH="$TEST_DIR/bin:$PATH"

# ---- merge tests --------------------------------------------------------
REPO="$TEST_DIR/main/proj"; mkdir -p "$REPO"
git -C "$REPO" init -q -b master
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q --bare "$REPO" "$TEST_DIR/merge-origin.git"
git -C "$REPO" remote add origin "$TEST_DIR/merge-origin.git"
git -C "$REPO" push -q origin master:fix/issue-600
git -C "$REPO" fetch -q origin
export COORD_ACTIONS_LOCK="$TEST_DIR/coord-actions.lock"
MERGE="$ROOT/scripts/swarm-merge.sh"
reset() { rm -rf "$TEST_DIR/state"; git -C "$REPO" push -q -f origin master:fix/issue-600; }
merges() { [ -f "$TEST_DIR/state/merge-calls" ] && wc -l < "$TEST_DIR/state/merge-calls" || echo 0; }

heading "C: normal merge still merges"
reset
( cd "$REPO" && timeout 30 "$MERGE" 600 --no-kill >"$TEST_DIR/c.log" 2>&1 ) || red "normal merge failed: $(cat "$TEST_DIR/c.log")"
[ "$(merges)" = 1 ] || red "expected 1 merge call, got $(merges)"
green "single merge: one gh pr merge call"

heading "A: two concurrent merges of one PR merge once"
reset
( cd "$REPO" && timeout 30 "$MERGE" 600 --no-kill >"$TEST_DIR/a1.log" 2>&1 ) & p1=$!
( cd "$REPO" && timeout 30 "$MERGE" 600 --no-kill >"$TEST_DIR/a2.log" 2>&1 ) & p2=$!
rc1=0; rc2=0; wait $p1 || rc1=$?; wait $p2 || rc2=$?
[ "$(merges)" = 1 ] || red "expected exactly 1 merge call, got $(merges) (rc $rc1/$rc2)
$(cat "$TEST_DIR/a1.log" "$TEST_DIR/a2.log")"
green "two concurrent merges -> $(merges) gh pr merge call (rc $rc1/$rc2)"

heading "B: head moved between gates and merge is refused"
reset; mkdir -p "$TEST_DIR/state"; touch "$TEST_DIR/state/move-head"
rc=0; ( cd "$REPO" && timeout 30 "$MERGE" 600 --no-kill >"$TEST_DIR/b.log" 2>&1 ) || rc=$?
[ "$rc" != 0 ] || red "merge should have been refused"
grep -q 'head moved' "$TEST_DIR/b.log" || red "no head-moved message: $(cat "$TEST_DIR/b.log")"
[ "$(merges)" = 0 ] || red "gh pr merge was called despite the moved head"
green "moved head refused, nothing merged"

# --auto-low path: fake ci-wait.sh that, like the real one, follows a head that
# arrives during the wait and reports the NEWEST commit as verified-head.
cat > "$TEST_DIR/ci-wait-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "verified-head=${FAKE_VERIFIED_HEAD:-aaa1111}"
exit 0
STUB
chmod +x "$TEST_DIR/ci-wait-stub.sh"
auto() { ( cd "$REPO" && SWARM_MERGE_TEST_HOOKS=1 CI_WAIT_SCRIPT="$TEST_DIR/ci-wait-stub.sh" timeout 30 "$MERGE" 600 --no-kill --auto-low "$@" >"$TEST_DIR/auto.log" 2>&1 ); }

heading "B2: --auto-low, head moved during the CI wait (CI verified the new head) is refused"
reset; mkdir -p "$TEST_DIR/state"; touch "$TEST_DIR/state/body-low" "$TEST_DIR/state/move-head"
rc=0; FAKE_VERIFIED_HEAD=bbb2222 auto || rc=$?
[ "$rc" != 0 ] || red "auto-low merge should have been refused: $(cat "$TEST_DIR/auto.log")"
grep -q 'gates read aaa1111' "$TEST_DIR/auto.log" || red "no moved-since-gates message: $(cat "$TEST_DIR/auto.log")"
[ "$(merges)" = 0 ] || red "gh pr merge was called despite the head moving during the CI wait"
green "auto-low: head that moved during CI wait refused, nothing merged"

heading "B3: --auto-low with a stable head still merges (control for B2)"
reset; mkdir -p "$TEST_DIR/state"; touch "$TEST_DIR/state/body-low"
auto || red "stable-head auto-low merge failed: $(cat "$TEST_DIR/auto.log")"
[ "$(merges)" = 1 ] || red "expected 1 merge call, got $(merges)"
green "auto-low: stable head merges"

heading "F: re-read under the lock fails: --auto-low refuses, plain merge proceeds"
reset; mkdir -p "$TEST_DIR/state"; touch "$TEST_DIR/state/body-low" "$TEST_DIR/state/fail-reread"
rc=0; auto || rc=$?
[ "$rc" != 0 ] || red "auto-low should refuse when the re-read fails"
grep -q 're-read under the action lock failed' "$TEST_DIR/auto.log" || red "no reread-failed message: $(cat "$TEST_DIR/auto.log")"
[ "$(merges)" = 0 ] || red "auto-low merged despite a failed re-read"
reset; mkdir -p "$TEST_DIR/state"; touch "$TEST_DIR/state/fail-reread"
( cd "$REPO" && timeout 30 "$MERGE" 600 --no-kill >"$TEST_DIR/f.log" 2>&1 ) || red "plain merge should proceed on a failed re-read: $(cat "$TEST_DIR/f.log")"
[ "$(merges)" = 1 ] || red "plain merge expected 1 call, got $(merges)"
green "failed re-read: auto-low refused, plain merge continues"

heading "G: lock timeout refuses, names swarm-merge.sh, never says exit 5 / Retry"
reset
( exec 9>"$COORD_ACTIONS_LOCK"; flock 9; sleep 8 ) & holder=$!
sleep 1
rc=0; ( cd "$REPO" && COORD_ACTIONS_LOCK_TIMEOUT_SECS=1 timeout 30 "$MERGE" 600 --no-kill >"$TEST_DIR/g.log" 2>&1 ) || rc=$?
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
[ "$rc" = 1 ] || red "lock timeout should exit 1, got $rc: $(cat "$TEST_DIR/g.log")"
grep -q 'not provision-worker.sh' "$TEST_DIR/g.log" || red "timeout message does not name its script: $(cat "$TEST_DIR/g.log")"
grep -q 'Retry' "$TEST_DIR/g.log" && red "timeout message still says Retry"
[ "$(merges)" = 0 ] || red "merged despite the lock timeout"
green "lock timeout: exit 1, script named, nothing merged"

# ---- dispatch tests -----------------------------------------------------
PROJECT_DIR="$TEST_DIR/proj"; mkdir -p "$PROJECT_DIR/.swarm"
git -C "$PROJECT_DIR" init -q -b master
git -C "$PROJECT_DIR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git clone -q --bare "$PROJECT_DIR" "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" remote add origin "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" fetch -q origin
export HOST_STATE_DIR="$TEST_DIR/host-state" LLM_SWARM_DIR="$TEST_DIR/sandbox"
mkdir -p "$LLM_SWARM_DIR/scripts" "$HOST_STATE_DIR"
cp "$ROOT/sandbox.sh" "$LLM_SWARM_DIR/"
cp "$ROOT"/scripts/{_load-env.sh,_window-flags.sh,provision-worker.sh,requeue.sh} "$LLM_SWARM_DIR/scripts/"
off=(HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0 PROVISION_SPAWN_CHECK_SECS=0 BRIEF_LINT=0)
prov() { set +e; ( cd "$PROJECT_DIR" && env "${off[@]}" bash "$LLM_SWARM_DIR/scripts/provision-worker.sh" "$@" >"$TEST_DIR/prov.log" 2>&1 ); local rc=$?; set -e; echo "$rc"; }
inbox_count() { find "$TEST_DIR" -path "*wt-issue-$1/.swarm/tasks/inbox/*.md" | wc -l; }

heading "D: duplicate provision refused for a live worker; crash recovery still works"
[ "$(prov 31)" = 0 ] || red "first provision failed: $(cat "$TEST_DIR/prov.log")"
[ "$(inbox_count 31)" = 1 ] || red "expected 1 brief after first provision"
grep -qx iss-31 "$TEST_DIR/windows" || red "stub tmux should list iss-31 after the spawn"
rc=$(prov 31)
[ "$rc" = 5 ] || red "duplicate provision should exit 5, got $rc: $(cat "$TEST_DIR/prov.log")"
[ "$(inbox_count 31)" = 1 ] || red "duplicate provision queued a second brief"
green "second provision of a live issue: exit 5, still one brief"
rm -f "$TEST_DIR/windows"                       # window gone (crash)
rc=$(prov 31)
[ "$rc" = 0 ] || red "re-provision after crash should still work, rc=$rc: $(cat "$TEST_DIR/prov.log")"
green "no live window: re-provision allowed (stale brief salvaged)"

heading "D2: two simultaneous first provisions of one issue queue one brief"
rm -f "$TEST_DIR/windows"
( set +e; ( cd "$PROJECT_DIR" && env "${off[@]}" bash "$LLM_SWARM_DIR/scripts/provision-worker.sh" 32 >"$TEST_DIR/p1.log" 2>&1 ); echo $? >"$TEST_DIR/p1.rc" ) &
( set +e; ( cd "$PROJECT_DIR" && env "${off[@]}" bash "$LLM_SWARM_DIR/scripts/provision-worker.sh" 32 >"$TEST_DIR/p2.log" 2>&1 ); echo $? >"$TEST_DIR/p2.rc" ) &
wait
rcs="$(sort "$TEST_DIR/p1.rc" "$TEST_DIR/p2.rc" | tr '\n' ' ')"
[ "$rcs" = "0 5 " ] || red "expected one success and one duplicate refusal, got: $rcs
$(cat "$TEST_DIR/p1.log" "$TEST_DIR/p2.log")"
[ "$(inbox_count 32)" = 1 ] || red "expected exactly 1 brief, got $(inbox_count 32)"
[ "$(grep -c iss-32 "$TEST_DIR/windows")" = 1 ] || red "expected exactly one spawned window"
green "concurrent provisions: one spawned, one refused (exit 5), one brief"

heading "D3: dispatch-lock timeout exits 7 (not 5) and says so"
WT33="$(dirname "$(find "$TEST_DIR" -maxdepth 3 -type d -name wt-issue-31 | head -1)")/wt-issue-33"
( exec 9>"$(dirname "$WT33")/.dispatch-wt-issue-33.lock"; flock 9; sleep 6 ) & holder=$!
sleep 1
rc=$(set +e; ( cd "$PROJECT_DIR" && env "${off[@]}" PROVISION_DISPATCH_LOCK_TIMEOUT_SECS=1 bash "$LLM_SWARM_DIR/scripts/provision-worker.sh" 33 >"$TEST_DIR/prov.log" 2>&1 ); echo $?)
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
[ "$rc" = 7 ] || red "dispatch-lock timeout should exit 7, got $rc: $(cat "$TEST_DIR/prov.log")"
grep -q 'not exit 5' "$TEST_DIR/prov.log" || red "timeout message does not distinguish exit 5"
[ "$(inbox_count 33)" = 0 ] || red "a brief was queued despite the lock timeout"
green "dispatch-lock timeout: exit 7, nothing queued"

heading "E: requeue.sh refuses an identical pending brief"
WT="$(find "$TEST_DIR" -maxdepth 3 -type d -name wt-issue-31 | head -1)"
echo "please also handle X" > "$TEST_DIR/brief.md"
( cd "$PROJECT_DIR" && bash "$LLM_SWARM_DIR/scripts/requeue.sh" "$WT" "$TEST_DIR/brief.md" >/dev/null 2>&1 ) || red "first requeue failed"
n1=$(find "$WT/.swarm/tasks/inbox" -name '*.md' | wc -l)
rc=0; ( cd "$PROJECT_DIR" && bash "$LLM_SWARM_DIR/scripts/requeue.sh" "$WT" "$TEST_DIR/brief.md" >/dev/null 2>&1 ) || rc=$?
[ "$rc" = 5 ] || red "duplicate requeue should exit 5, got $rc"
[ "$(find "$WT/.swarm/tasks/inbox" -name '*.md' | wc -l)" = "$n1" ] || red "duplicate requeue added a file"
green "identical second requeue: exit 5, inbox unchanged"
echo "different" > "$TEST_DIR/brief2.md"
( cd "$PROJECT_DIR" && bash "$LLM_SWARM_DIR/scripts/requeue.sh" "$WT" "$TEST_DIR/brief2.md" >/dev/null 2>&1 ) || red "a different brief should still queue"
green "a different brief still queues"

heading "E2: requeue.sh dispatch-lock timeout exits 7 (not 5) and says so"
echo "third brief" > "$TEST_DIR/brief3.md"
n2=$(find "$WT/.swarm/tasks/inbox" -name '*.md' | wc -l)
( exec 9>"$(dirname "$WT")/.dispatch-$(basename "$WT").lock"; flock 9; sleep 6 ) & holder=$!
sleep 1
rc=0; ( cd "$PROJECT_DIR" && PROVISION_DISPATCH_LOCK_TIMEOUT_SECS=1 bash "$LLM_SWARM_DIR/scripts/requeue.sh" "$WT" "$TEST_DIR/brief3.md" >"$TEST_DIR/e2.log" 2>&1 ) || rc=$?
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
[ "$rc" = 7 ] || red "requeue lock timeout should exit 7, got $rc: $(cat "$TEST_DIR/e2.log")"
grep -q 'not exit 5' "$TEST_DIR/e2.log" || red "requeue timeout message does not distinguish exit 5: $(cat "$TEST_DIR/e2.log")"
grep -q 'Retry' "$TEST_DIR/e2.log" && red "requeue timeout message still says Retry"
[ "$(find "$WT/.swarm/tasks/inbox" -name '*.md' | wc -l)" = "$n2" ] || red "a brief was queued despite the lock timeout"
green "requeue lock timeout: exit 7, nothing queued"

heading "H: action lock unavailable: --auto-low refuses, plain merge proceeds"
reset; mkdir -p "$TEST_DIR/state"; touch "$TEST_DIR/state/body-low"
printf x > "$TEST_DIR/not-a-dir"                     # lock path under a regular file: unopenable
rc=0; COORD_ACTIONS_LOCK="$TEST_DIR/not-a-dir/coord.lock" auto || rc=$?
[ "$rc" != 0 ] || red "auto-low should refuse without the action lock: $(cat "$TEST_DIR/auto.log")"
grep -q 'action lock unavailable' "$TEST_DIR/auto.log" || red "no lock-unavailable message: $(cat "$TEST_DIR/auto.log")"
[ "$(merges)" = 0 ] || red "auto-low merged without the action lock"
reset
( cd "$REPO" && COORD_ACTIONS_LOCK="$TEST_DIR/not-a-dir/coord.lock" timeout 30 "$MERGE" 600 --no-kill >"$TEST_DIR/h.log" 2>&1 ) || red "plain merge should proceed without the lock: $(cat "$TEST_DIR/h.log")"
[ "$(merges)" = 1 ] || red "plain merge expected 1 call, got $(merges)"
green "no action lock: auto-low refused, plain merge continues with the warning"
