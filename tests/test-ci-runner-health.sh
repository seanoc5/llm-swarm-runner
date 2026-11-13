#!/usr/bin/env bash
#
# test-ci-runner-health.sh — issue #899: scripts/ci-runner-health.sh flags an
# offline self-hosted runner while jobs queue, and reports queue wait. A stub
# `gh` serves JSON from a temp dir, so no network and no GitHub token.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { if [ "$2" = "$3" ]; then green "$1"; else red "$1 (expected [$2] got [$3])"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$ROOT/scripts/ci-runner-health.sh"
T="$(mktemp -d -t ci-health-XXXXXX)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/api"
export STUB_API="$T/api" PATH="$T/bin:$PATH"
# gh api <endpoint> --jq <filter>: the endpoint's file name is the path with
# "/" and "?" turned into "_"; the stub applies the filter itself.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || exit 2
ep="$2"; shift 2; filter=.
[ "${1:-}" = --jq ] && filter="$2"
f="$STUB_API/$(printf '%s' "$ep" | tr '/?&=%<>' '_______')"
[ -f "$f" ] || { echo "stub: no fixture for $ep ($f)" >&2; exit 1; }
jq -r "$filter" "$f"
STUB
chmod +x "$T/bin/gh"

NOW=1800000000
export CI_HEALTH_NOW=$NOW
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ep() { printf '%s' "$1" | tr '/?&=%<>' '_______'; }
R=o/repo

runners() { # name:status:busy[:label,label] …  (labels default self-hosted,linux)
    local s="" x lj
    for x in "$@"; do
        IFS=: read -r n st b lb <<< "$x"
        lj="$(jq -nc --arg l "${lb:-self-hosted,linux}" '($l | split(","))')"
        s+="{\"name\":\"$n\",\"status\":\"$st\",\"busy\":$b,\"labels\":$(jq -c 'map({name:.})' <<< "$lj")},"
    done
    echo "{\"runners\":[${s%,}]}" > "$T/api/$(ep "repos/$R/actions/runners?per_page=100")"
}
queue() { # run ids for queued / in_progress
    echo "{\"workflow_runs\":[$1]}" > "$T/api/$(ep "repos/$R/actions/runs?status=queued&per_page=50")"
    echo "{\"workflow_runs\":[$2]}" > "$T/api/$(ep "repos/$R/actions/runs?status=in_progress&per_page=50")"
}
jobs_of() { # run-id then job json objects
    local id="$1"; shift
    echo "{\"jobs\":[$(IFS=,; echo "$*")]}" > "$T/api/$(ep "repos/$R/actions/runs/$id/jobs?per_page=100")"
}
job() { # status created-epoch started-epoch|null [labels]
    local started=null
    [ "$3" = null ] || started="\"$(iso "$3")\""
    echo "{\"id\":1,\"status\":\"$1\",\"created_at\":\"$(iso "$2")\",\"started_at\":$started,\"runner_name\":null,\"labels\":${4:-[\"self-hosted\",\"linux\"]}}"
}

# 1. offline runner + job queued 20 min: error, exit 1, restart command named.
runners "r1:offline:false"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-1200)) null)"
set +e; out="$("$CHK" "$R")"; rc=$?; set -e
check "offline + queued 20 min: exit 1" 1 "$rc"
check "…check id" runner-offline-with-queue "$(jq -r .check <<< "$out")"
check "…severity" error "$(jq -r .severity <<< "$out")"
case "$out" in *"sudo systemctl restart actions.runner.o-repo.r1.service"*) got=yes ;; *) got=no ;; esac
check "…message carries the restart command" yes "$got"

# 2. runner back and idle, job started: silent, exit 0.
runners "r1:online:false"; queue '' '{"id":10}'
jobs_of 10 "$(job in_progress $((NOW-1200)) $((NOW-1100)))"
set +e; out="$("$CHK" "$R")"; rc=$?; set -e
check "healthy: exit 0 and silent" "0|" "$rc|$out"

# 3. offline but queue is short: warn runner-offline only.
runners "r1:offline:false"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-120)) null)"
set +e; out="$("$CHK" "$R")"; rc=$?; set -e
check "offline, 2 min queue: warn runner-offline" "1|runner-offline|warn" "$rc|$(jq -r .check <<< "$out")|$(jq -r .severity <<< "$out")"
queue '' ''; set +e; out="$("$CHK" "$R")"; rc=$?; set -e
check "offline, nothing queued: runner-offline" "1|runner-offline" "$rc|$(jq -r .check <<< "$out")"

