#!/usr/bin/env bash
# Issue #992: a knob the overview doc says is settable in <project>/.swarm/.env
# and that a worker reads inside its container (pr-ready.sh, worker-listener.sh)
# must be in BOTH forward lists: provision-worker.sh PASS_VARS (tmux window env)
# and sandbox.sh's WORKER_ENV_OPTS loop (docker -e). WORKER_PR_READY_CHECK_CMD
# was in neither, so setting it in .swarm/.env silently did nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }

pass_keys() {
  sed -n '/^    PASS_VARS=(/,/^    )/p' "$ROOT/scripts/provision-worker.sh" | tr ' ' '\n' |
    sed -E 's/=.*//' | grep -E '^[A-Z][A-Z0-9_]+$' || true
}
sandbox_keys() {
  sed -n '/^for _v in WORKER_HEADLESS/,/; do$/p' "$ROOT/sandbox.sh" | tr -s ' \;' '\n' |
    grep -E '^[A-Z][A-Z0-9_]+$' || true
}
P="$(pass_keys)"; S="$(sandbox_keys)"
[ "$(echo "$P" | grep -c .)" -ge 10 ] && [ "$(echo "$S" | grep -c .)" -ge 10 ] \
  && ok "parsed both forward lists" || bad "could not parse forward lists"

# Worker-side knobs documented in the overview table, with the script that reads them.
# Add a knob here when a worker-run script gains a documented .swarm/.env setting.
KNOBS="WORKER_CHECK_CMD WORKER_CHECK_TIMEOUT WORKER_CHECK_RETRY \
WORKER_PR_READY_CHECK_CMD WORKER_PR_READY_CHECK_TIMEOUT PR_READY_LINTS"
for k in $KNOBS; do
  grep -q "\`$k\`" "$ROOT/docs/llm-swarm-runner-overview.md" || bad "$k not in overview knob table (stale test list)"
  grep -qx "$k" <<<"$P" && ok "$k in PASS_VARS" || bad "$k missing from provision-worker.sh PASS_VARS"
  grep -qx "$k" <<<"$S" && ok "$k in sandbox.sh forward list" || bad "$k missing from sandbox.sh forward list"
done

# Behavioural: sandbox.sh forwards the knob as `-e NAME` when set.
if ! grep -q 'WORKER_PR_READY_CHECK_CMD' <(sed -n '/^for _v in WORKER_HEADLESS/,/; do$/p' "$ROOT/sandbox.sh"); then
  bad "sandbox.sh loop lacks WORKER_PR_READY_CHECK_CMD"
fi
exit $fail
