#!/usr/bin/env bash
#
# swarm-nudge.sh — HUMAN-ONLY escape hatch: type a line into a swarm pane.
# Not recommended; emergencies only (docs/tmux-as-channel.md §4). No agent and
# no watcher calls this; agents use the file bus (outbox, requeue.sh).
#
# usage: swarm-nudge.sh [--force] <project-dir> <window> "text"
#   <project-dir>  the swarm's project checkout (socket swarm-<basename>,
#                  session llm-<basename>, as capture-worker.sh derives them)
#   <window>       e.g. coordinator or iss-123
#
# Refuses (exit 3) when the pane looks busy (coord_pane_busy_visible with the
# watcher's busy pattern) or the composer is non-empty (compact_composer_clear,
# the watcher's own check, via scripts/_pane-composer.sh). --force sends anyway.
# Every send is logged to <project-dir>/.swarm/events.log (nudge.sent, or
# nudge.forced when --force overrode a refusal).
# Exit: 0 sent, 2 usage/target error, 3 refused.
set -euo pipefail

FORCE=0
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) POS+=("$1"); shift ;;
    esac
done
if [ "${#POS[@]}" -ne 3 ] || [ -z "${POS[2]}" ]; then
    echo 'usage: swarm-nudge.sh [--force] <project-dir> <window> "text"' >&2
    exit 2
fi
PROJECT_DIR="$(cd "${POS[0]}" 2>/dev/null && pwd)" || { echo "ERROR: no such project dir: ${POS[0]}" >&2; exit 2; }
WINDOW="${POS[1]}"
TEXT="${POS[2]}"
REPO="$(basename "$PROJECT_DIR")"
SOCKET="swarm-$REPO"
TARGET="llm-$REPO:$WINDOW.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"
# shellcheck source=_coord-layout.sh
. "$SCRIPT_DIR/_coord-layout.sh"
# shellcheck source=_pane-composer.sh
. "$SCRIPT_DIR/_pane-composer.sh"

# The shared helpers call plain `tmux`; point it at the swarm's socket.
tmux() { command tmux -L "$SOCKET" "$@"; }

tmux has-session -t "llm-$REPO" 2>/dev/null \
    || { echo "ERROR: no tmux session llm-$REPO on socket $SOCKET" >&2; exit 2; }
tmux list-windows -t "llm-$REPO" -F '#{window_name}' | grep -Fx -- "$WINDOW" >/dev/null \
    || { echo "ERROR: no window $WINDOW in session llm-$REPO" >&2; exit 2; }

reason=""
if coord_pane_busy_visible "$TARGET" "${AUTO_COMPACT_BUSY_PATTERN:-$PANE_BUSY_PATTERN_DEFAULT}"; then
    reason="pane_busy"
elif ! compact_composer_clear "$TARGET"; then
    reason="composer_not_clear"
fi

if [ -n "$reason" ] && [ "$FORCE" != 1 ]; then
    echo "REFUSED ($reason): $WINDOW is mid-turn or has text in its composer; keystrokes could corrupt it." >&2
    echo "Prefer the file bus (requeue.sh / outbox). Override with --force (logged)." >&2
    exit 3
fi

if [ -n "$reason" ]; then ev=nudge.forced; else ev=nudge.sent; fi
mkdir -p "$PROJECT_DIR/.swarm"
printf '%s  %-15s window=%s override=%s len=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$ev" \
    "$WINDOW" "${reason:-none}" "${#TEXT}" >> "$PROJECT_DIR/.swarm/events.log"

tmux send-keys -t "$TARGET" -l -- "$TEXT"
tmux send-keys -t "$TARGET" Enter
echo "sent to $WINDOW ($ev)"
