#!/usr/bin/env bash
#
# check-stuck-workers.sh — survey iss-* worker panes for unhealthy states.
#
# Reads project-dir → derives socket (swarm-<repo>) and session
# (llm-<repo>). Captures the last 50 lines of each iss-* pane, strips
# ANSI escapes, and pattern-matches against known healthy/attention/
# broken states. Prints a one-line-per-worker status table and exits
# non-zero if any worker needs eyes-on.
#
# This is a read-only diagnostic — does NOT send keys, kill panes, or
# touch containers. Intended to be:
#   - run by the user ad-hoc when something feels off
#   - called from coordinator-watch.sh on each wake (`if ! check ; then
#     surface in events.log`) so the coordinator sees stuck workers
#     before deciding to top up the swarm
#
# Pattern catalog (precedence order, most-specific first):
#   IDLE-PARKED            healthy: listener printed "[polling for next brief"
#                          after a task-complete status block (success or
#                          failure — a failed task's result belongs to PR/
#                          outcome-JSON review, not to "is this pane stuck")
#   ACTIVE                 healthy: spinner glyph (✻/✶) or "Considering…/Sautéed for/Cooked for"
#   EXITED-IDLE            healthy: container gone + clean Task-complete marker
#   CONTEXT-LARGE          suggestion: "/clear to save Nk tokens" visible
#   EXIT-CONFIRM-PENDING   needs-help: "Press Ctrl-C again to ?xit" visible
#   UNKNOWN                needs-help: no recognized pattern in last N lines
#   DEAD-PANE              broken: pane_dead=1 from tmux list-panes
#   ORPHANED-CONTAINER     broken: container gone, no clean-exit marker
#
# Exits:
#   0  all workers healthy (IDLE-PARKED / ACTIVE / EXITED-IDLE)
#   1  one or more workers in attention/broken states
#   2  usage / setup error

set -euo pipefail

# --- Help ---
case "${1:-}" in
    -h|--help)
        cat <<EOF
check-stuck-workers.sh — survey iss-* worker panes for unhealthy states

USAGE
    check-stuck-workers.sh [project-dir]

ARGUMENTS
    project-dir     Path to project root (default: \$PWD).
                    Used to derive socket (swarm-<basename>) and session
                    (llm-<basename>).

ENV VARS
    CAPTURE_LINES   How many trailing lines to capture per pane (default: 50).
    NO_COLOR        Set to any value to suppress ANSI color in output.

OUTPUT
    A table: WINDOW / PANE / STATE / DETAIL — one row per iss-* window.

EXIT
    0   all workers healthy
    1   one or more in attention/broken states (DEAD-PANE, ORPHANED-CONTAINER,
        EXIT-CONFIRM-PENDING, UNKNOWN)
    2   usage / setup error (e.g. no swarm session for this project)

EXAMPLES
    check-stuck-workers.sh                    # current project
    check-stuck-workers.sh /opt/work/fand-etl # specific project
EOF
        exit 0
        ;;
esac

PROJECT_DIR="$(cd "${1:-$PWD}" && pwd)"
REPO="$(basename "$PROJECT_DIR")"
SOCKET="swarm-$REPO"
SESSION="llm-$REPO"
CAPTURE_LINES="${CAPTURE_LINES:-50}"

# --- Color helpers ---
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_RST=''
fi

color_for() {
    case "$1" in
        IDLE-PARKED|ACTIVE|EXITED-IDLE)             printf '%s' "$C_GRN" ;;
        CONTEXT-LARGE|EXIT-CONFIRM-PENDING|UNKNOWN) printf '%s' "$C_YEL" ;;
        DEAD-PANE|ORPHANED-CONTAINER)               printf '%s' "$C_RED" ;;
        *)                                          printf '' ;;
    esac
}

# --- Verify swarm session exists ---
if ! tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: no tmux session '$SESSION' on socket '$SOCKET'" >&2
    echo "       (derived from project dir: $PROJECT_DIR)" >&2
    exit 2
fi

# --- ANSI-strip helper ---
# Strips CSI sequences (ESC [ ... letter) and OSC sequences. Good enough
# for the simple matches we do below; not a full terminal emulator.
strip_ansi() {
    sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g'
}

