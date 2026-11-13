#!/usr/bin/env bash
#
# ci-runner-health.sh — flag a self-hosted GitHub Actions runner that is
# offline while jobs queue, and report queue wait per repo (issue #899,
# ADR 0007: deterministic checks first). Read-only: only `gh api` GETs.
#
# Usage:
#   ci-runner-health.sh [repo…]            check (owner/name; default: $CI_HEALTH_REPOS,
#                                          else the current directory's repo)
#   ci-runner-health.sh --report [days] [repo…]
#                                          queue wait (median, 1-in-10) per repo
#                                          over the last <days> (default 7)
#
# Check output: JSON lines in the docs/checks.md format (+ extra fields
# repo, runner, queued_mins), nothing when healthy.
#   runner-offline-with-queue (error)  a runner is offline and a self-hosted job
#                                      has been queued > CI_HEALTH_QUEUE_MINS
#   queue-long (warn)                  a job queued > CI_HEALTH_QUEUE_MINS while every
#                                      runner is online and busy: needs more capacity
#   runner-offline (warn)              a runner is offline, nothing waiting too long
# Exit 0 healthy, 1 findings, 2 usage error or a gh/jq failure.
#
# Env:
#   CI_HEALTH_QUEUE_MINS=10     queued-job age (minutes) that counts as waiting too long
#   CI_HEALTH_REPOS=            default repo list (space separated)
#   CI_HEALTH_REPORT_RUNS=100   --report looks at at most this many newest runs per repo (one API page: max 100)
#   CI_HEALTH_GH_TOKEN=         token for gh (listing runners needs repo admin; a worker-scoped token gets HTTP 403)
#   CI_HEALTH_NOW=              epoch override (tests)
#
# Only jobs labelled self-hosted count: a hosted-runner job never waits on
# our runners. Runners are matched per repo (a personal account cannot share
# runners across repos).
set -uo pipefail

case "${1:-}" in -h|--help) sed -n "2,32p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
command -v jq >/dev/null || { echo "ci-runner-health: jq required" >&2; exit 2; }
command -v gh >/dev/null || { echo "ci-runner-health: gh required" >&2; exit 2; }

QUEUE_MINS="${CI_HEALTH_QUEUE_MINS:-10}"
[[ "$QUEUE_MINS" =~ ^[0-9]+$ ]] || { echo "ci-runner-health: CI_HEALTH_QUEUE_MINS must be an integer (got $QUEUE_MINS)" >&2; exit 2; }
REPORT_RUNS="${CI_HEALTH_REPORT_RUNS:-100}"
{ [[ "$REPORT_RUNS" =~ ^[0-9]+$ ]] && [ "$REPORT_RUNS" -gt 0 ]; } || { echo "ci-runner-health: CI_HEALTH_REPORT_RUNS must be a positive integer" >&2; exit 2; }
NOW="${CI_HEALTH_NOW:-$(date +%s)}"
[ -z "${CI_HEALTH_GH_TOKEN:-}" ] || export GH_TOKEN="$CI_HEALTH_GH_TOKEN"

MODE=check; DAYS=7
if [ "${1:-}" = "--report" ]; then
    MODE=report; shift
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then DAYS="$1"; shift; fi
fi
REPOS=("$@")
if [ "${#REPOS[@]}" -eq 0 ] && [ -n "${CI_HEALTH_REPOS:-}" ]; then read -r -a REPOS <<< "$CI_HEALTH_REPOS"; fi
if [ "${#REPOS[@]}" -eq 0 ]; then
    r="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
        || { echo "ci-runner-health: no repo given and cannot resolve the current one" >&2; exit 2; }
    REPOS=("$r")
fi
for r in "${REPOS[@]}"; do
    [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "ci-runner-health: bad repo '$r' (want owner/name)" >&2; exit 2; }
done

# Subshells ($(…)) lose variables, so a gh failure is recorded as a file.
FAIL_FILE="$(mktemp -t ci-health-fail-XXXXXX)"; rm -f "$FAIL_FILE"; trap 'rm -f "$FAIL_FILE" "$FAIL_FILE.err"' EXIT
# gh_json <endpoint> <jq filter>: prints the filtered output; flags api_fail on error.
gh_json() {
    local out
    if ! out="$(gh api "$1" --jq "$2" 2>"$FAIL_FILE.err")"; then head -n1 "$FAIL_FILE.err" > "$FAIL_FILE"; return 1; fi
    printf '%s' "$out"
}

# jobs_of_runs <repo> <run-id>…: one compact job object per line (self-hosted only).
jobs_of_runs() {
    local repo="$1" id out; shift
    for id in "$@"; do
        out="$(gh_json "repos/$repo/actions/runs/$id/jobs?per_page=100" \
            '.jobs[] | select(.labels | index("self-hosted")) | {id, status, created_at, started_at, runner_name}' )" || continue
        [ -n "$out" ] && printf '%s\n' "$out" | jq -c .
    done
}

emit() { # <check> <severity> <match> <message> <repo> <runner> <queued_mins>
    jq -nc --arg c "$1" --arg s "$2" --arg m "$3" --arg msg "$4" --arg repo "$5" --arg runner "$6" --argjson q "${7:-0}" \
        '{check:$c, severity:$s, line:0, match:$m, message:$msg, repo:$repo, runner:$runner, queued_mins:$q}'
}

