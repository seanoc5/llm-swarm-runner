#!/usr/bin/env bash
#
# test-shape-host-admission.sh — shape tests for the host-wide admission
# check in provision-worker.sh (2026-09-29): pending-spawn markers count
# toward HOST_MAX_WORKERS, load / memory / stagger refusals are exit 3 with
# a cap.refused reason, and _load-env.sh ignores HOST_* keys in a project's
# .swarm/.env. Stubs gh/tmux/docker like test-shape-orchestration.sh.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"

TEST_DIR=$(mktemp -d -t shape-host-admission-XXXXXX)
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/host-state"

# Minimal project: a git repo with one commit, a .swarm dir, no .swarm/.env.
PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR/.swarm"
git -C "$PROJECT_DIR" init -q -b master
git -C "$PROJECT_DIR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git clone -q --bare "$PROJECT_DIR" "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" remote add origin "$TEST_DIR/origin.git"
git -C "$PROJECT_DIR" fetch -q origin

cat > "$TEST_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    echo "FAKE-GH issue #${3:-?}: synthetic body for shape test"; exit 0
fi
echo "stub-gh: unhandled args: $*" >&2; exit 1
STUB
cat > "$TEST_DIR/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    has-session)   exit 0 ;;
    list-windows)  echo "coordinator"; echo "util" ;;
    new-window)    echo "\$*" >> "$TEST_DIR/tmux.log" ;;
