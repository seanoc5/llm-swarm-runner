#!/usr/bin/env bash
#
# test-shape-coord-action-lock.sh — issue #766 (ADR 0006 §3):
#   A. two concurrent swarm-merge.sh runs on one PR merge it exactly once
#   B. a head that moved between the gates and the merge is refused
#   C. a normal single merge still merges (and takes no lock beyond the call)
#   D. provision-worker.sh refuses a duplicate dispatch for a live worker,
#      but still re-provisions after a crash (no window)
#   E. requeue.sh refuses a byte-identical brief that is already pending
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
    head=aaa111
    case "\$*" in *"--jq .headRefOid"*) echo aaa111; exit 0 ;; esac
    # the re-read under the action lock asks for exactly "state,headRefOid"
    if [ "\$*" = "pr view 600 --json state,headRefOid" ] && [ -e "\$S/move-head" ]; then head=bbb222; fi
    printf '{"state":"%s","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"fix/issue-600","title":"t","closingIssuesReferences":[],"body":"","isDraft":false,"reviewDecision":"","baseRefName":"master","headRefOid":"%s"}\n' "\$st" "\$head"
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
printf '#!/usr/bin/env bash\ncase "${1:-}" in has-session) exit 0;; list-panes) echo 0;; list-windows) cat "%s/windows" 2>/dev/null;; esac\nexit 0\n' "$TEST_DIR" > "$TEST_DIR/bin/tmux"
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
echo "iss-31" > "$TEST_DIR/windows"            # worker window is now live
rc=$(prov 31)
[ "$rc" = 5 ] || red "duplicate provision should exit 5, got $rc: $(cat "$TEST_DIR/prov.log")"
[ "$(inbox_count 31)" = 1 ] || red "duplicate provision queued a second brief"
green "second provision of a live issue: exit 5, still one brief"
rm -f "$TEST_DIR/windows"                       # window gone (crash)
rc=$(prov 31)
[ "$rc" = 0 ] || red "re-provision after crash should still work, rc=$rc: $(cat "$TEST_DIR/prov.log")"
green "no live window: re-provision allowed (stale brief salvaged)"

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