# 4. all online and busy, long queue: queue-long warn.
runners "r1:online:true" "r2:online:true"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-900)) null)"
set +e; out="$("$CHK" "$R")"; rc=$?; set -e
check "all busy + 15 min queue: warn queue-long" "1|queue-long|warn" "$rc|$(jq -r .check <<< "$out")|$(jq -r .severity <<< "$out")"

# 5. an idle online runner and a queued job: no verdict from this check (label mismatch is out of scope).
runners "r1:online:true" "r2:online:false"
set +e; out="$("$CHK" "$R")"; rc=$?; set -e
check "an idle runner exists: silent" "0|" "$rc|$out"

# 6. hosted-runner job is ignored; threshold env honored.
runners "r1:offline:false"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-1200)) null '["ubuntu-latest"]')"
set +e; out="$("$CHK" "$R")"; set -e
check "a hosted-runner job does not count as waiting" runner-offline "$(jq -r .check <<< "$out")"
jobs_of 10 "$(job queued $((NOW-1200)) null)"
set +e; out="$(CI_HEALTH_QUEUE_MINS=30 "$CHK" "$R")"; set -e
check "CI_HEALTH_QUEUE_MINS=30 raises the bar" runner-offline "$(jq -r .check <<< "$out")"

# 6b. retired-but-registered runner (#940 review): a stale offline runner plus a
# normal busy queue must NOT page "restart <stale runner>"; busy online runners
# that fit the job make it a capacity note.
checks_of() { jq -r '.check + ":" + .severity' <<< "$1" | sort | paste -sd, -; }
runners "old:offline:false" "r1:online:true" "r2:online:true"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-900)) null)"
set +e; out="$("$CHK" "$R")"; rc=$?; set -e
check "stale offline + busy queue: no urgent alert" "1|queue-long:warn,runner-offline:warn" "$rc|$(checks_of "$out")"
case "$out" in *'"check":"runner-offline-with-queue"'*) got=urgent ;; *) got=none ;; esac
check "…runner-offline-with-queue absent" none "$got"

# 6c. an idle online runner fits the job: restarting the offline one is moot.
runners "old:offline:false" "r1:online:false"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-1200)) null)"
set +e; out="$("$CHK" "$R")"; set -e
check "offline + idle matching online runner: warn only" "runner-offline:warn" "$(checks_of "$out")"

# 6d. the only online runners lack the job's labels: the offline runner is the one that fits, so urgent.
runners "old:offline:false" "gpu1:online:true:self-hosted,gpu"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-1200)) null)"
set +e; out="$("$CHK" "$R")"; set -e
check "offline fits, online runner has other labels: urgent" "runner-offline-with-queue:error" "$(checks_of "$out")"

# 6e. the offline runner lacks the job's labels: not the culprit, no urgent alert.
runners "gpu-old:offline:false:self-hosted,gpu" "r1:online:true"; queue '{"id":10}' ''
jobs_of 10 "$(job queued $((NOW-1200)) null)"
set +e; out="$("$CHK" "$R")"; set -e
check "offline runner cannot take the job: no urgent" "queue-long:warn,runner-offline:warn" "$(checks_of "$out")"

# 7. gh failure: exit 2, no verdict.
rm -f "$T/api/$(ep "repos/$R/actions/runners?per_page=100")"
set +e; "$CHK" "$R" >/dev/null 2>&1; rc=$?; set -e
check "gh failure: exit 2" 2 "$rc"

# 8. --report: waits 0,60,120,...,540 s → median 4.5 min, p90 8.1 min (linear).
runners "r1:online:false"
since="$(iso $((NOW-7*86400)))"
echo '{"workflow_runs":[{"id":20}]}' > "$T/api/$(ep "repos/$R/actions/runs?created=%3E%3D$since&per_page=100")"
js=(); for i in 0 1 2 3 4 5 6 7 8 9; do js+=("$(job completed $((NOW-5000)) $((NOW-5000+i*60)))"); done
js+=("$(job completed $((NOW-5000)) $((NOW-5000+999)) '["ubuntu-latest"]')")
jobs_of 20 "${js[@]}"
out="$("$CHK" --report 7 "$R")"
row="$(grep "^$R" <<< "$out")"
check "--report 7: jobs / median / 1-in-10 (hosted job excluded)" "$R 10 4.5 8.1" "$(tr -s ' ' <<< "$row")"

echo "all ci-runner-health tests passed"
