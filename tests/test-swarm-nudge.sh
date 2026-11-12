#!/usr/bin/env bash
#
# test-swarm-nudge.sh — swarm-nudge.sh (issue #585): refuses on a non-empty
# composer or busy pane, sends on a clear one, --force overrides and logs.
# Stub pane: a real tmux session on a private socket running `cat`-style
# shell that prints a fake composer line.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || red "tmux not found"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUDGE="$SCRIPT_DIR/../scripts/swarm-nudge.sh"
T="$(mktemp -d -t swarm-nudge-XXXXXX)"
PROJ="$T/nudgeproj"; mkdir -p "$PROJ"
SOCK="swarm-nudgeproj"; SESS="llm-nudgeproj"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

# Window runs a script that draws a pane, then echoes whatever it is sent.
cat > "$T/pane.sh" <<'PANE'
#!/usr/bin/env bash
printf '%s\n' "$1"
printf '❯ %s\n' "$2"
while IFS= read -r line; do printf 'GOT:%s\n' "$line"; done
PANE
chmod +x "$T/pane.sh"
tmux -L "$SOCK" new-session -d -s "$SESS" -n coordinator -x 120 -y 30 "$T/pane.sh idle ''"
sleep 0.5
rc() { set +e; "$@" >"$T/out" 2>&1; echo $?; set -e; }
got() { tmux -L "$SOCK" capture-pane -t "$SESS:coordinator.0" -p | grep -c "GOT:$1" || true; }

# 1. clear composer -> sends
[ "$(rc "$NUDGE" "$PROJ" coordinator hello)" = 0 ] || red "clear composer should send: $(cat "$T/out")"
sleep 0.3; [ "$(got hello)" = 1 ] || red "hello not delivered"
grep -q 'nudge.sent' "$PROJ/.swarm/events.log" || red "send not logged"
green "clear composer sends and logs nudge.sent"

# 2. non-empty composer -> refuses, nothing delivered
tmux -L "$SOCK" kill-server; sleep 0.2
tmux -L "$SOCK" new-session -d -s "$SESS" -n coordinator -x 120 -y 30 "$T/pane.sh idle 'half-typed draft'"
sleep 0.5
[ "$(rc "$NUDGE" "$PROJ" coordinator blocked)" = 3 ] || red "dirty composer should refuse (3)"
grep -q composer_not_clear "$T/out" || red "refusal should name composer_not_clear"
sleep 0.3; [ "$(got blocked)" = 0 ] || red "refused text was delivered"
green "non-empty composer refuses (exit 3), nothing sent"

# 3. --force sends and logs nudge.forced
[ "$(rc "$NUDGE" --force "$PROJ" coordinator forced)" = 0 ] || red "--force should send"
sleep 0.3; [ "$(got forced)" = 1 ] || red "forced text not delivered"
grep -q 'nudge.forced.*override=composer_not_clear' "$PROJ/.swarm/events.log" || red "forced send not logged"
green "--force sends and logs nudge.forced"

# 4. busy pane -> refuses
tmux -L "$SOCK" kill-server; sleep 0.2
tmux -L "$SOCK" new-session -d -s "$SESS" -n coordinator -x 120 -y 30 "$T/pane.sh '✻ Working (esc to interrupt)' ''"
sleep 0.5
[ "$(rc "$NUDGE" "$PROJ" coordinator busy)" = 3 ] || red "busy pane should refuse (3)"
grep -q pane_busy "$T/out" || red "refusal should name pane_busy"
green "busy pane refuses"

# 5. bad window / usage -> exit 2
[ "$(rc "$NUDGE" "$PROJ" nowin x)" = 2 ] || red "unknown window should exit 2"
[ "$(rc "$NUDGE" "$PROJ")" = 2 ] || red "usage error should exit 2"
green "bad target and usage exit 2"
