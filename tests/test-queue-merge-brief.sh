#!/usr/bin/env bash
#
# test-queue-merge-brief.sh — issue #841: the operator's `merge PR N red` typed
# in the coordinator reaches a worker that is on hold. Replays the
# corpusminder-spring #2113 incident: worker for issue 2108 sidelined, PR 2113
# rated 🔴. Covers scripts/queue-merge-brief.sh (real requeue.sh, stub gh/tmux),
# the queued brief's command run through the real worker-merge.sh (merges at the
# approved head; refuses once the head moved) and the lint rule that flags a
# Needs-you item sending the operator to the window of a worker on hold.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }
check()   { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QMB="$ROOT/scripts/queue-merge-brief.sh"
WM="$ROOT/scripts/worker-merge.sh"
LINT="$ROOT/scripts/lint-coordinator-reply.sh"
FX="$ROOT/tests/fixtures/reply-lint"
T="$(mktemp -d -t queue-merge-brief-XXXXXX)"
trap 'rm -rf "$T"' EXIT
export SWARM_WORKTREE_GROUPING=flat

HEAD_A=aaaaaaa1111111111111111111111111111aaaaa
HEAD_B=bbbbbbb2222222222222222222222222222bbbbb
mkdir -p "$T/bin" "$T/proj/.swarm"
git -C "$T/proj" init -q -b master
git -C "$T/proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$T/proj" worktree add -q -b fix/issue-2108 "$T/wt-issue-2108" master
WT="$T/wt-issue-2108"
mkdir -p "$WT/.swarm/tasks"/{inbox,processing,done,status,outbox}
printf 'sidelined_at=20261110T145400Z\nreason=finished\n' > "$WT/.swarm/sidelined"
printf '{"task_id":"x","state":"ready-for-review","pr":2113,"ts":"2026-11-10T14:00:00Z"}\n' > "$WT/.swarm/tasks/status/x.json"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
    "pr view")
        case "$*" in
            *"--json state,isDraft,headRefName"*)
                jq -cn --arg s "${GH_STATE:-OPEN}" --argjson d "${GH_DRAFT:-false}" --arg h "$GH_HEAD" --arg r "${GH_RISK:-high}" \
                    '{state:$s,isDraft:$d,headRefName:"fix/issue-2108",headRefOid:$h,title:"Needs-you store",body:("<!-- BLIND_MERGE_RISK: "+$r+" -->\nbody")}' ;;
            *"--json state "*)       echo OPEN ;;
            *"--json isDraft "*)     echo false ;;
            *"--json mergeable "*)   echo MERGEABLE ;;
            *"--json baseRefName "*) echo master ;;
            *"--json headRefOid "*)  echo "$GH_HEAD" ;;
            *"--json body "*)        printf '<!-- BLIND_MERGE_RISK: %s -->\n' "${GH_RISK:-high}" ;;
            *"--json comments "*)    echo APPROVE ;;
        esac ;;
    "repo view") echo master ;;
    "pr merge"|"pr comment") exit 0 ;;
    *) exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/ok"
printf '#!/usr/bin/env bash\necho "%s"\n' "$WT" > "$T/list-wt"
chmod +x "$T/bin/gh" "$T/bin/tmux" "$T/ok" "$T/list-wt"
export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_HEAD="$HEAD_A"
export CI_WAIT_SCRIPT="$T/ok" MIGRATION_CHECK_SCRIPT="$T/ok" LIST_WORKTREES_SCRIPT="$T/list-wt"
: > "$GH_LOG"

q() { "$QMB" "$@" --project "$T/proj" >"$T/out" 2>&1; }
inbox_n() { find "$WT/.swarm/tasks/inbox" -name '*.md' | wc -l; }

