#!/usr/bin/env bash
# shellcheck disable=SC2034  # COORD_HOOK_* are read by helpers eval'd from coordinator-watch.sh
# test-coord-hook.sh — issue #666: the coordinator's Claude Code hooks write
# an explicit state file and ring the inbox doorbell at turn end; the
# watcher reads that state instead of the screen and does not re-paste a
# wake the hook already rang. No tmux, no claude: the hook is driven with
# the JSON Claude Code would send, and coordinator-claude.sh with a stub.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/coord-hook.sh"
WATCH="$ROOT/scripts/coordinator-watch.sh"
T="$(mktemp -d -t coord-hook-XXXXXX)"
trap 'rm -rf "$T"' EXIT
P="$T/proj"; mkdir -p "$P/.swarm/coord-inbox"

hook() {   # <event> [stdin-json]
    printf '%s' "${2:-{\}}" | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE="${HS:-1}" "$HOOK" "$1"
}
state() { cut -d' ' -f1 "$P/.swarm/coordinator-state" 2>/dev/null || echo none; }

# ── the hook ────────────────────────────────────────────────────────────────
out="$(HS=0 hook UserPromptSubmit)"
check "COORD_HOOK_STATE=0: hook is a silent no-op" "none|" "$(state)|$out"

hook UserPromptSubmit >/dev/null
check "UserPromptSubmit -> busy" "busy" "$(state)"

out="$(hook Stop '{"stop_hook_active":false}')"
check "Stop with an empty inbox -> idle, no block" "idle|" "$(state)|$out"

hook Notification >/dev/null
check "Notification -> waiting" "waiting" "$(state)"

echo 1 > "$P/.swarm/coord-hook-rang"   # an old ring, epoch 1
echo "worker 12 finished" > "$P/.swarm/coord-inbox/a.md"
out="$(hook Stop '{"stop_hook_active":false}')"
check "Stop with a new inbox item -> block" "block" "$(jq -r .decision <<<"$out")"
case "$(jq -r .reason <<<"$out")" in
    "Inbox: 1 item(s) in .swarm/coord-inbox/"*) got=nudge ;; *) got="$(jq -r .reason <<<"$out")" ;;
esac
check "block reason is the watcher's own nudge text" "nudge" "$got"
check "ringing keeps the state busy (the turn continues)" "busy" "$(state)"
grep -q 'coord.wake.hook_rang items=1' "$P/.swarm/events.log" && got=yes || got=no
check "ring logged to events.log" "yes" "$got"
rang="$(cut -d' ' -f1 "$P/.swarm/coord-hook-rang")"
[ "$rang" -gt 1 ] && got=yes || got=no
check "ring recorded in coord-hook-rang" "yes" "$got"

out="$(hook Stop '{"stop_hook_active":true}')"
check "stop_hook_active=true -> never rings twice in one turn end" "idle|" "$(state)|$out"

out="$(hook Stop '{"stop_hook_active":false}')"
check "no item newer than the last ring -> no repeat ring" "idle|" "$(state)|$out"

# The hook and the watcher must agree on the nudge text: the watcher spots
# its own doorbell in the transcript by it.
hook_t="$(sed -n 's/^template="\${COORD_INBOX_NUDGE_TEMPLATE:-\(.*\)}"$/\1/p' "$HOOK")"
watch_t="$(sed -n 's/^COORD_INBOX_NUDGE_TEMPLATE="\${COORD_INBOX_NUDGE_TEMPLATE:-\(.*\)}"$/\1/p' "$WATCH")"
[ -n "$hook_t" ] && [ "$hook_t" = "$watch_t" ] && got=same || got="hook=[$hook_t] watch=[$watch_t]"
check "hook and watcher share the nudge template default" "same" "$got"

# ── the watcher helpers ─────────────────────────────────────────────────────
eval "$(sed -n '/^coord_hook_state() {/,/^}/p; /^coord_wake_pane_busy() {/,/^}/p; /^coord_hook_rang_since() {/,/^}/p' "$WATCH")"
COORD_HOOK_STATE_FILE="$P/.swarm/coordinator-state"
COORD_HOOK_RANG_FILE="$P/.swarm/coord-hook-rang"
COORD_HOOK_BUSY_MAX_SECS=3600
coordinator_pane_busy() { [ "$SCREEN" = busy ]; }
now="$(date +%s)"
pb() { coord_wake_pane_busy && echo busy || echo idle; }

COORD_HOOK_STATE=0; SCREEN=busy; echo "idle $now" > "$COORD_HOOK_STATE_FILE"
check "feature off -> screen decides" "busy" "$(pb)"
COORD_HOOK_STATE=1
check "fresh idle file overrides a busy-looking screen" "idle" "$(pb)"
SCREEN=idle; echo "busy $now" > "$COORD_HOOK_STATE_FILE"
check "fresh busy file overrides an idle-looking screen" "busy" "$(pb)"
SCREEN=idle; echo "busy $((now - 7200))" > "$COORD_HOOK_STATE_FILE"
check "busy older than COORD_HOOK_BUSY_MAX_SECS -> screen decides" "idle" "$(pb)"
SCREEN=busy; rm -f "$COORD_HOOK_STATE_FILE"
check "missing file -> screen decides" "busy" "$(pb)"

echo "$now 1" > "$COORD_HOOK_RANG_FILE"
coord_hook_rang_since "$((now - 10))" && got=yes || got=no
check "rang after the wake went pending -> delivered" "yes" "$got"
coord_hook_rang_since "$((now + 10))" && got=yes || got=no
check "rang before the wake went pending -> not delivered" "no" "$got"

# ── coordinator-claude.sh wiring ───────────────────────────────────────────
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %q\n' "$T/argv" > "$T/bin/claude"; chmod +x "$T/bin/claude"
run_wrapper() {
    echo sys > "$T/sys"; echo hi > "$T/init"
    (cd "$P" && PATH="$T/bin:$PATH" COORD_HOOK_STATE="$1" "$ROOT/scripts/coordinator-claude.sh" "$T/sys" "$T/init")
}
run_wrapper 0
grep -qx -- '--settings' "$T/argv" && got=yes || got=no
check "COORD_HOOK_STATE=0: no --settings passed" "no" "$got"
run_wrapper 1
settings="$(grep -A1 -x -- '--settings' "$T/argv" | tail -1)"
got="$(jq -r '[.hooks | keys[]] | sort | join(",")' <<<"$settings" 2>/dev/null || echo invalid)"
check "COORD_HOOK_STATE=1: --settings installs the three hooks" "Notification,Stop,UserPromptSubmit" "$got"
cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' <<<"$settings")"
out="$(printf '{}' | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE=1 bash -c "$cmd" && state)"
check "the installed Stop command runs coord-hook.sh" "idle" "$out"
