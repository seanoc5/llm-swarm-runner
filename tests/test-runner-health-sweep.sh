#!/usr/bin/env bash
#
# test-runner-health-sweep.sh — issue #899: the watcher's runner_health_sweep_pass
# writes ONE urgent coord-inbox note per runner outage (not one per tick),
# clears its dedup when the runner recovers, and rings once. A fake
# ci-runner-health.sh stands in for GitHub. No tmux, no claude, no network.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { if [ "$2" = "$3" ]; then green "$1"; else red "$1 (expected [$2] got [$3])"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/scripts/coordinator-watch.sh"
T="$(mktemp -d -t runner-health-sweep-XXXXXX)"; trap 'rm -rf "$T"' EXIT
P="$T/proj"; mkdir -p "$P/.swarm"
git -C "$P" init -q; git -C "$P" remote add origin https://github.com/o/repo.git

eval "$(sed -n '/^runner_health_sweep_pass() {/,/^}/p; /^runner_offline_ring_pass() {/,/^}/p; /^coord_inbox_write() {/,/^}/p; /^log_event() {/,/^}/p' "$WATCH")"
declare -A RUNNER_HEALTH_LOGGED=()
PROJECT_DIR="$P"; DRY_RUN=0
COORD_INBOX_DIR="$P/.swarm/coord-inbox"; COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$COORD_INBOX_DIR/.self"; EVENTS_LOG="$P/.swarm/events.log"
RUNNER_OFFLINE_RING_DIR="$P/.swarm/runner-offline-ring-pending"
RINGS="$T/rings.log"; : > "$RINGS"
coord_ring_doorbell() { echo "$*" >> "$RINGS"; }
coord_split_flag_urgent() { :; }

# Fake check: prints $T/mode's canned output and exit code. Records its args.
CI_RUNNER_HEALTH="$T/fake-health.sh"
cat > "$CI_RUNNER_HEALTH" <<FAKE
#!/usr/bin/env bash
echo "\$*" > "$T/args"
case "\$(cat "$T/mode")" in
  down) echo '{"check":"runner-offline-with-queue","severity":"error","line":0,"match":"o/repo r1","message":"runner r1 is offline; restart it: sudo systemctl restart actions.runner.o-repo.r1.service","repo":"o/repo","runner":"r1","queued_mins":30}'; exit 1 ;;
  warn) echo '{"check":"queue-long","severity":"warn","line":0,"match":"o/repo","message":"queue long","repo":"o/repo","runner":"","queued_mins":15}'; exit 1 ;;
  fail) echo "ci-runner-health: gh api failed (HTTP 403)"; exit 2 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$CI_RUNNER_HEALTH"
notes() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-runner_offline-*.md' | wc -l; }

echo down > "$T/mode"
runner_health_sweep_pass
check "repo is taken from the origin remote" "o/repo" "$(cat "$T/args")"
check "an offline runner with a queue writes one note" 1 "$(notes)"
case "$(cat "$COORD_INBOX_DIR"/*-runner_offline-*.md)" in *"sudo systemctl restart actions.runner.o-repo.r1.service"*) got=yes ;; *) got=no ;; esac
check "the note carries the exact restart command" yes "$got"
check "events.log gets a watch.runner_offline line" 1 "$(grep -c 'watch.runner_offline' "$EVENTS_LOG")"
runner_health_sweep_pass; runner_health_sweep_pass
check "later ticks of the same outage write no more notes" 1 "$(notes)"
runner_offline_ring_pass; runner_offline_ring_pass
check "the doorbell rings exactly once" "runner_offline count=1 runners=o-repo.r1" "$(cat "$RINGS")"

echo ok > "$T/mode"; runner_health_sweep_pass
check "dedup clears once the runner is healthy" 0 "${#RUNNER_HEALTH_LOGGED[@]}"
echo down > "$T/mode"; runner_health_sweep_pass
check "a second outage is noted again" 2 "$(notes)"

echo fail > "$T/mode"; runner_health_sweep_pass; runner_health_sweep_pass
check "a gh failure is logged once, writes no note" "1|2" "$(grep -c 'watch.runner_health_error' "$EVENTS_LOG")|$(notes)"
echo down > "$T/mode"; runner_health_sweep_pass
check "a failed tick keeps the dedup: still one note per outage" 2 "$(notes)"

echo ok > "$T/mode"; runner_health_sweep_pass
echo warn > "$T/mode"; runner_health_sweep_pass; runner_health_sweep_pass
check "warn findings are logged once and write no note" "1|2" "$(grep -c 'watch.runner_health ' "$EVENTS_LOG")|$(notes)"
echo "all runner-health sweep tests passed"
