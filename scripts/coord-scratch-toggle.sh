#!/usr/bin/env bash
# coord-scratch-toggle.sh — Toggle a bare-bash "scratch" pane next to the
# coordinator. Invoked by the Ctrl-Z binding in the coordinator window
# (see install-tmux-binding.sh).
#
# First press: split a new bash pane to the right of the active pane in
# the coordinator window, started in the session's launch directory
# (the repo root — no worktree, no container), and tag it with the pane
# title 'coord-scratch' so we can find it again.
#
# Second press (from anywhere in the coordinator window, including from
# inside the scratch pane itself): kill the tagged pane.
#
# The pane title is the source of truth, which keeps this idempotent and
# index-free — pane indices shift around as splits/swaps happen, titles
# don't. If a user manually retitles or kills the scratch pane, the next
# Ctrl-Z just creates a fresh one.
#
# Why a separate script and not inline `if-shell` in tmux.conf? Iterating
# panes to find one by title takes a real shell pipeline; cramming awk and
# nested quoting into a tmux key-binding is unreadable and brittle.
#
# Errors here are silent on purpose — a binding that prints to a random
# pane on every keypress is worse than one that does nothing visible.

set -euo pipefail

: "${TMUX_PANE:?TMUX_PANE not set — this script must run from a tmux key binding}"

WINDOW_ID="$(tmux display-message -p -t "$TMUX_PANE" -F '#{window_id}')"

# Find an existing scratch pane in this window by its title tag.
SCRATCH_PANE="$(tmux list-panes -t "$WINDOW_ID" -F '#{pane_id} #{pane_title}' \
    | awk '$2 == "coord-scratch" { print $1; exit }')"

if [ -n "$SCRATCH_PANE" ]; then
    tmux kill-pane -t "$SCRATCH_PANE"
    exit 0
fi

# Spawn fresh. Prefer the session's launch directory (repo root) over the
# active pane's pwd — the coordinator pane's pwd is wherever claude was
# started, which is what the user wants anyway, but `session_path` is the
# more stable anchor when claude has chdir'd internally.
SESSION_PATH="$(tmux display-message -p -t "$TMUX_PANE" -F '#{session_path}')"

NEW_PANE="$(tmux split-window -h -P -F '#{pane_id}' \
    -t "$TMUX_PANE" -c "$SESSION_PATH")"

# Tag for the next toggle press. -T sets pane_title; this also disables
# automatic-rename for the pane title (the shell's escape sequences won't
# overwrite it), which is exactly what we want — the tag must survive.
tmux select-pane -t "$NEW_PANE" -T coord-scratch
