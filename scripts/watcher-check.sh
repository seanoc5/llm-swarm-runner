#!/usr/bin/env bash
#
# watcher-check.sh — is this project's coordinator-watch.sh alive? (issue #756)
#
# A dead watcher is silent: outcomes, outbox files, ready sweeps and doorbells
# all stop, and the coordinator just looks idle. civicstrata lost its watcher
# for days (2026-11-01) with a decision-needed outbox file unread and a green
# PR stuck in draft. This is the one cheap check that makes it loud.
#
# Signal used: the pid in <project>/.swarm/coordinator-watch.state, probed with
# `kill -0` and (where /proc exists) confirmed to still be a coordinator-watch
# process, so a recycled pid doesn't read as alive. The state file is written
# once at watcher startup and never rewritten or removed, so its mtime says
# when the watcher STARTED, not whether it is alive; do not use it as a
# heartbeat.
#
# Deliberate stop vs crash. A dead watcher is NOT reported when either marker
# exists, is newer than the state file (a watcher that started after the
# marker, then crashed, still warns) and is younger than
# WATCHER_PAUSE_MAX_SECS (default 259200 = 3 days; after that the WARN
# returns, saying how long it has been stopped, so a forgotten stop cannot
# hide forever):
#   .swarm/watcher-stopped   written by coordinator-watch.sh itself when it
#                            exits on SIGINT/SIGTERM (Ctrl-C, `kill <pid>`).
#                            A crash, SIGKILL, SIGHUP (tmux pane/session
#                            killed) or the watcher's own stale-code
#                            self-shutdown leaves no marker, so those warn.
#   .swarm/watcher-paused    written by `watcher-check.sh --pause` for a stop
#                            the operator plans ahead of time.
# A starting watcher removes both markers.
#
# Usage:
#   watcher-check.sh [project-dir]
#       Silent when the watcher is alive, was deliberately stopped, or never
#       ran for this project (no state file: WATCH=0 swarms). Otherwise prints
#       a WARN naming the restart command and exits 3.
#   watcher-check.sh --status [project-dir]
#       Always prints one line: running | stopped-deliberately | not-running |
#       never-started. Exit codes as above (0, 0, 3, 0).
#   watcher-check.sh --siblings [project-dir]
#       Cross-swarm view: scan the sibling projects next to project-dir (and
#       any colon-separated dirs in WATCH_SIBLING_ROOTS) and print one
#       tab-separated line per sibling whose watcher is dead (not deliberately
#       stopped) AND whose events.log shows a worker.start within
#       WATCH_SIBLING_RECENT_SECS (default 259200 = 3 days):
#           <project-dir> <TAB> <seconds-dead-since-last-start> <TAB> <last worker.start ISO>
#       coordinator-watch.sh runs this on a timer and turns each line into one
#       deduped coord-inbox note. Exit 0 always.
#   watcher-check.sh --pause [project-dir] [reason...]
#       Silence the dead-watcher WARN for a planned stop (e.g. before
#       deploying updates). Does not kill anything. Starting the watcher again
#       clears it.
#   watcher-check.sh --resume [project-dir]
#       Remove both markers by hand.
#
# Exit: 0 fine/silenced/never-started, 3 watcher dead and not silenced,
#       2 usage error.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SELF_DIR")}"
NOW="$(date +%s)"

mtime_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# resolve_dir <arg>: absolute project dir, or exit 2.
resolve_dir() {
    local d="${1:-$PWD}"
    [ -d "$d" ] || { echo "watcher-check.sh: '$d' is not a directory" >&2; exit 2; }
    (cd "$d" && pwd -P)
}

state_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

# classify <project-dir>: sets
#   WC_STATE   running | stopped-deliberately | not-running | never-started
#   WC_PID     recorded pid (may be empty)
#   WC_SINCE   epoch the watcher was last known started (state file mtime)
#   WC_WHY     for stopped-deliberately: which marker
#   WC_STOPPED_AGE seconds since an expired marker (not-running only), else empty
classify() {
    local dir="$1" sf="$1/.swarm/coordinator-watch.state" m mt cmd
    WC_STATE="never-started"; WC_PID=""; WC_SINCE=0; WC_WHY=""; WC_STOPPED_AGE=""
    [ -r "$sf" ] || return 0
    WC_PID="$(state_get "$sf" pid)"
    WC_SINCE="$(mtime_epoch "$sf")"
    if [[ "$WC_PID" =~ ^[0-9]+$ ]] && kill -0 "$WC_PID" 2>/dev/null; then
        # Linux: make sure the live pid is still a coordinator-watch process.
        if [ -r "/proc/$WC_PID/cmdline" ]; then
            cmd="$(tr '\0' ' ' < "/proc/$WC_PID/cmdline" 2>/dev/null || true)"
            case "$cmd" in
                *coordinator-watch*) WC_STATE="running"; return 0 ;;
            esac
            # pid reused by something else: fall through to dead handling
        else
            WC_STATE="running"; return 0
        fi
    fi
    WC_STATE="not-running"
    for m in watcher-paused watcher-stopped; do
        [ -e "$dir/.swarm/$m" ] || continue
        mt="$(mtime_epoch "$dir/.swarm/$m")"
        # Marker from before the current watcher started: the watcher then
        # died on its own; the marker is stale.
        [ "$mt" -ge "$WC_SINCE" ] || continue
        if [ $((NOW - mt)) -le "$PAUSE_MAX_SECS" ]; then
            WC_STATE="stopped-deliberately"; WC_WHY="$m"; return 0
        fi
        WC_STOPPED_AGE=$((NOW - mt))
    done
    return 0
}

