#!/usr/bin/env bash
# tmux-worker-shell.sh — Open a login shell inside a swarm worker container.
#
# Invoked by the `bind-key -n C-z` worker escape hatch in ~/.tmux.conf.
# split-window calls this script; the script resolves the current session
# and window name via `tmux display-message -p` (which DOES expand #{...}
# formats — unlike split-window's literal shell-command argument), then
# execs into the matching swarm-<session>-<window> container.
#
# Container naming must stay in sync with provision-worker.sh.
#
# Errors print a friendly message and exit non-zero so the pane stays
# "[dead]" under remain-on-exit=failed, leaving the diagnosis visible.

set -euo pipefail

# Resolve our own pane's context. `tmux display-message -p` without -t
# defaults to the *attached client's* active pane, NOT the pane this script
# is running in — so it returns the wrong session/window whenever the user
# is currently looking at a different window. $TMUX_PANE is the canonical
# self-reference (tmux exports it into every pane's env), and -t accepts it.
: "${TMUX_PANE:?TMUX_PANE not set — this script must run inside a tmux pane}"
eval "$(tmux display-message -p -t "$TMUX_PANE" -F 'SESSION=#{session_name}; WINDOW=#{window_name}')"

CONTAINER="swarm-${SESSION}-${WINDOW}"

if ! docker ps --format '{{.Names}}' | grep -x "$CONTAINER" >/dev/null; then
    echo "tmux-worker-shell: container '$CONTAINER' is not running." >&2
    echo "tmux-worker-shell: expected swarm-<tmux-session>-<window-name>; check provision-worker.sh." >&2
    docker ps --format '  {{.Names}}\t{{.Status}}' | grep -i swarm >&2 || true
    exit 1
fi

exec docker exec -it "$CONTAINER" bash -l