esac
exit 0
STUB
cat > "$TEST_DIR/bin/docker" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "ps" ]; then cat "$TEST_DIR/docker-containers.txt" 2>/dev/null; fi
exit 0
STUB
chmod +x "$TEST_DIR"/bin/*
export PATH="$TEST_DIR/bin:$PATH"
export HOST_STATE_DIR="$TEST_DIR/host-state"
export LLM_SWARM_DIR="$TEST_DIR/sandbox"
mkdir -p "$LLM_SWARM_DIR"
printf 'HOST_MAX_WORKERS=2\n' > "$LLM_SWARM_DIR/.env.example"
cp "$SCRIPT_DIR/../sandbox.sh" "$LLM_SWARM_DIR/sandbox.sh"
mkdir -p "$LLM_SWARM_DIR/scripts" && cp "$SCRIPT_DIR"/../scripts/_load-env.sh "$LLM_SWARM_DIR/scripts/"
cp "$SCRIPT_DIR"/../scripts/provision-worker.sh "$LLM_SWARM_DIR/scripts/"
cp "$SCRIPT_DIR"/../scripts/lint-brief.sh "$LLM_SWARM_DIR/scripts/" 2>/dev/null || true
PROVISION="$LLM_SWARM_DIR/scripts/provision-worker.sh"

run_prov() {  # $1 issue, rest = env assignments; prints exit code
    local issue="$1"; shift
    set +e
    ( cd "$PROJECT_DIR" && env "$@" bash ${TRACE:+-x} "$PROVISION" "$issue" > "$TEST_DIR/prov-$issue.log" 2>&1 )
    local rc=$?
    set -e
    echo "$rc"
}
# issue #493: this stub's docker never reports the just-spawned issue's own
# container as running (docker-containers.txt here tracks only the
# HOST_MAX_WORKERS cap scenario, under different container names) — same
# gap as test-shape-orchestration.sh's stub. PROVISION_SPAWN_CHECK_SECS=0
# disables provision-worker.sh's unrelated post-spawn health check so it
# doesn't misread every admitted spawn here as a failed one; spawn health
# is covered for real by test-shape-provision-stale-container.sh instead.
off="HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0 PROVISION_SPAWN_CHECK_SECS=0"

heading "1: admitted spawn leaves a pending marker; marker counts toward the cap"
: > "$TEST_DIR/docker-containers.txt"
# shellcheck disable=SC2086
rc=$(run_prov 11 $off)
[ "$rc" -eq 0 ] || red "first spawn should be admitted, rc=$rc: $(cat "$TEST_DIR/prov-11.log")"
[ -e "$HOST_STATE_DIR/pending-swarm-llm-proj-iss-11" ] || red "pending marker missing"
echo "swarm-other-iss-1" > "$TEST_DIR/docker-containers.txt"   # 1 running + 1 pending = cap 2
# shellcheck disable=SC2086
rc=$(run_prov 12 $off)
[ "$rc" -eq 3 ] || red "second spawn should be refused by running+pending, rc=$rc: $(cat "$TEST_DIR/prov-12.log")"
grep -q 'reason=host_max_workers running=2 pending=1' "$PROJECT_DIR/.swarm/events.log" || red "expected pending=1 in cap.refused event"
green "pending marker counted (running=1 + pending=1 >= 2)"

heading "2: marker is dropped once the container is visible"
echo "swarm-llm-proj-iss-11" > "$TEST_DIR/docker-containers.txt"  # the pending one is now running
# shellcheck disable=SC2086
rc=$(run_prov 12 $off)
[ "$rc" -eq 0 ] || red "spawn should be admitted once marker resolves, rc=$rc: $(cat "$TEST_DIR/prov-12.log")"
[ ! -e "$HOST_STATE_DIR/pending-swarm-llm-proj-iss-11" ] || red "resolved marker should be removed"
green "resolved marker removed, 1 running + 0 pending < 2 admits"

heading "3: load, memory and stagger refusals"
rm -f "$HOST_STATE_DIR"/pending-* "$HOST_STATE_DIR/last-spawn"
: > "$TEST_DIR/docker-containers.txt"
printf '99.00 50.00 20.00 1/1 1\n' > "$TEST_DIR/loadavg"
printf 'MemTotal: 131072000 kB\nMemAvailable: 4194304 kB\n' > "$TEST_DIR/meminfo"
rc=$(run_prov 13 HOST_LOADAVG_FILE="$TEST_DIR/loadavg" HOST_MAX_LOAD1=48 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=0)
[ "$rc" -eq 3 ] && grep -q 'reason=host_load load1=99.00 max=48' "$PROJECT_DIR/.swarm/events.log" || red "load refusal: rc=$rc $(cat "$TEST_DIR/prov-13.log")"
green "load1 99 > 48 refused (exit 3, reason=host_load)"
rc=$(run_prov 13 HOST_MEMINFO_FILE="$TEST_DIR/meminfo" HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=16384 HOST_SPAWN_STAGGER_SECS=0)
[ "$rc" -eq 3 ] && grep -q 'reason=host_mem avail_mb=4096 min_mb=16384' "$PROJECT_DIR/.swarm/events.log" || red "mem refusal: rc=$rc $(cat "$TEST_DIR/prov-13.log")"
green "MemAvailable 4096 MB < 16384 refused (exit 3, reason=host_mem)"
rc=$(run_prov 13 HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=600 PROVISION_SPAWN_CHECK_SECS=0)
[ "$rc" -eq 0 ] || red "first spawn with stagger should be admitted: $(cat "$TEST_DIR/prov-13.log")"
rc=$(run_prov 14 HOST_MAX_LOAD1=0 HOST_MIN_MEM_AVAIL_MB=0 HOST_SPAWN_STAGGER_SECS=600)
[ "$rc" -eq 3 ] && grep -q 'reason=spawn_stagger' "$PROJECT_DIR/.swarm/events.log" || red "stagger refusal: rc=$rc $(cat "$TEST_DIR/prov-14.log")"
green "second spawn inside the stagger window refused (exit 3, reason=spawn_stagger)"

heading "4: _load-env.sh ignores HOST_* keys in <project>/.swarm/.env"
printf 'HOST_MAX_WORKERS=99\nMAX_WORKERS=7\n' > "$PROJECT_DIR/.swarm/.env"
out=$(cd "$PROJECT_DIR" && bash -c ". '$LOAD_ENV' '$PROJECT_DIR'; echo \"\$HOST_MAX_WORKERS \$MAX_WORKERS\"" 2>"$TEST_DIR/loadenv.err")
[ "$out" = "2 7" ] || red "expected 'HOST_MAX_WORKERS=2 (host tier) MAX_WORKERS=7 (project)', got '$out'"
grep -q 'host-only keys are ignored' "$TEST_DIR/loadenv.err" || red "expected a warning about the ignored key"
green "project HOST_MAX_WORKERS=99 ignored with a warning; host tier value 2 wins; MAX_WORKERS still project-settable"

echo
green "all host-admission shape tests passed"
