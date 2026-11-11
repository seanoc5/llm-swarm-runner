#!/usr/bin/env bash
#
# test-shape-check-skip-no-change.sh — issue #494: worker-listener.sh skips the
# acceptance check when the worker session changed nothing (clean tree, HEAD
# where the task started), records check_exit "skipped_no_change", and still
# runs it after any edit or new commit. Also covers the "still running"
# heartbeat. Same `bash` fallback-agent trick as test-shape-checks.sh.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

command -v jq >/dev/null 2>&1 || red "jq required"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
SCOREBOARD="$SCRIPT_DIR/../scripts/swarm-scoreboard.sh"
[ -x "$LISTENER" ] || red "worker-listener.sh not executable"

TEST_DIR=$(mktemp -d -t check-skip-XXXXXX)
LISTENER_PIDS=()
cleanup() {
    for pid in "${LISTENER_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
    if [ "${KEEP:-0}" = "1" ]; then yellow "KEEP=1: $TEST_DIR"; else rm -rf "$TEST_DIR"; fi
}
trap cleanup EXIT

wait_for() {
    local desc="$1" cmd="$2"
    for ((i=0; i<60; i++)); do eval "$cmd" && return 0; sleep 0.5; done
    red "timeout waiting for: $desc"
}
drop_v2() {
    local tmp
    tmp=$(mktemp -p .swarm/tasks/inbox .tmp.XXXX.md)
    printf '%s\n' "$2" > "$tmp"
    mv "$tmp" ".swarm/tasks/inbox/$1.md"
}

WT="$TEST_DIR/wt"
mkdir -p "$WT/.swarm/tasks/inbox" "$WT/.swarm/tasks/processing" "$WT/.swarm/tasks/done"
git -C "$WT" init -q
printf '.swarm/\nlistener.log\n' > "$WT/.git/info/exclude"
echo base > "$WT/tracked.txt"
git -C "$WT" add tracked.txt
git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m base
RAN="$TEST_DIR/check-ran"
( cd "$WT" && env WORKER_HEADLESS=1 WORKER_CHECK_RETRY=0 WORKER_CHECK_HEARTBEAT=1 \
    WORKER_CHECK_CMD="echo ran >> '$RAN'" "$LISTENER" bash > listener.log 2>&1 ) &
LISTENER_PIDS+=($!)
sleep 0.5
cd "$WT"

heading "Test 1: no change → check skipped, check_exit skipped_no_change"
drop_v2 s1 'true'
wait_for "s1 outcome" '[ -f .swarm/tasks/done/s1.ok.json ]'
[ ! -e "$RAN" ] || red "s1: check ran despite no change"
jq -e '.outcome == "ok" and .check_exit == "skipped_no_change" and .verification == "not-run"' \
    .swarm/tasks/done/s1.ok.json >/dev/null || { cat .swarm/tasks/done/s1.ok.json; red "s1 outcome wrong"; }
grep -q 'Acceptance check SKIPPED (skipped_no_change)' listener.log || red "s1: no skip line in the pane"
green "clean tree + same HEAD → skipped, outcome records skipped_no_change"

heading "Test 2: edited tracked file → check runs as before"
drop_v2 s2 'echo edit >> tracked.txt'
wait_for "s2 outcome" '[ -f .swarm/tasks/done/s2.ok.json ]'
[ -e "$RAN" ] || red "s2: check did not run after an edit"
jq -e '.check_exit == 0' .swarm/tasks/done/s2.ok.json >/dev/null || red "s2: check_exit should be 0"
green "edit → check ran, check_exit 0"
git checkout -q -- tracked.txt
rm -f "$RAN"

heading "Test 3: new commit, clean tree → check runs"
drop_v2 s3 'echo more >> tracked.txt; git add tracked.txt; git -c user.name=t -c user.email=t@t commit -q -m s3'
wait_for "s3 outcome" '[ -f .swarm/tasks/done/s3.ok.json ]'
[ -e "$RAN" ] || red "s3: check did not run after a new commit"
jq -e '.check_exit == 0' .swarm/tasks/done/s3.ok.json >/dev/null || red "s3: check_exit should be 0"
green "new commit → check ran"
rm -f "$RAN"

heading "Test 4: untracked new file → check runs"
drop_v2 s4 'echo x > brand-new.txt'
wait_for "s4 outcome" '[ -f .swarm/tasks/done/s4.ok.json ]'
[ -e "$RAN" ] || red "s4: check did not run with an untracked file"
green "untracked file counts as a change"
rm -f brand-new.txt "$RAN"
git checkout -q -- . 2>/dev/null || true

heading "Test 5: eval log + scoreboard tolerate the string check_exit"
jq -es 'map(select(.task_id == "s1")) | .[0].check_exit == "skipped_no_change"' .swarm/eval-log.jsonl >/dev/null \
    || { cat .swarm/eval-log.jsonl; red "s1 eval row should carry skipped_no_change"; }
"$SCOREBOARD" --json .swarm/eval-log.jsonl | jq -e '.[0].unchecked == 1 and .[0].checked == 3' >/dev/null \
    || { "$SCOREBOARD" --json .swarm/eval-log.jsonl; red "scoreboard should count the skipped row as unchecked"; }
green "eval row + scoreboard handle skipped_no_change (unchecked=1)"

heading "Test 6: a slow check prints its command, timeout and a heartbeat"
rm -f "$RAN"
drop_v2 s6 'echo edit6 > t6.txt
# <!-- SWARM_CHECK: echo working-line; sleep 3 -->'
wait_for "s6 outcome" '[ -f .swarm/tasks/done/s6.ok.json ]'
grep -q 'timeout 600s, full log:' listener.log || red "s6: missing start/timeout line"
grep -q 'check still running (.*working-line' listener.log || red "s6: missing heartbeat with the log's last line: $(tail -20 listener.log)"
green "start line + heartbeat shown while the check runs"

green "ALL TESTS PASSED"
