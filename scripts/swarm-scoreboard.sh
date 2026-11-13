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
#   dir args   — <dir>/.swarm/eval-log.jsonl plus <dir>'s OWN worktrees,
#                resolved via swarm_own_worktree_dirs() (issue #357 —
#                `git worktree list` against <dir>'s own repo, not a
#                name-glob under a shared parent dir a sibling project's
#                swarm can also populate under flat grouping):
#                <own-worktree>/.swarm/eval-log.jsonl
#   no args    — same scoping from the current directory
#   --json     — emit the aggregated groups as JSON instead of a table
#   --wakes    — instead of the eval scoreboard, count coordinator wakes per
#                day from events.log (file args are events.log files; dir args
#                use <dir>/.swarm/events.log). Counts coord.wake (typed
#                doorbell), coord.wake.waiter_rang and coord.wake.hook_rang,
#                the same set docs/quiet-wakes.md uses; items/urgent/batched
#                sum the ring lines' counters. Quiet vs full replies are NOT
#                derivable: no event records which reply form the coordinator
#                chose (issue #738), so the output says so.
#   --night [YYYY-MM-DD]
#                per-hour row for one night (00:00-09:00 LOCAL, per $TZ) from
#                events.log: PRs created, worker starts, wakes delivered, wakes
#                skipped by reason (ADR-0008 D8, issue #900). Default night is
#                the most recent one whose 09:00 has passed. First line is a
#                CANARY when any hour has non-inbox_empty wake skips > 0 and
#                wakes delivered = 0 (skips other than inbox_empty mean the
#                inbox was non-empty: the Oct-14 dropped-wake pattern).
#                "PRs created" = distinct pr=N values first seen that hour
#                (events.log has no pr.created event; this is a proxy). Reads
#                only the swarm's own events.log. --json emits the rows.
#
# Columns:
#   tasks     rows for the group
#   pass      outcome == "ok" AND check_exit == 0 (not explicitly blocked)
#   pass%     pass / tasks
#   1st-try%  passed without the retry-once kicking in
#   retries   rows where the retry fired
#   checked   rows that had an executed check at all
#   unchecked rows with no executed check (never counted as passes)
#   avg-s     mean duration_seconds
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "swarm-scoreboard.sh: jq required" >&2; exit 1; }

JSON_OUT=0
WAKES=0
NIGHT=0
NIGHT_DATE=""
ARGS=()
while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
        --json) JSON_OUT=1 ;;
        --wakes) WAKES=1 ;;
        --night) NIGHT=1
                 # optional YYYY-MM-DD operand (local date of the night)
                 if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then NIGHT_DATE="$1"; shift; fi ;;
        -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done
