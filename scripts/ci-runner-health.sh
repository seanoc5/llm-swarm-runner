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
#   runner-offline-with-queue (error)  a runner is offline and a self-hosted job it could
#                                      take (job labels all on the runner) has been queued
#                                      > CI_HEALTH_QUEUE_MINS with NO online runner able to
#                                      take it, idle or busy
#   queue-long (warn)                  such a job waits while the online runners that fit it
#                                      are all busy: needs more capacity, not a restart
#   runner-offline (warn)              a runner is offline, no job only it could take waits too long
# Exit 0 healthy, 1 findings, 2 usage error or a gh/jq failure.
#
# Env:
#   CI_HEALTH_QUEUE_MINS=10     queued-job age (minutes) that counts as waiting too long
#   CI_HEALTH_REPOS=            default repo list (space separated)
#   CI_HEALTH_REPORT_RUNS=100   --report looks at at most this many newest runs per repo (one API page: max 100)
#   CI_HEALTH_GH_TOKEN=         token for gh (listing runners needs repo admin; a worker-scoped token gets HTTP 403)
#   CI_HEALTH_NOW=              epoch override (tests)
#
# Queue age counts from the job's created_at, which is when it became ready (a job blocked
# on `needs:` is not in the jobs API until its dependencies finish).
# Only jobs labelled self-hosted count: a hosted-runner job never waits on
# our runners. Runners are matched per repo (a personal account cannot share
# runners across repos).
set -uo pipefail

case "${1:-}" in -h|--help) sed -n "2,36p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
command -v jq >/dev/null || { echo "ci-runner-health: jq required" >&2; exit 2; }
command -v gh >/dev/null || { echo "ci-runner-health: gh required" >&2; exit 2; }
# Reload project-only knobs (CI_HEALTH_*) from <project>/.swarm/.env; caller-set variables still win.
# shellcheck source=_load-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_load-env.sh" "$PWD"

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
            '.jobs[] | select(.labels | index("self-hosted")) | {id, status, created_at, started_at, runner_name, labels}' )" || continue
        [ -n "$out" ] && printf '%s\n' "$out" | jq -c .
    done
}

emit() { # <check> <severity> <match> <message> <repo> <runner> <queued_mins>
    jq -nc --arg c "$1" --arg s "$2" --arg m "$3" --arg msg "$4" --arg repo "$5" --arg runner "$6" --argjson q "${7:-0}" \
        '{check:$c, severity:$s, line:0, match:$m, message:$msg, repo:$repo, runner:$runner, queued_mins:$q}'
}

check_repo() {
    local repo="$1" runners ids jobs idl offline online_busy_all slug ev kind nm mins n unit
    runners="$(gh_json "repos/$repo/actions/runners?per_page=100" '.runners[] | {name, status, busy, labels: [.labels[].name]}')" || return 0
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
    slug="${repo/\//-}"
    # Match each queued job to runners by labels (a runner can take a job when it
    # carries every label the job asks for). A job's age runs from its created_at,
    # which is when it became ready: a job blocked on `needs:` does not exist in
    # the jobs API until its dependencies finish (see PR #940 for the evidence).
    #   urgent   waiting too long, no online runner fits it, an offline runner does
    #   capacity waiting too long, online runners fit it but all are busy
    #   offline  an offline runner, with the age of the oldest queued job it could take
    # A waiting job that an idle online runner fits yields nothing (no restart helps).
    ev="$(jq -nc --argjson now "$NOW" --argjson q "$QUEUE_MINS" \
        --argjson runners "$(printf '%s\n' "$runners" | jq -s .)" --argjson jobs "$(printf '%s\n' "$jobs" | jq -s .)" '
        def lc: map(ascii_downcase);
        def fits($j; $r): (($j.labels | lc) - ($r.labels | lc)) == [];
        [ $jobs[] | select(.status == "queued")
          | .age = ((($now - (.created_at | fromdateiso8601)) / 60) | floor) ] as $queued
        | [ $queued[] | select(.age > $q) | . as $j
            | [ $runners[] | select(.status == "online" and fits($j; .)) ] as $on
            | [ $runners[] | select(.status == "offline" and fits($j; .)) | .name ] as $off
            | if ($on | any(.busy | not)) then empty
              elif ($on | length) > 0 then {kind: "capacity", age: .age, n: ($on | length)}
              elif ($off | length) > 0 then {kind: "urgent", age: .age, off: $off}
              else empty end ] as $w
        | ( $w | map(select(.kind == "capacity")) | if length > 0 then {kind: "capacity", mins: (map(.age) | max), n: (map(.n) | max)} else empty end ),
          ( $runners[] | select(.status == "offline") | .name as $nm | . as $r
            | ( [ $w[] | select(.kind == "urgent" and (.off | index($nm))) | .age ] ) as $u
            | ( [ $queued[] | select(fits(.; $r)) | .age ] | max // 0 ) as $any
            | if ($u | length) > 0 then {kind: "urgent", runner: $nm, mins: ($u | max)}
              else {kind: "offline", runner: $nm, mins: $any} end )')" || { echo "ci-runner-health: jq failed for $repo" > "$FAIL_FILE"; return 0; }
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        kind="$(jq -r .kind <<< "$e")"; nm="$(jq -r '.runner // ""' <<< "$e")"; mins="$(jq -r .mins <<< "$e")"
        unit="actions.runner.$slug.$nm.service"
        case "$kind" in
            urgent) emit runner-offline-with-queue error "$repo $nm" \
                "runner $nm is offline, no online runner can take the job waiting in $repo, and that job has been queued for $mins min (> $QUEUE_MINS); restart it: sudo systemctl restart $unit" \
                "$repo" "$nm" "$mins" ;;
            offline) emit runner-offline warn "$repo $nm" \
                "runner $nm is offline but no job it alone could take has waited too long; restart it if it should be in service: sudo systemctl restart $unit" \
                "$repo" "$nm" "$mins" ;;
            capacity) n="$(jq -r .n <<< "$e")"
                emit queue-long warn "$repo" \
                "a job for $repo has been queued for $mins min (> $QUEUE_MINS) while its $n matching online runner(s) are all busy; more runner capacity is needed" \
                "$repo" "" "$mins" ;;
        esac
    done <<< "$ev"
}

report_repo() {
    local repo="$1" since ids
    since="$(date -u -d "@$((NOW - DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)"
    ids="$(gh_json "repos/$repo/actions/runs?created=%3E%3D$since&per_page=100" '.workflow_runs[].id')" || return 0
    ids="$(printf "%s\n" "$ids" | sed "/^$/d" | sed -n "1,${REPORT_RUNS}p")"
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
