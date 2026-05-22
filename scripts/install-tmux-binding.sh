#!/usr/bin/env bash
#
# install-tmux-binding.sh — Install the Ctrl-Z worker escape-hatch binding
# into ~/.tmux.conf with the correct absolute path to this checkout baked
# in, then re-source the config on every running swarm-* tmux socket so
# existing swarms pick it up without a restart.
#
# Why a script instead of "copy this snippet from examples/tmux.conf.example"?
# The snippet hardcodes `/opt/work/llm-swarm-runner/scripts/tmux-worker-shell.sh`
# as an example, and if the user's clone is anywhere else, Ctrl-Z creates a
# sibling pane that immediately dies with `exit 127: No such file or directory`.
# This script self-locates its own checkout and writes the right path.
#
# Idempotent: managed block lives between sentinel markers and is rewritten
# in place on re-run. Re-sourcing is safe on already-bound sockets.
#
# Usage:
#   ./scripts/install-tmux-binding.sh             # install + reload
#   ./scripts/install-tmux-binding.sh --dry-run   # show what would change
#   ./scripts/install-tmux-binding.sh --uninstall # remove the managed block

set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_SHELL="$SCRIPT_DIR/tmux-worker-shell.sh"
TMUX_CONF="${TMUX_CONF:-$HOME/.tmux.conf}"

BEGIN_MARK="# >>> llm-swarm-runner ctrl-z binding (managed by install-tmux-binding.sh) >>>"
END_MARK="# <<< llm-swarm-runner ctrl-z binding (managed by install-tmux-binding.sh) <<<"

DRY_RUN=0
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'
            exit 0
            ;;
        *)
            red "unknown arg: $arg"
            exit 2
            ;;
    esac
done

# --- 1. Sanity-check the worker-shell script exists --------------------------
if [ ! -x "$WORKER_SHELL" ]; then
    red "Helper script not found or not executable: $WORKER_SHELL"
    red "This script must live in the same scripts/ dir as tmux-worker-shell.sh."
    exit 1
fi

# --- 2. Build the managed block ----------------------------------------------
read -r -d '' MANAGED_BLOCK <<EOF || true
$BEGIN_MARK
# Worker (iss-*) Ctrl-Z escape hatch. In any iss-* window, Ctrl-Z splits
# a sibling bash pane that docker-execs into the same worker container as
# a login shell. Claude in the original pane is untouched. In any other
# window, Ctrl-Z falls through to normal behavior.
#
# Path below is baked in by scripts/install-tmux-binding.sh — re-run that
# script if you move this checkout.
bind-key -n C-z if-shell -F '#{m:iss-*,#{window_name}}' \\
    'split-window -h "$WORKER_SHELL"' \\
    'if-shell -F "#{==:#{window_name},coordinator}" \\
        "display-message \"Ctrl-Z swallowed in coordinator window\"" \\
        "send-keys C-z"'
$END_MARK
EOF