check_repo() {
    local repo="$1" runners ids jobs idl maxq offline online_busy_all total nm unit slug
    runners="$(gh_json "repos/$repo/actions/runners?per_page=100" '.runners[] | {name, status, busy}')" || return 0
    runners="$(printf '%s\n' "$runners" | jq -c . 2>/dev/null)"
    offline="$(printf '%s\n' "$runners" | jq -r 'select(.status=="offline") | .name')"
    online_busy_all="$(printf '%s\n' "$runners" | jq -s 'length > 0 and all(.[]; .status=="online" and .busy)')"
    # Healthy (someone is online and idle): no finding is possible, so skip the per-run job fetches.
    [ -n "$offline" ] || [ "$online_busy_all" = "true" ] || return 0
    ids="$(gh_json "repos/$repo/actions/runs?status=queued&per_page=50" '.workflow_runs[].id')" || return 0
    ids="$ids $(gh_json "repos/$repo/actions/runs?status=in_progress&per_page=50" '.workflow_runs[].id')" || return 0
    # shellcheck disable=SC2086
    mapfile -t idl < <(printf "%s\n" $ids | sed "/^$/d" | sort -un)
    jobs="$(jobs_of_runs "$repo" "${idl[@]}")"
    # Age in whole minutes of the oldest queued job; 0 when none.
    maxq="$(printf '%s\n' "$jobs" | jq -s --argjson now "$NOW" \
        '[.[] | select(.status=="queued") | (($now - (.created_at | fromdateiso8601)) / 60 | floor)] | max // 0')"
    total="$(printf '%s\n' "$runners" | jq -s 'length')"
    slug="${repo/\//-}"
    if [ -n "$offline" ]; then
        while IFS= read -r nm; do
            [ -n "$nm" ] || continue
            unit="actions.runner.$slug.$nm.service"
            if [ "$maxq" -gt "$QUEUE_MINS" ]; then
                emit runner-offline-with-queue error "$repo $nm" \
                    "runner $nm is offline and a job for $repo has been queued for $maxq min (> $QUEUE_MINS); restart it: sudo systemctl restart $unit" \
                    "$repo" "$nm" "$maxq"
            else
                emit runner-offline warn "$repo $nm" \
                    "runner $nm is offline with no job waiting too long; restart it: sudo systemctl restart $unit" \
                    "$repo" "$nm" "$maxq"
            fi
        done <<< "$offline"
    elif [ "$maxq" -gt "$QUEUE_MINS" ] && [ "$online_busy_all" = "true" ]; then
        emit queue-long warn "$repo" \
            "a job for $repo has been queued for $maxq min (> $QUEUE_MINS) while all $total runner(s) are online and busy; more runner capacity is needed" \
            "$repo" "" "$maxq"
    fi
}

report_repo() {
    local repo="$1" since ids
    since="$(date -u -d "@$((NOW - DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)"
    ids="$(gh_json "repos/$repo/actions/runs?created=%3E%3D$since&per_page=100" '.workflow_runs[].id')" || return 0
    ids="$(printf "%s\n" "$ids" | sed "/^$/d" | head -n "$REPORT_RUNS")"
    # shellcheck disable=SC2086
    jobs_of_runs "$repo" $ids | jq -s -r --arg repo "$repo" '
        [.[] | select(.started_at != null)
             | ((.started_at | fromdateiso8601) - (.created_at | fromdateiso8601)) / 60 | if . < 0 then 0 else . end]
        | sort as $w
        | def q($p): if ($w|length) == 0 then null
                     else ($p * (($w|length) - 1)) as $i
                     | ($i|floor) as $lo | ($i|ceil) as $hi
                     | $w[$lo] + ($w[$hi] - $w[$lo]) * ($i - $lo) end;
          [$repo, ($w|length), (q(0.5) // "-"), (q(0.9) // "-")]
        | @tsv'
}

if [ "$MODE" = "report" ]; then
    printf 'queue wait over the last %s day(s), at most %s runs per repo (minutes)\n' "$DAYS" "$REPORT_RUNS"
    printf '%-40s %6s %8s %10s\n' repo jobs median 1-in-10
    for repo in "${REPOS[@]}"; do
        line="$(report_repo "$repo")"
        [ -n "$line" ] || { printf '%-40s %6s\n' "$repo" "no data"; continue; }
        IFS=$'\t' read -r r n med p90 <<< "$line"
        fmt() { [[ "$1" =~ ^[0-9.]+$ ]] && printf '%.1f' "$1" || printf '%s' "$1"; }
        printf '%-40s %6s %8s %10s\n' "$r" "$n" "$(fmt "$med")" "$(fmt "$p90")"
    done
    [ -e "$FAIL_FILE" ] && { echo "ci-runner-health: some gh api calls failed; numbers may be partial" >&2; exit 2; }
    exit 0
fi

out=""
for repo in "${REPOS[@]}"; do
    out+="$(check_repo "$repo")"$'\n'
done
if [ -e "$FAIL_FILE" ]; then echo "ci-runner-health: gh api failed (auth, rate limit or network); no verdict ($(head -n1 "$FAIL_FILE"))" >&2; exit 2; fi
out="$(printf '%s' "$out" | sed '/^$/d')"
[ -z "$out" ] && exit 0
printf '%s\n' "$out"
exit 1