# --- State detection on captured pane content ---
# $1 = clean (ANSI-stripped) content. Echo state label.
#
# IMPORTANT: pipe content INTO grep rather than using a `<<<` here-string.
# Pane content contains stripped-ANSI residue and box-drawing UTF-8 bytes
# that can crash bash's here-string handling under the default UTF-8
# locale (silent subshell exit; grep never runs). LC_ALL=C on the grep
# invocations bypasses the multi-byte regex engine and is correct here
# since all our patterns are ASCII or known fixed Unicode (✻/✶/…).
detect_state() {
    local clean="$1"
    # Precedence: parked > active > exit-confirm > context-large > exited > unknown
    if printf '%s\n' "$clean" | LC_ALL=C grep -q '\[polling for next brief'; then
        echo IDLE-PARKED; return
    fi
    if printf '%s\n' "$clean" | LC_ALL=C grep -qE '(Considering…|Sautéed for|Cooked for|Baked for|Simmered for|✻|✶)'; then
        echo ACTIVE; return
    fi
    if printf '%s\n' "$clean" | LC_ALL=C grep -q 'Press Ctrl-C again to .xit'; then
        echo EXIT-CONFIRM-PENDING; return
    fi
    if printf '%s\n' "$clean" | LC_ALL=C grep -qE '/clear to save [0-9.]+k tokens'; then
        echo CONTEXT-LARGE; return
    fi
    if printf '%s\n' "$clean" | LC_ALL=C grep -q 'Resume this session with'; then
        echo EXITED-IDLE; return  # claude exited, listener probably parked
    fi
    echo UNKNOWN
}

# --- Iterate iss-* windows ---
windows="$(tmux -L "$SOCKET" list-windows -t "$SESSION" -F '#{window_name}' | grep '^iss-' || true)"

if [ -z "$windows" ]; then
    echo "(no iss-* windows in session $SESSION)"
    exit 0
fi

printf '%-12s  %-5s  %-22s  %s\n' "WINDOW" "PANE" "STATE" "DETAIL"
printf '%s\n' "----------------------------------------------------------------------------------"

EXIT=0
while IFS= read -r win; do
    [ -n "$win" ] || continue
    # First pane's index + dead flag
    pane_info="$(tmux -L "$SOCKET" list-panes -t "$SESSION:$win" -F '#{pane_dead}|#{pane_index}|#{pane_current_command}' | head -1)"
    IFS='|' read -r pane_dead pane_idx pane_cmd <<<"$pane_info"

    state=""; detail=""

    if [ "$pane_dead" = "1" ]; then
        state="DEAD-PANE"
        detail="pane exited non-zero; remain-on-exit kept it visible"
        EXIT=1
    else
        container="swarm-${SESSION}-${win}"
        container_alive=0
        if docker ps --format '{{.Names}}' | grep -qx "$container"; then
            container_alive=1
        fi

        content="$(tmux -L "$SOCKET" capture-pane -t "$SESSION:$win" -p -S "-$CAPTURE_LINES" 2>/dev/null || true)"
        clean="$(printf '%s' "$content" | strip_ansi)"
        state="$(detect_state "$clean")"

        if [ "$container_alive" -eq 0 ]; then
            # Container gone — refine state
            case "$state" in
                IDLE-PARKED|EXITED-IDLE) state="EXITED-IDLE"; detail="container gone; clean exit, listener parked" ;;
                *)                        state="ORPHANED-CONTAINER"; detail="container '$container' missing; pane state unclear"; EXIT=1 ;;
            esac
        else
            # Container alive — flesh out detail per state
            case "$state" in
                IDLE-PARKED)          detail="listener parked; ready for requeue.sh $REPO briefs" ;;
                ACTIVE)               detail="claude working (spinner / 'Considering...' visible)" ;;
                CONTEXT-LARGE)        detail="claude suggesting /clear (token count above threshold)" ;;
                EXIT-CONFIRM-PENDING) detail="Ctrl-C pressed once; awaiting confirmation or cancel"; EXIT=1 ;;
                EXITED-IDLE)          detail="claude exited inside container; listener should pick up next brief" ;;
                UNKNOWN)              detail="no recognized pattern in last $CAPTURE_LINES lines (cmd: $pane_cmd)"; EXIT=1 ;;
            esac
        fi
    fi

    color="$(color_for "$state")"
    printf '%-12s  %-5s  %s%-22s%s  %s\n' "$win" "$pane_idx" "$color" "$state" "$C_RST" "$detail"
done <<<"$windows"

exit $EXIT