heading "queue-merge-brief.sh: gates"
set +e
GH_RISK=medium q 2113 --rating high; ec=$?
check "PR not rated high -> refused (2), nothing queued" "2 0" "$ec $(inbox_n)"
GH_DRAFT=true q 2113 --rating high; ec=$?
check "draft PR -> refused (2), nothing queued" "2 0" "$ec $(inbox_n)"
GH_STATE=MERGED q 2113 --rating high; ec=$?
check "merged PR -> refused (2), nothing queued" "2 0" "$ec $(inbox_n)"
q 2113 --rating high --expect-head bbbbbbb; ec=$?
check "--expect-head that is not the head -> refused (2), nothing queued" "2 0" "$ec $(inbox_n)"
q 2113 --rating urgent; ec=$?
check "bad rating is a usage error (1)" "1" "$ec"
LIST_WORKTREES_SCRIPT=/bin/true q 2113 --rating high; ec=$?
check "no worktree owns the branch -> refused (2)" "2" "$ec"
set -e

heading "queue-merge-brief.sh: the #2113 replay (worker on hold)"
q 2113 --rating high || red "queue failed: $(cat "$T/out")"
check "one brief lands in the sidelined worker's inbox" "1" "$(inbox_n)"
B="$(find "$WT/.swarm/tasks/inbox" -name '*.md' | head -1)"
grep -q "SWARM_MERGE_APPROVAL: pr=2113 rating=high head=aaaaaaa11111" "$B" || red "brief lacks the approval marker: $(cat "$B")"
green "brief carries the marker with PR, rating and the head read at typing time"
CMD="$(grep -m1 'worker-merge.sh' "$B")"
case "$CMD" in *"worker-merge.sh 2113 --expect-head aaaaaaa11111 --rating high"*) green "brief carries the exact worker-merge.sh command" ;; *) red "unexpected command: $CMD" ;; esac
grep -q "merge.queued  *pr=2113 rating=high head=aaaaaaa11111" "$T/proj/.swarm/events.log" && green "merge.queued logged" || red "no merge.queued event"
[ -e "$WT/.swarm/sidelined" ] && green "marker untouched: the watcher's wake pass (sideline_wake_pass) owns the wake" || red "marker vanished"

heading "the queued command, run by the woken worker"
run_cmd() { LLM_SWARM_DIR="$ROOT" bash -c "${CMD//\$LLM_SWARM_DIR/$ROOT}" >"$T/wm.out" 2>&1; }
: > "$GH_LOG"
run_cmd && grep -q "pr merge 2113 --squash --match-head-commit $HEAD_A" "$GH_LOG" \
    && green "head unchanged: worker-merge.sh merges at the approved head" || red "did not merge: $(cat "$T/wm.out")"
: > "$GH_LOG"
GH_HEAD="$HEAD_B"
set +e; run_cmd; ec=$?; set -e
if [ "$ec" = 2 ] && ! grep -q "pr merge" "$GH_LOG"; then green "a push after the phrase (head moved) -> refused, nothing merged"; else red "moved head not refused (exit $ec): $(cat "$T/wm.out")"; fi
GH_HEAD="$HEAD_A"

heading "lint: stale 'in its worker window' item (Do 4)"
check "the 15:56Z coordinator item is flagged" "stale-window" "$("$LINT" --project "$T/proj" < "$FX/incident-stale-window.txt" | cut -d: -f1 | sort -u | paste -sd, -)"
mv "$WT/.swarm/sidelined" "$T/marker"
check "same words, worker NOT on hold: clean" "" "$("$LINT" --project "$T/proj" < "$FX/incident-stale-window.txt" | cut -d: -f1 | paste -sd, -)"
mv "$T/marker" "$WT/.swarm/sidelined"
check "corrected wording (type it in the coordinator) is clean" "" "$("$LINT" --project "$T/proj" < "$FX/clean-merge-in-coordinator.txt" | cut -d: -f1 | paste -sd, -)"
check "no --project: rule is skipped, not guessed" "" "$("$LINT" < "$FX/incident-stale-window.txt" | grep stale-window | cut -d: -f1 | paste -sd, -)"
check "iss-N named directly also resolves" "stale-window" "$(printf -- '- **A1** Type `merge PR 9 red` in its iss-2108 pane.\n' | "$LINT" --project "$T/proj" | cut -d: -f1 | paste -sd, -)"
echo "all queue-merge-brief checks passed"