# --- 3. Read existing tmux.conf (touch if missing) ---------------------------
if [ ! -f "$TMUX_CONF" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        yellow "[dry-run] would create $TMUX_CONF"
        EXISTING=""
    elif [ "$UNINSTALL" -eq 1 ]; then
        yellow "$TMUX_CONF does not exist — nothing to uninstall."
        exit 0
    else
        touch "$TMUX_CONF"
        EXISTING=""
    fi
else
    EXISTING="$(cat "$TMUX_CONF")"
fi

# --- 4. Compute new content --------------------------------------------------
# Strip any existing managed block (idempotency); we'll re-append if installing.
if grep -qF "$BEGIN_MARK" "$TMUX_CONF" 2>/dev/null; then
    HAD_MANAGED=1
    STRIPPED="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skipping=1; next }
        $0 == e { skipping=0; next }
        !skipping { print }
    ' "$TMUX_CONF")"
else
    HAD_MANAGED=0
    STRIPPED="$EXISTING"
fi

# --- 5. Warn about unmanaged duplicate bindings ------------------------------
# A previous manual copy of the binding (e.g. pasted from
# examples/tmux.conf.example) lives outside the managed markers and isn't
# touched by this script. Multi-line bindings can't be matched with a
# single-line regex, so we check the stripped version (managed block
# removed) for any `tmux-worker-shell` reference — anything that survives
# is unmanaged.
if [ "$UNINSTALL" -eq 0 ] && echo "$STRIPPED" | grep -q 'tmux-worker-shell'; then
    yellow "Note: another C-z worker-shell binding exists in $TMUX_CONF outside the managed block:"
    echo "$STRIPPED" | grep -n 'tmux-worker-shell' | sed 's/^/  /'
    yellow "  tmux's last-binding-wins semantics mean the managed block (appended last) will take effect,"
    yellow "  but you may want to delete the stray copy manually."
fi

if [ "$UNINSTALL" -eq 1 ]; then
    if [ "$HAD_MANAGED" -eq 0 ]; then
        yellow "No managed block found in $TMUX_CONF — nothing to uninstall."
        exit 0
    fi
    NEW_CONTENT="$STRIPPED"
else
    # Append managed block, separated by a single blank line if file is non-empty.
    if [ -n "${STRIPPED//[[:space:]]/}" ]; then
        NEW_CONTENT="${STRIPPED%$'\n'}"$'\n\n'"$MANAGED_BLOCK"$'\n'
    else
        NEW_CONTENT="$MANAGED_BLOCK"$'\n'
    fi
fi

# --- 6. Write the file (or print diff in dry-run) ----------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo
    yellow "[dry-run] would write to $TMUX_CONF:"
    diff -u <(printf '%s' "$EXISTING") <(printf '%s' "$NEW_CONTENT") || true
    echo
    yellow "[dry-run] no changes made."
    exit 0
fi

BACKUP="${TMUX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
if [ -f "$TMUX_CONF" ]; then
    cp -p "$TMUX_CONF" "$BACKUP"
    green "Backed up existing config to $BACKUP"
fi
printf '%s' "$NEW_CONTENT" > "$TMUX_CONF"

if [ "$UNINSTALL" -eq 1 ]; then
    green "Removed managed block from $TMUX_CONF"
else
    green "Installed/updated managed block in $TMUX_CONF (helper path: $WORKER_SHELL)"
fi

# --- 7. Reload on default socket + every running swarm-* socket --------------
RUN_DIR="/tmp/tmux-$(id -u)"
SOCKETS=()
# Default tmux socket is just "default"; only reload it if it has a server.
if command tmux ls >/dev/null 2>&1; then
    SOCKETS+=(default)
fi
if [ -d "$RUN_DIR" ]; then
    for s in "$RUN_DIR"/swarm-*; do
        [ -S "$s" ] || continue
        SOCKETS+=("$(basename "$s")")
    done
fi

if [ "${#SOCKETS[@]}" -eq 0 ]; then
    yellow "No running tmux servers found — nothing to reload."
    exit 0
fi

echo
green "Reloading config on ${#SOCKETS[@]} tmux socket(s):"
for sock in "${SOCKETS[@]}"; do
    if command tmux -L "$sock" source-file "$TMUX_CONF" 2>/dev/null; then
        # Verify the binding is actually present after the reload.
        if command tmux -L "$sock" list-keys -T root 2>/dev/null | grep -q 'C-z.*tmux-worker-shell'; then
            green "  $sock — reloaded, C-z binding active"
        else
            yellow "  $sock — reloaded, but C-z binding not detected (check for syntax errors)"
        fi
    else
        red   "  $sock — source-file failed"
    fi
done

if [ "$UNINSTALL" -eq 0 ]; then
    echo
    green "Done. In any iss-* window: Ctrl-Z opens a sibling bash pane in the same container."
fi