[ ${#ARGS[@]} -eq 0 ] && ARGS=(.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the env loader to get swarm_own_worktree_dirs() (issue #357),
# scoped via `git worktree list` against each dir arg's own repo.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "${ARGS[0]}"

if [ "$NIGHT" = "1" ]; then
    EVENT_LOGS=()
    for a in "${ARGS[@]}"; do
        if [ -f "$a" ]; then EVENT_LOGS+=("$a")
        elif [ -d "$a" ] && [ -f "$a/.swarm/events.log" ]; then EVENT_LOGS+=("$a/.swarm/events.log")
        else echo "swarm-scoreboard.sh: no events.log at: $a" >&2; fi
    done
    [ ${#EVENT_LOGS[@]} -gt 0 ] || { echo "No events.log found." >&2; exit 1; }
    if [ -z "$NIGHT_DATE" ]; then
        if [ "$(date +%-H)" -ge 9 ]; then NIGHT_DATE=$(date +%F); else NIGHT_DATE=$(date -d yesterday +%F); fi
    fi
    # Line shape: "<ISO-UTC-ts>  <event> [k=v ...]". Bucket by local hour.
    NIGHT_AGG=$(cat "${EVENT_LOGS[@]}" | jq -R -s --arg night "$NIGHT_DATE" '
        [split("\n")[]
         | capture("^(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8})Z\\s+(?<ev>\\S+)(?:\\s+(?<rest>.*))?$")
         | .rest = (.rest // "")
         | (.ts + "Z" | fromdateiso8601 | localtime | strftime("%Y-%m-%d %H")) as $lh
         | select(($lh | .[0:10]) == $night and (($lh | .[11:13] | tonumber) < 9))
         | .hour = ($lh | .[11:13] | tonumber)
         | .pr = ((.rest | capture("(?:^| )pr=(?<n>[0-9]+)") | .n) // null)
         | .reason = ((.rest | capture("(?:^| )reason=(?<r>[A-Za-z0-9_]+)") | .r) // "unknown")] as $evs
        | ([$evs[] | select(.pr != null) | {pr, hour}] | group_by(.pr) | map(min_by(.hour))) as $firstpr
        | [range(0; 9) as $h
           | ($evs | map(select(.hour == $h))) as $e
           | {hour: $h,
              prs: ($firstpr | map(select(.hour == $h)) | length),
              starts: ($e | map(select(.ev == "worker.start")) | length),
              delivered: ($e | map(select(.ev == "coord.wake" or .ev == "coord.wake.waiter_rang" or .ev == "coord.wake.hook_rang")) | length),
              skipped: ($e | map(select(.ev == "coord.wake.skip")) | group_by(.reason) | map({key: .[0].reason, value: length}) | from_entries)}
           | .skipped_total = ([.skipped[]] | add // 0)
           | .skipped_inbox = (.skipped_total - (.skipped.inbox_empty // 0))
           | .canary = (.skipped_inbox > 0 and .delivered == 0)]')
    CANARY_HOURS=$(printf '%s\n' "$NIGHT_AGG" | jq -r '[.[] | select(.canary) | "0\(.hour):00"] | join(", ")')
    if [ "$JSON_OUT" = "1" ]; then
        printf '%s\n' "$NIGHT_AGG" | jq --arg n "$NIGHT_DATE" '{night: $n, canary: (map(.canary) | any), hours: .}'
        exit 0
    fi
    if [ -n "$CANARY_HOURS" ]; then
        echo "CANARY: dropped wakes on $NIGHT_DATE in hour(s) $CANARY_HOURS (skips > 0, 0 delivered, inbox non-empty): ADR-0008 F2 pattern"
    else
        echo "Canary: clear for night $NIGHT_DATE (no hour with wake skips and 0 wakes delivered)"
    fi
    echo ""
    {
        echo "HOUR|PRS|STARTS|WAKES|SKIPPED|SKIP-REASONS"
        printf '%s\n' "$NIGHT_AGG" | jq -r '.[] |
            [(("0" + (.hour | tostring))[-2:] + ":00"), .prs, .starts, .delivered, .skipped_total,
             (if .skipped_total == 0 then "-" else (.skipped | to_entries | map("\(.key)=\(.value)") | join(" ")) end)]
            | join("|")'
    } | column -t -s'|'
    echo ""
    echo "Local night 00:00-09:00 (TZ=${TZ:-system}). PRS = distinct pr=N first seen that hour (proxy: no pr.created event)."
    exit 0
fi

if [ "$WAKES" = "1" ]; then
    EVENT_LOGS=()
    for a in "${ARGS[@]}"; do
        if [ -f "$a" ]; then
            EVENT_LOGS+=("$a")
        elif [ -d "$a" ]; then
            [ -f "$a/.swarm/events.log" ] && EVENT_LOGS+=("$a/.swarm/events.log")
        else
            echo "swarm-scoreboard.sh: no such file or dir: $a" >&2
        fi
    done
    if [ ${#EVENT_LOGS[@]} -eq 0 ]; then
        echo "No events.log found. Pass events.log files or project dirs as args." >&2
        exit 1
    fi
    # Line shape: "<ISO-ts>  <event> [k=v ...]" (log_event in coord-hook.sh).
    WAKE_AGG=$(cat "${EVENT_LOGS[@]}" | jq -R -s '
        def kv($k): (capture("(?:^| )" + $k + "=(?<v>[0-9]+)") | .v | tonumber) // 0;
        [split("\n")[]
         | capture("^(?<day>[0-9]{4}-[0-9]{2}-[0-9]{2})T\\S+\\s+(?<ev>coord\\.wake(?:\\.waiter_rang|\\.hook_rang)?)(?:\\s+(?<rest>.*))?$")
         | .rest = (.rest // "")]
        | group_by(.day)
        | map({
            day: .[0].day,
            wakes: length,
            typed: (map(select(.ev == "coord.wake")) | length),
            waiter: (map(select(.ev == "coord.wake.waiter_rang")) | length),
            hook: (map(select(.ev == "coord.wake.hook_rang")) | length),
            items: (map(.rest | kv("items")) | add),
            urgent: (map(.rest | kv("urgent")) | add),
            batched: (map(.rest | kv("batched")) | add)
          })')
    if [ "$JSON_OUT" = "1" ]; then
        printf '%s\n' "$WAKE_AGG" | jq '{days: ., total_wakes: (map(.wakes) | add // 0),
            quiet_vs_full: "not derivable: no events.log line records which reply form the coordinator used"}'
        exit 0
    fi
    echo "Events logs: ${#EVENT_LOGS[@]} file(s)"
    echo ""
    {
        echo "DAY|WAKES|TYPED|WAITER|HOOK|ITEMS|URGENT|BATCHED"
        printf '%s\n' "$WAKE_AGG" | jq -r '.[] |
            [.day, .wakes, .typed, .waiter, .hook, .items, .urgent, .batched] | join("|")'
        printf '%s\n' "$WAKE_AGG" | jq -r '"TOTAL|\(map(.wakes) | add // 0)|\(map(.typed) | add // 0)|\(map(.waiter) | add // 0)|\(map(.hook) | add // 0)|\(map(.items) | add // 0)|\(map(.urgent) | add // 0)|\(map(.batched) | add // 0)"'
    } | column -t -s'|'
    echo ""
    echo "Quiet vs full replies: not derivable from events.log. The coordinator's reply"
    echo "form (one-line 'Handled N items' vs full write-up) is never logged; only the"
    echo "ring is. URGENT/BATCHED above are the nearest proxy (urgent items always get"
    echo "a full reply; batched ones may be quiet). See docs/quiet-wakes.md."
    exit 0
fi

# Collect log files from file/dir args
LOGS=()
for a in "${ARGS[@]}"; do
    if [ -f "$a" ]; then
        LOGS+=("$a")
    elif [ -d "$a" ]; then
        [ -f "$a/.swarm/eval-log.jsonl" ] && LOGS+=("$a/.swarm/eval-log.jsonl")
        while IFS= read -r wt; do
            [ -n "$wt" ] || continue
            [ -f "$wt/.swarm/eval-log.jsonl" ] && LOGS+=("$wt/.swarm/eval-log.jsonl")
        done < <(swarm_own_worktree_dirs "$a")
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
    def passed: .outcome == "ok" and .check_exit == 0 and .task_state != "blocked";
    map(select(type == "object"))
    | group_by([.agent, .model])
    | map({
        agent: .[0].agent,
        model: (.[0].model // "-"),
        tasks: length,
        pass: (map(select(passed)) | length),
        pass_rate: ((map(select(passed)) | length) / length),
        first_try_pass_rate:
            ((map(select(passed and (.retried | not))) | length) / length),
        retries: (map(select(.retried)) | length),
        checked: (map(select((.check_exit | type) == "number")) | length),
        unchecked: (map(select((.check_exit | type) != "number")) | length),
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
    echo "AGENT|MODEL|TASKS|PASS|PASS%|1ST-TRY%|RETRIES|CHECKED|UNCHECKED|AVG-S"
    printf '%s\n' "$AGG" | jq -r '.[] |
        [.agent, .model, .tasks, .pass,
         ((.pass_rate * 100) | round | tostring) + "%",
         ((.first_try_pass_rate * 100) | round | tostring) + "%",
         .retries, .checked, .unchecked, .avg_duration_s]
        | join("|")'
} | column -t -s'|'
