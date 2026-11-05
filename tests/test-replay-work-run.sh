#!/usr/bin/env bash
# test-replay-work-run.sh — issue #768 (ADR 0006 section 9 step A5):
# scripts/replay-work-run.sh must never let a replayed run reach GitHub or a
# live swarm, and must serve PR/issue reads from the as-of fixtures.
#
# No claude, no network: the "run" is a shell command passed with --cmd, and
# GH_TOKEN is set to a canary that must not reach it.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLAY="$ROOT/scripts/replay-work-run.sh"
RESIDENT="$ROOT/scripts/replay-resident-actions.sh"
command -v jq >/dev/null || { echo "jq missing; skipping"; exit 0; }

T="$(mktemp -d -t replay-test-XXXXXX)"
trap 'rm -rf "$T"' EXIT
export GH_TOKEN=canary-must-not-leak GITHUB_TOKEN=canary-must-not-leak

# fixtures: one open PR (as-of state) and one issue
mkdir -p "$T/fix" "$T/src"
jq -n '{number:7,title:"fix thing",state:"OPEN",isDraft:false,headRefOid:"abc1234",body:"b",
        statusCheckRollup:[{name:"build",conclusion:"SUCCESS",status:"COMPLETED"}]}' > "$T/fix/pr-7.json"
jq -n '{number:3,title:"an issue",state:"OPEN",labels:[],comments:[]}' > "$T/fix/issue-3.json"
echo '[{"number":7,"title":"fix thing","state":"OPEN","isDraft":false}]' > "$T/fix/pr-list.json"
echo '[{"number":3,"title":"an issue","state":"OPEN","labels":[],"assignees":[]}]' > "$T/fix/issue-list.json"
printf 'Worker(s) just finished.\n\nTriggering outcome: issue=3 outcome=ok path=/mnt/wd1t/worktrees/x-worktrees/wt-issue-3/.swarm/tasks/done/20260101-000000-3.ok.json\n' \
    > "$T/src/20260101T000000Z-outcome-1-1.md"

heading "reads come from fixtures, writes are recorded and not sent"
CMD='
set -u
echo "gh=$(command -v gh)" > "$PWD/probe.txt"
echo "token=${GH_TOKEN:-unset}${GITHUB_TOKEN:-}" >> "$PWD/probe.txt"
echo "state=$(gh pr view 7 --json state -q .state)" >> "$PWD/probe.txt"
echo "open=$(gh pr list --state open --json number -q length)" >> "$PWD/probe.txt"
gh pr comment 7 --body "hello"
gh pr merge 7 --squash
gh issue create --title t --body b > /dev/null
$LLM_SWARM_DIR/scripts/swarm-merge.sh 7 --auto-low
$LLM_SWARM_DIR/scripts/requeue.sh 3 /dev/null
tmux kill-window -t llm-x:iss-3
echo "docker_ps=$(docker ps -q | wc -l) docker_bin=$(command -v docker)" >> "$PWD/probe.txt"
docker stop swarm-live-worker
echo "outcome=$(jq -r .outcome /mnt/none 2>/dev/null; ls .swarm/coord-inbox | wc -l)" >> "$PWD/probe.txt"
'
"$REPLAY" --out "$T/out" --fixtures "$T/fix" --inbox-src "$T/src" --files 20261231T000000Z-none.md --cmd "$CMD" >/dev/null 2>&1 \
    && red "missing inbox file must fail" || green "missing inbox file is refused"
rm -rf "$T/out"
"$REPLAY" --out "$T/out" --fixtures "$T/fix" --inbox-src "$T/src" --files 20260101T000000Z-outcome-1-1.md \
    --cmd "$CMD" --project-kind synthetic --windows "coordinator util iss-3" >/dev/null 2>&1 || true
P="$T/out/project"
check "gh resolves to the stub" "$T/out/bin/gh" "$(sed -n 's/^gh=//p' "$P/probe.txt")"
check "no GitHub token reaches the run" "token=unset" "$(sed -n 's/^token=//p;' "$P/probe.txt" | sed 's/^/token=/')"
check "pr view served from fixture" "state=OPEN" "$(grep '^state=' "$P/probe.txt")"
check "pr list served from fixture" "open=1" "$(grep '^open=' "$P/probe.txt")"
A="$T/out/actions.tsv"
check "pr comment recorded" "1" "$(grep -c $'\tgh\tpr comment 7' "$A")"
check "pr merge recorded" "1" "$(grep -c $'\tgh\tpr merge 7' "$A")"
check "issue create recorded" "1" "$(grep -c $'\tgh\tissue create' "$A")"
check "swarm-merge recorded, not run" "1" "$(grep -c $'\tswarm-merge.sh\t7 --auto-low' "$A")"
check "requeue recorded, not run" "1" "$(grep -c $'\trequeue.sh\t3' "$A")"
check "tmux kill-window recorded" "1" "$(grep -c $'\ttmux\tkill-window' "$A")"
check "docker ps sees an empty host, via the stub" "docker_ps=0 docker_bin=$T/out/bin/docker" "$(grep '^docker_ps=' "$P/probe.txt")"
check "docker stop recorded, not sent" "1" "$(grep -c $'\tdocker\tstop swarm-live-worker' "$A")"

heading "inbox copy has host paths rewritten and an outcome stand-in"
check "inbox item copied" "1" "$(ls "$P"/.swarm/coord-inbox/*.md | wc -l)"
grep -q "$T/out/worktrees" "$P"/.swarm/coord-inbox/*.md && green "worktree path rewritten into the replay tree" || red "path not rewritten"
check "outcome stand-in written at the rewritten path" "ok" "$(jq -r .outcome "$T/out/worktrees/wt-issue-3/.swarm/tasks/done/20260101-000000-3.ok.json")"
check "project has no git remote" "0" "$(git -C "$P" remote | wc -l)"

heading "reuse of an output dir is refused"
"$REPLAY" --out "$T/out" --fixtures "$T/fix" --inbox-src "$T/src" --files 20260101T000000Z-outcome-1-1.md --cmd true >/dev/null 2>&1 \
    && red "reuse must fail" || green "existing project/ is not overwritten"

heading "resident-action extractor reads a transcript"
cat > "$T/t.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-11-01T19:12:42.000Z","message":{"content":"Inbox: 1 item(s) in .swarm/coord-inbox/ — read and triage them"}}
{"type":"assistant","timestamp":"2026-11-01T19:12:50.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat .swarm/coord-inbox/20261101T191201Z-outcome-1-1.md; gh pr merge 5 --squash"}}]}}
{"type":"assistant","timestamp":"2026-11-01T19:12:55.000Z","message":{"content":[{"type":"text","text":"Merged PR 5.\nmore"}]}}
EOF
OUTX="$("$RESIDENT" "$T/t.jsonl")"
check "wake row" "1" "$(printf '%s\n' "$OUTX" | grep -c $'\twake\t')"
check "read row names the inbox file" "1" "$(printf '%s\n' "$OUTX" | grep -c $'\tread\t20261101T191201Z-outcome-1-1.md')"
check "act row for the merge" "1" "$(printf '%s\n' "$OUTX" | grep -c $'\tact\t.*gh pr merge 5')"
check "say row is the first line only" "Merged PR 5." "$(printf '%s\n' "$OUTX" | awk -F'\t' '$2=="say"{print $3}')"

printf '\n\033[1;32mAll replay-work-run tests passed.\033[0m\n'
