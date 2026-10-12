#!/usr/bin/env bash
#
# swarm-idle-report.sh — how many worker-slot hours went to work, to
# waiting on a human, and to finished workers sitting on a slot.
#
# Read-only. Replays each swarm's <project>/.swarm/events.log and splits
# every worker's life (worker.start → reap.window or reap.worktree) into three buckets:
#
#   working        a task is open: worker.start or a delivered follow-up
#                  (worker.deliver.ok) until worker.finish
#   waiting-on-you the window carried the ✋ flag (outbox decision needed);
#                  takes precedence over the other two
#   finished-held  worker.finish until the window is reaped or the next
#                  follow-up is delivered — the slot is held, nothing runs
#
# Then answers the parking question directly: at each machine-wide cap
# refusal (cap.refused reason=host_max_workers), how many of the occupied
# slots, across all swarms, were finished-held or waiting-on-you. Those
# are the slots a "park idle workers" feature would have freed.
#
# Also reports hours the coordinator window carried 🔔 (waiting for your
# approval), which can stall a whole swarm without holding worker slots.
#
# Caveats (approximate by design):
#   - Flags (✋, 🔔) are only logged since 2026-10-09 (#597); before that,
#     waiting-on-you time is counted as working.
#   - A follow-up brief the worker picks up without worker.deliver.ok is
#     counted as finished-held.
#   - A worker with no reap event ends at its last logged event,
#     unless its container is running now (then it ends now).
#
# Usage:
#   swarm-idle-report.sh [--days N] [project-dir ...]
#
#   --days N     only count time in the last N days (default 30; 0 = all)
#   project-dir  swarm project dirs (each with .swarm/events.log); default:
#                every <dir> up to 3 levels under the parent of this repo
#                whose .swarm/events.log has a watch.start line
#
# Test hooks: SWARM_IDLE_NOW (epoch "now"), SWARM_IDLE_RUNNING (newline-
# separated container names instead of `docker ps`).
set -euo pipefail

DAYS=30
DIRS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --days) DAYS="${2:?--days needs a number}"; shift 2 ;;
        -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "swarm-idle-report.sh: unknown option $1" >&2; exit 2 ;;
        *) DIRS+=("$1"); shift ;;
    esac
done
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "swarm-idle-report.sh: --days must be a whole number" >&2; exit 2; }

