#!/usr/bin/env bash
#
# swarm-scoreboard.sh — Aggregate eval-log rows into a per-(agent, model)
# scoreboard.
#
# Eval-loop concept adopted from Nate B. Jones's ringer (its JSONL model log
# and `./ringer.py models` scoreboard, incl. the first_try_pass_rate metric).
# Original bash/jq implementation, no code copied — attribution and pointers
# in docs/ringer-adoptions.md #3.
#
# Rows come from worker-listener.sh, which appends one JSONL line per
# completed v2 task to .swarm/eval-log.jsonl in the worktree (or to
# $SWARM_EVAL_LOG). This script pools rows and answers: which (agent, model)
# combos actually pass their executed checks, how often on the first try,
# and how long they take. That makes model-default choices (e.g. "Sonnet 5
# for workers") empirically checkable instead of vibes.
#
# Usage:
#   swarm-scoreboard.sh [--json] [file-or-dir ...]
#
#   file args  — read as JSONL eval logs
#   dir args   — glob <dir>/.swarm/eval-log.jsonl plus sibling worktrees
#                <dir>/../wt-issue-*/.swarm/eval-log.jsonl
#   no args    — same globbing from the current directory
#   --json     — emit the aggregated groups as JSON instead of a table
#
# Columns:
#   tasks     rows for the group
#   pass      outcome == "ok" (agent exit 0 AND executed check passed)
#   pass%     pass / tasks
#   1st-try%  passed without the retry-once kicking in
#   retries   rows where the retry fired
#   checked   rows that had an executed check at all
#   avg-s     mean duration_seconds
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "swarm-scoreboard.sh: jq required" >&2; exit 1; }

JSON_OUT=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --json) JSON_OUT=1 ;;
        -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done
[ ${#ARGS[@]} -eq 0 ] && ARGS=(.)

# Collect log files from file/dir args
LOGS=()
for a in "${ARGS[@]}"; do
    if [ -f "$a" ]; then
        LOGS+=("$a")
    elif [ -d "$a" ]; then
        for f in "$a/.swarm/eval-log.jsonl" "$a"/../wt-issue-*/.swarm/eval-log.jsonl; do
            [ -f "$f" ] && LOGS+=("$f")
        done
    else
        echo "swarm-scoreboard.sh: no such file or dir: $a" >&2
    fi
done

if [ ${#LOGS[@]} -eq 0 ]; then
    echo "No eval logs found. Workers write .swarm/eval-log.jsonl per worktree" >&2
    echo "(or \$SWARM_EVAL_LOG). Pass files or project/worktree dirs as args." >&2
    exit 1
fi

AGG=$(cat "${LOGS[@]}" | jq -s '
    map(select(type == "object"))
    | group_by([.agent, .model])
    | map({
        agent: .[0].agent,
        model: (.[0].model // "-"),
        tasks: length,
        pass: (map(select(.outcome == "ok")) | length),
        pass_rate: ((map(select(.outcome == "ok")) | length) / length),
        first_try_pass_rate:
            ((map(select(.outcome == "ok" and (.retried | not))) | length) / length),
        retries: (map(select(.retried)) | length),
        checked: (map(select(.check_exit != null)) | length),
        avg_duration_s: ((map(.duration_seconds) | add / length) * 10 | round / 10)
      })
    | sort_by(-.first_try_pass_rate, -.tasks)')

if [ "$JSON_OUT" = "1" ]; then
    printf '%s\n' "$AGG"
    exit 0
fi

echo "Eval logs: ${#LOGS[@]} file(s), $(cat "${LOGS[@]}" | wc -l) row(s)"
echo ""
{
    echo "AGENT|MODEL|TASKS|PASS|PASS%|1ST-TRY%|RETRIES|CHECKED|AVG-S"
    printf '%s\n' "$AGG" | jq -r '.[] |
        [.agent, .model, .tasks, .pass,
         ((.pass_rate * 100) | round | tostring) + "%",
         ((.first_try_pass_rate * 100) | round | tostring) + "%",
         .retries, .checked, .avg_duration_s]
        | join("|")'
} | column -t -s'|'
