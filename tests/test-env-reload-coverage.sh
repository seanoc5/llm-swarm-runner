#!/usr/bin/env bash
# Issue #660 (fix round, PR #685): llm-start.sh now keeps .env.example/.env
# defaults OUT of the tmux server's global env so a project's .swarm/.env can
# win. The flip side: a script that reads one of those keys but neither
# sources scripts/_load-env.sh nor receives the key through the tmux -e list
# (llm-start.sh) or provision-worker.sh's PASS_VARS silently falls back to its
# in-script default. This test catches the next such script by shape.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }

# Keys shipped in .env.example (active or commented-out assignments).
KEYS="$(grep -oE '^#?[[:space:]]*(export )?[A-Z][A-Z0-9_]+=' "$ROOT/.env.example" |
    sed -E 's/^#?[[:space:]]*(export )?//; s/=$//' | sort -u)"

# Keys handed over explicitly: the llm-start.sh `for _v in` list (session -e),
# its named -e options, and provision-worker.sh PASS_VARS (worker windows).
PASSED="$(
  sed -n '/^    for _v in MAX_WORKERS/,/; do$/p' "$ROOT/llm-start.sh" | tr -s ' \;' '\n\n\n\n' |
      grep -E '^[A-Z][A-Z0-9_]+$' | grep -vx 'for\|do\|in' || true
  grep -oE 'TMUX_ENV_OPTS\+=\(-e "[A-Z_]+=' "$ROOT/llm-start.sh" | sed -E 's/.*"([A-Z_]+)=/\1/' || true
  sed -n '/^    PASS_VARS=(/,/^    )/p' "$ROOT/scripts/provision-worker.sh" | tr ' ' '\n' |
      sed -E 's/=.*//' | grep -E '^[A-Z][A-Z0-9_]+$' || true
)"
[ "$(echo "$PASSED" | grep -c .)" -ge 20 ] || bad "could not parse the pass lists (got: $(echo "$PASSED" | tr '\n' ' '))"

# Scripts that read keys without reloading, with the reason that is OK.
# "inherits": only ever runs as a child of a script that sources the loader.
# "worker": only runs in worker windows/containers, which get PASS_VARS.
declare -A ALLOW=(
  [scripts/coord-hook.sh]="inherits: hook child of coordinator-claude.sh, which sources the loader"
  [scripts/coord-inbox-wait.sh]="inherits: armed from inside the coordinator claude process"
  [scripts/dep-proxy.sh]="worker: started by sandbox.sh/provision-worker.sh (PASS_VARS)"
  [scripts/worker-listener.sh]="worker: runs via sandbox.sh listener; PASS_VARS carries its keys"
  [sandbox.sh]="worker: invoked by provision-worker.sh with PASS_VARS in its env"
  [entrypoint.sh]="worker: container entrypoint, env from sandbox.sh"
)

for f in "$ROOT"/scripts/*.sh "$ROOT"/sandbox.sh "$ROOT"/entrypoint.sh; do
  rel="${f#"$ROOT"/}"
  grep -q '_load-env\.sh' "$f" && continue
  [ -n "${ALLOW[$rel]:-}" ] && continue
  code="$(grep -vE '^[[:space:]]*#' "$f")"
  for k in $KEYS; do
    echo "$PASSED" | grep -qx "$k" && continue
    if grep -qE "\\$\\{?$k([^A-Za-z0-9_]|\$)" <<<"$code"; then
      bad "$rel reads $k but neither sources _load-env.sh nor gets it via llm-start -e / PASS_VARS"
    fi
  done
done
[ "$fail" = 0 ] && ok "every key-reading script reloads or is passed its keys"

# Behavioural check: stale-pr-nudges.sh in a bare env (no tmux-inherited
# defaults) must honor the project's .swarm/.env. Threshold 0 = exit before
# calling gh; the old fallback of 6 would call the stub gh.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proj/.swarm" "$T/bin"
echo 'STALE_PR_NUDGE_HOURS=0' > "$T/proj/.swarm/.env"
printf '#!/bin/sh\ntouch "%s/gh-called"\necho []\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
(cd "$T/proj" && env -i PATH="$T/bin:$PATH" HOME="$T" LLM_SWARM_DIR="$ROOT" bash "$ROOT/scripts/stale-pr-nudges.sh") >/dev/null 2>&1 || true
[ ! -e "$T/gh-called" ] && ok "stale-pr-nudges honors project STALE_PR_NUDGE_HOURS" \
    || bad "stale-pr-nudges ignored project STALE_PR_NUDGE_HOURS=0 (gh was called)"
exit $fail
