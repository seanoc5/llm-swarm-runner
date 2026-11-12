#!/usr/bin/env bash
# watch-pause.sh — pause one swarm's coordinator watcher for a named time (issue #457).
#
# Usage:
#   watch-pause.sh [duration] [--full] [--reason "text"] [--project DIR]
#   watch-pause.sh --resume [--project DIR]
#   watch-pause.sh --status [--project DIR]
#
#   duration   N, Ns, Nm or Nh; default 60m. It is
#              also the longest a pause can last: it ends by itself, so a
#              forgotten pause cannot strand the swarm.
#   --full     also stop the timer sweeps (reaps, compaction, worker
#              delivery). Default is quiet: the watcher keeps polling and
#              writing coord-inbox/ notes but never rings the coordinator.
#   --project  the swarm's project dir (default: $PWD).
#
# Quiet is the deploy-window mode: nothing is lost, and on resume the
# coordinator gets one nudge carrying the true count of waiting items.
# A repeat call replaces the earlier pause (extend or shorten it).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_watch-pause.sh
. "$SCRIPT_DIR/_watch-pause.sh"

project="$PWD"; dur=""; mode=quiet; reason=""; action=pause
while [ $# -gt 0 ]; do
    case "$1" in
        --resume) action=resume ;;
        --status) action=status ;;
        --full)   mode=full ;;
        --quiet)  mode=quiet ;;
        --reason) shift; reason="${1:-}" ;;
        --project) shift; project="${1:-}" ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "watch-pause.sh: unknown option $1" >&2; exit 2 ;;
        *)  [ -z "$dur" ] || { echo "watch-pause.sh: only one duration allowed" >&2; exit 2; }; dur="$1" ;;
    esac
    shift
done
swarm="$project/.swarm"
[ -d "$swarm" ] || { echo "watch-pause.sh: no $swarm — is $project a swarm project? (use --project)" >&2; exit 2; }
f="$(watch_pause_file "$swarm")"

case "$action" in
status)
    if watch_pause_read "$swarm"; then watch_pause_describe; else echo "not paused"; fi
    ;;
resume)
    if watch_pause_read "$swarm"; then
        rm -f "$f"
        watch_pause_log "$swarm" "coord.resume reason=manual mode=$WP_MODE"
        echo "resumed; the watcher rings once on its next retry tick if anything is waiting"
    else
        echo "not paused"
    fi
    ;;
pause)
    dur="${dur:-60m}"
    [[ "$dur" =~ ^([0-9]+)([smh]?)$ ]] || { echo "watch-pause.sh: bad duration '$dur' (use 90, 90s, 30m, 2h)" >&2; exit 2; }
    n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in s) secs=$n ;; h) secs=$((n * 3600)) ;; *) secs=$((n * 60)) ;; esac
    [ "$secs" -gt 0 ] || { echo "watch-pause.sh: duration must be positive (use --resume to end a pause)" >&2; exit 2; }
    reason="${reason//$'\n'/ }"
    now="$(date +%s)"; until=$((now + secs))
    tmp="$(mktemp -p "$swarm" .watch-paused.XXXXXX)"
    printf 'until=%s\nmode=%s\nsince=%s\n' "$until" "$mode" "$now" > "$tmp"
    [ -z "$reason" ] || printf 'reason=%s\n' "$reason" >> "$tmp"
    mv "$tmp" "$f"
    watch_pause_log "$swarm" "coord.pause mode=$mode until=$(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ) secs=$secs${reason:+ reason=\"$reason\"}"
    watch_pause_read "$swarm" && watch_pause_describe
    ;;
esac
