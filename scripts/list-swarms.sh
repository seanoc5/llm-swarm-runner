#!/usr/bin/env bash
#
# list-swarms.sh — enumerate per-project tmux swarm sockets, LIVE vs ORPHAN.
#
# Each swarm runs on its own tmux server, addressed via a per-project
# socket name (`swarm-<basename-of-project-dir>`, see llm-start.sh).
# This script walks /tmp/tmux-$UID/ and reports:
#   - LIVE   : `tmux -L <socket> list-sessions` succeeds
#   - ORPHAN : socket file lingers but no live server is bound to it
#
# Read-only. Does NOT clean up orphan sockets — see --prune for that.
#
# Exit:
#   0  ran successfully (regardless of mix of LIVE/ORPHAN)
#   2  usage error

set -euo pipefail

PRUNE=0
case "${1:-}" in
    -h|--help)
        cat <<EOF
list-swarms.sh — list per-project tmux swarm sockets with status

USAGE
    list-swarms.sh [--prune]

OPTIONS
    --prune     After listing, delete socket files for ORPHAN entries.
                Safe: list-sessions already confirmed no live server.

OUTPUT
    Table: SOCKET / STATUS / SESSIONS / WINDOWS / ATTACH-CMD
    ATTACH-CMD is a ready-to-paste tmux invocation for LIVE swarms.

EXAMPLES
    list-swarms.sh                 # just list
    list-swarms.sh --prune         # list, then rm orphan socket files
EOF
        exit 0
        ;;
    --prune) PRUNE=1 ;;
    "") ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
esac

SOCK_DIR="/tmp/tmux-$(id -u)"
if [ ! -d "$SOCK_DIR" ]; then
    echo "no tmux socket dir at $SOCK_DIR — no swarms (or no tmux ever ran)" >&2
    exit 0
fi

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    C_GRN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_GRN=''; C_RED=''; C_DIM=''; C_RST=''
fi

printf "%-32s %-7s %-28s %-8s %s\n" "SOCKET" "STATUS" "SESSIONS" "WINDOWS" "ATTACH-CMD"
printf "%-32s %-7s %-28s %-8s %s\n" "------" "------" "--------" "-------" "----------"

orphans=()
for sock in "$SOCK_DIR"/*; do
    [ -e "$sock" ] || continue
    name=$(basename "$sock")
    if out=$(command tmux -L "$name" list-sessions -F '#{session_name}:#{session_windows}' 2>/dev/null); then
        sessions=$(echo "$out" | cut -d: -f1 | paste -sd, -)
        windows=$(echo "$out" | cut -d: -f2 | awk '{print $0"w"}' | paste -sd, -)
        first_session=$(echo "$out" | head -1 | cut -d: -f1)
        attach="tmux -L $name attach -t $first_session"
        printf "%s%-32s %-7s %-28s %-8s %s%s\n" "$C_GRN" "$name" "LIVE" "$sessions" "$windows" "$attach" "$C_RST"
    else
        printf "%s%-32s %-7s %-28s %-8s %s%s\n" "$C_RED" "$name" "ORPHAN" "-" "-" "(socket file lingering)" "$C_RST"
        orphans+=("$sock")
    fi
done

if [ "$PRUNE" = "1" ] && [ "${#orphans[@]}" -gt 0 ]; then
    echo
    echo "${C_DIM}Pruning ${#orphans[@]} orphan socket(s)...${C_RST}"
    for sock in "${orphans[@]}"; do
        rm -v "$sock"
    done
fi