human_age() {
    local s="$1"
    if   [ "$s" -ge 86400 ]; then echo "$((s / 86400))d $((s % 86400 / 3600))h"
    elif [ "$s" -ge 3600 ];  then echo "$((s / 3600))h $((s % 3600 / 60))m"
    else echo "$((s / 60))m"; fi
}

restart_cmd() {
    printf 'cd %q && NON_INTERACTIVE=1 %q' "$1" "$LLM_SWARM_DIR/llm-start.sh"
}

print_warn() {
    local dir="$1" since_note=""
    if [ "$WC_SINCE" -gt 0 ]; then
        since_note=" The last watcher started $(human_age $((NOW - WC_SINCE))) ago and its process (pid ${WC_PID:-?}) is gone."
    fi
    [ -n "$WC_STOPPED_AGE" ] && since_note+=" It was stopped on purpose $(human_age "$WC_STOPPED_AGE") ago, longer than WATCHER_PAUSE_MAX_SECS=$PAUSE_MAX_SECS, so the pause no longer silences this."
    echo "WARN: coordinator-watch.sh is NOT running for $dir; outcomes, outbox files, ready sweeps and doorbells are not being delivered.$since_note"
    echo "WARN: restart it: $(restart_cmd "$dir")"
    echo "WARN: stopped it on purpose? Silence this with: $LLM_SWARM_DIR/scripts/watcher-check.sh --pause $dir"
}

# last_worker_start <project-dir>: prints "<epoch> <iso>" of the newest
# worker.start in the events log, nothing when none.
last_worker_start() {
    local log="$1/.swarm/events.log" iso ep
    [ -r "$log" ] || return 0
    iso="$(grep -a ' worker\.start ' "$log" 2>/dev/null | tail -n 1 | cut -d' ' -f1)"
    [ -n "$iso" ] || return 0
    ep="$(date -u -d "$iso" +%s 2>/dev/null)" || return 0
    printf '%s %s\n' "$ep" "$iso"
}

cmd_siblings() {
    local self="$1" parent f d ep iso roots r
    local -a states=()
    parent="$(dirname "$self")"
    roots=("$parent")
    if [ -n "${WATCH_SIBLING_ROOTS:-}" ]; then
        IFS=: read -r -a extra <<< "$WATCH_SIBLING_ROOTS"
        for r in "${extra[@]}"; do [ -d "$r" ] && roots+=("$r"); done
    fi
    for r in "${roots[@]}"; do
        while IFS= read -r f; do
            [ -n "$f" ] && states+=("$f")
        done < <(find "$r" -mindepth 3 -maxdepth 3 -path '*/.swarm/coordinator-watch.state' 2>/dev/null | sort)
    done
    local -A seen=()
    for f in "${states[@]}"; do
        d="${f%/.swarm/coordinator-watch.state}"
        case "$d" in *-worktrees/*|*/wt-issue-*) continue ;; esac
        d="$(cd "$d" 2>/dev/null && pwd -P)" || continue
        [ "$d" = "$self" ] && continue
        [ -n "${seen[$d]:-}" ] && continue
        seen[$d]=1
        classify "$d"
        [ "$WC_STATE" = "not-running" ] || continue
        read -r ep iso < <(last_worker_start "$d") || true
        [ -n "${ep:-}" ] || continue
        [ $((NOW - ep)) -le "$RECENT_SECS" ] || continue
        printf '%s\t%s\t%s\n' "$d" "$((NOW - WC_SINCE))" "$iso"
    done
}

mode="check"
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --status)   mode="status";   shift ;;
    --siblings) mode="siblings"; shift ;;
    --pause)    mode="pause";    shift ;;
    --resume)   mode="resume";   shift ;;
    -*) echo "watcher-check.sh: unknown option $1 (try --help)" >&2; exit 2 ;;
esac

dir="$(resolve_dir "${1:-$PWD}")" || exit 2
shift || true

# Project .swarm/.env and the sandbox defaults supply the knobs below.
# shellcheck source=_load-env.sh
. "$SELF_DIR/_load-env.sh" "$dir"
PAUSE_MAX_SECS="${WATCHER_PAUSE_MAX_SECS:-259200}"
RECENT_SECS="${WATCH_SIBLING_RECENT_SECS:-259200}"

case "$mode" in
    check)
        classify "$dir"
        if [ "$WC_STATE" = "not-running" ]; then print_warn "$dir"; exit 3; fi
        exit 0
        ;;
    status)
        classify "$dir"
        case "$WC_STATE" in
            running)              echo "running (pid $WC_PID)" ;;
            stopped-deliberately) echo "stopped-deliberately ($WC_WHY)" ;;
            not-running)          echo "not-running (pid ${WC_PID:-?} gone)" ;;
            never-started)        echo "never-started (no coordinator-watch.state)" ;;
        esac
        [ "$WC_STATE" = "not-running" ] && exit 3
        exit 0
        ;;
    siblings)
        cmd_siblings "$dir"
        exit 0
        ;;
    pause)
        mkdir -p "$dir/.swarm"
        printf '%s paused %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${*:-}" > "$dir/.swarm/watcher-paused"
        echo "paused: dead-watcher WARN silenced for $dir for up to $(human_age "$PAUSE_MAX_SECS") (or until a watcher starts)"
        exit 0
        ;;
    resume)
        rm -f "$dir/.swarm/watcher-paused" "$dir/.swarm/watcher-stopped"
        echo "resumed: markers removed for $dir"
        exit 0
        ;;
esac