if [ ${#DIRS[@]} -eq 0 ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
    while IFS= read -r log; do
        grep -q '  watch\.start ' "$log" 2>/dev/null && DIRS+=("${log%/.swarm/events.log}")
    done < <(find "$ROOT" -mindepth 3 -maxdepth 5 -path '*/.swarm/events.log' 2>/dev/null | sort)
fi
[ ${#DIRS[@]} -gt 0 ] || { echo "swarm-idle-report.sh: no swarm event logs found" >&2; exit 1; }

STREAM="$(mktemp -t swarm-idle-XXXXXX)"
trap 'rm -f "$STREAM"' EXIT

NOW="${SWARM_IDLE_NOW:-$(date +%s)}"
if [ -n "${SWARM_IDLE_RUNNING+x}" ]; then
    RUNNING="$SWARM_IDLE_RUNNING"
else
    RUNNING="$(docker ps --filter 'name=^swarm-' --format '{{.Names}}' 2>/dev/null || true)"
fi
SINCE=0
[ "$DAYS" -gt 0 ] && SINCE=$(( NOW - DAYS * 86400 ))

# One merged, time-ordered stream: "<iso-ts> <swarm> <event> <k=v ...>".
# Only the events the replay needs, so 200k-line logs stay cheap.
for d in "${DIRS[@]}"; do
    log="$d/.swarm/events.log"
    [ -f "$log" ] || { echo "warn: no $log" >&2; continue; }
    name="$(basename "$d")"
    grep -aE '^[0-9TZ:-]+  (worker\.start|worker\.finish|worker\.deliver\.ok|reap\.window|reap\.worktree|watch\.flag|cap\.refused) ' "$log" \
        | awk -v n="$name" '{ $1 = $1 " " n; print }'
done | sort -s -k1,1 > "$STREAM"

# Two passes over the stream: the first learns when each worker actually
# ended (so a worker whose reap was never logged does not count as occupying
# a slot at later refusals); the second does the accounting.
TZ=UTC awk -v now="$NOW" -v since="$SINCE" -v running="$RUNNING" '
function epoch(iso,   s) {
    s = iso; gsub(/[-T:Z]/, " ", s)
    return mktime(s)
}
function kv(key,   i) {
    for (i = 4; i <= NF; i++) if (index($i, key "=") == 1) return substr($i, length(key) + 2)
    return ""
}
function accrue(sw, bucket, from, to) {
    if (from < since) from = since
    if (to <= from) return
    hours[sw, bucket] += (to - from) / 3600
    swarms[sw] = 1
}
function eff(k) { return hand[k] ? "waiting" : state[k] }
# Close out the open stretch of slot k up to time t, before any change.
function settle(k, t,   sw) {
    if (!(k in state)) return
    sw = swarm_of[k]
    accrue(sw, eff(k), mark[k], t)
    mark[k] = t
}
function close_slot(k, t) {
    settle(k, t)
    delete state[k]; delete hand[k]; delete mark[k]; delete born[k]; delete swarm_of[k]
}
function is_live(k,   p, c) {
    split(k, p, SUBSEP)
    for (c in alive) if (c ~ ("-" p[1] "-iss-" p[2] "$")) return 1
    return 0
}
BEGIN {
    n = split(running, r, "\n")
    for (i = 1; i <= n; i++) if (r[i] != "") alive[r[i]] = 1
}
# Pass 1: when did each worker (swarm, issue, start time) really end?
NR == FNR {
    ev = $3
    if (ev != "worker.start" && ev != "worker.finish" && ev != "worker.deliver.ok" && ev != "reap.window" && ev != "reap.worktree") next
    t = epoch($1); k = $2 SUBSEP kv("issue")
    if (ev == "worker.start") {
        if (k in s1) endt[k, s1[k]] = t
        s1[k] = t; l1[k] = t
    } else if (k in s1) {
        l1[k] = t
        if (ev == "reap.window" || ev == "reap.worktree") { endt[k, s1[k]] = t; delete s1[k] }
    }
    next
}
FNR == 1 {
    for (k in s1) {
        if (is_live(k)) endt[k, s1[k]] = now
        else { endt[k, s1[k]] = l1[k]; if (l1[k] >= since) unended++ }
    }
}
# Pass 2: accounting.
{
    t = epoch($1); sw = $2; ev = $3
    if (ev == "cap.refused") {
        if (kv("reason") != "host_max_workers" || t < since) next
        refusals++
        for (k in state) if (endt[k, born[k]] > t) at_refusal[eff(k)]++
        next
    }
    if (ev == "watch.flag") {
        w = kv("window"); f = kv("flag")
        if (w == "coordinator") {
            if (f == "🔔") { if (!(sw in bell)) bell[sw] = t }
            else if (sw in bell) { accrue(sw, "bell", bell[sw], t); delete bell[sw] }
            next
        }
        if (w !~ /^iss-[0-9]+$/) next
        k = sw SUBSEP substr(w, 5)
        if (!(k in state) || t > endt[k, born[k]]) next
        settle(k, t)
        hand[k] = (f == "✋")
        next
    }
    k = sw SUBSEP kv("issue")
    if (ev == "worker.start") {
        if (k in state) close_slot(k, t)
        state[k] = "working"; mark[k] = t; born[k] = t; swarm_of[k] = sw; hand[k] = 0
    } else if (!(k in state)) {
        next
    } else if (ev == "worker.finish") {
        settle(k, t); state[k] = "held"
    } else if (ev == "worker.deliver.ok") {
        settle(k, t); state[k] = "working"
    } else if (ev == "reap.window" || ev == "reap.worktree") {
        close_slot(k, t)
    }
}
END {
    for (k in state) close_slot(k, endt[k, born[k]])
    for (c in bell) accrue(c, "bell", bell[c], now)

    printf "Worker-slot hours by swarm%s\n", (since ? " (last " int((now - since) / 86400) " days)" : "")
    printf "  %-24s %9s %9s %9s %9s %7s\n", "swarm", "working", "waiting", "held", "total", "idle%"
    for (s in swarms) order[++m] = s
    asort(order)
    for (i = 1; i <= m; i++) {
        s = order[i]
        w = hours[s, "working"]; h = hours[s, "held"]; q = hours[s, "waiting"]
        tot = w + h + q
        if (tot == 0) continue
        printf "  %-24s %9.1f %9.1f %9.1f %9.1f %6.0f%%\n", s, w, q, h, tot, 100 * (h + q) / tot
        W += w; H += h; Q += q
    }
    T = W + H + Q
    if (T > 0) printf "  %-24s %9.1f %9.1f %9.1f %9.1f %6.0f%%\n", "ALL", W, Q, H, T, 100 * (H + Q) / T
    if (unended) printf "  (%d worker(s) had no reap event; counted up to their last event)\n", unended

    printf "\nMachine-wide cap refusals: %d\n", refusals
    if (refusals) {
        occ = at_refusal["working"] + at_refusal["held"] + at_refusal["waiting"]
        printf "  average occupied slots at refusal: %.1f\n", occ / refusals
        printf "    working %.1f, waiting-on-you %.1f, finished-held %.1f\n", \
            at_refusal["working"] / refusals, at_refusal["waiting"] / refusals, at_refusal["held"] / refusals
        printf "  parking would have freed about %.1f slot(s) per refusal\n", \
            (at_refusal["held"] + at_refusal["waiting"]) / refusals
    }

    printf "\nCoordinator waiting for approval (🔔, logged since 2026-10-09)\n"
    any = 0
    for (i = 1; i <= m; i++) if (hours[order[i], "bell"] > 0) { printf "  %-24s %9.1f h\n", order[i], hours[order[i], "bell"]; any = 1 }
    if (!any) print "  none"
}
' "$STREAM" "$STREAM"
