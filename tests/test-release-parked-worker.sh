#!/usr/bin/env bash
#
# test-release-parked-worker.sh — scripts/release-parked-worker.sh (issue #1025).
# Real tmux session + real git worktree; provision-worker.sh is stubbed.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (want '$2', got '$3')"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL="$SCRIPT_DIR/../scripts/release-parked-worker.sh"
command -v tmux >/dev/null || red "tmux required"

T="$(mktemp -d -t release-parked-XXXXXX)"
MAIN="$T/proj"
SESSION="llm-proj"
cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

git init -q "$MAIN" && git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q --bare "$MAIN" "$T/origin.git"
git -C "$MAIN" remote add origin "$T/origin.git"
git -C "$MAIN" fetch -q origin
WT="$T/wt-issue-7"
git -C "$MAIN" worktree add -q -b fix/7 "$WT" HEAD
git -C "$WT" branch -q --set-upstream-to=origin/master 2>/dev/null || true
git -C "$MAIN" push -q origin fix/7 2>/dev/null || true
git -C "$WT" fetch -q origin
for d in inbox processing done; do mkdir -p "$WT/.swarm/tasks/$d"; done
printf '.swarm/\n' >> "$(git -C "$WT" rev-parse --git-common-dir)/info/exclude"

STUB="$T/provision.sh"
printf '#!/usr/bin/env bash\necho "$@" > "%s/wake.args"\nrm -f "%s/.swarm/sidelined"\n' "$T" "$WT" > "$STUB"
chmod +x "$STUB"

# A window running a non-shell process (sleep) stands in for the parked agent.
tmux new-session -d -s "$SESSION" -n keep "sleep 600"; tmux new-window -d -t "$SESSION" -n iss-7 "sleep 600"
export PROVISION_WORKER="$STUB"

reset() {
    rm -f "$WT/.swarm/tasks/inbox"/* "$WT/.swarm/tasks/processing"/* "$WT/.swarm/tasks/done"/* "$T/wake.args" "$WT/.swarm/sidelined"
    tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -n keep "sleep 600"
    tmux list-windows -t "$SESSION" -F '#W' | grep -qx iss-7 || tmux new-window -d -t "$SESSION" -n iss-7 "sleep 600"
    echo '{}' > "$WT/.swarm/tasks/done/old.ok.json"
    echo brief > "$WT/.swarm/tasks/inbox/new.md"
}
run() { local rc=0; "$REL" "$WT" "$@" >"$T/out" 2>&1 || rc=$?; echo "$rc"; }

reset
check "dry-run on a finished parked worker exits 0" 0 "$(run --dry-run)"
check "dry-run touches nothing" "no" "$([ -e "$T/wake.args" ] && echo yes || echo no)"

reset
rm "$WT/.swarm/tasks/inbox/new.md"
check "no queued brief: refused" 1 "$(run)"; grep -q "no brief waiting" "$T/out" || red "wrong refusal reason"

reset
echo x > "$WT/.swarm/tasks/processing/cur.md"
check "task still in processing/: refused" 1 "$(run)"; grep -q "still claimed" "$T/out" || red "wrong refusal reason"

reset
rm "$WT/.swarm/tasks/done/old.ok.json"
check "no done/ outcome: refused" 1 "$(run)"; grep -q "no done/ outcome" "$T/out" || red "wrong refusal reason"

reset
echo dirty > "$WT/dirty.txt"
check "dirty worktree: refused" 1 "$(run)"; grep -q "uncommitted" "$T/out" || red "wrong refusal reason"
rm -f "$WT/dirty.txt"

reset
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unpushed
check "unpushed commit: refused" 1 "$(run)"; grep -q "unpushed" "$T/out" || red "wrong refusal reason"
git -C "$WT" reset -q --hard HEAD~1

reset
tmux kill-window -t "$SESSION:iss-7"; tmux new-window -d -t "$SESSION" -n iss-7 "bash -c 'echo \"(esc to interrupt)\"; sleep 600'"
sleep 0.5
check "busy marker on pane: refused" 1 "$(run)"; grep -q "busy marker" "$T/out" || red "wrong refusal reason"
tmux kill-window -t "$SESSION:iss-7"

reset
check "finished + clean + pushed: released" 0 "$(run)"
check "provision-worker --wake called for the issue" "--wake 7 $MAIN" "$(cat "$T/wake.args")"
check "old window killed (stub does not respawn it)" "no" "$(tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx iss-7 && echo yes || echo no)"
echo "all release-parked-worker checks passed"
