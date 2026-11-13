#!/usr/bin/env bash
# Issue #491: batch-run.sh falls back to a plain exec without systemd-run,
# prefixes systemd-run when it works, and coordinator-claude.sh wraps only
# when SWARM_BATCH_SLICE=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BASH_BIN="$(command -v bash)"

# 1. No systemd-run on PATH -> plain exec.
mkdir "$T/empty"
out="$(PATH="$T/empty" "$BASH_BIN" "$ROOT/scripts/batch-run.sh" /bin/echo hi)"
[ "$out" = "hi" ] && ok "fallback runs command without systemd-run" || bad "fallback: got '$out'"

# 2. systemd-run present and working -> used with the batch slice.
mkdir "$T/stub"
cat > "$T/stub/systemd-run" <<S
#!/bin/sh
echo "\$@" >> "$T/calls"
while [ "\$1" != "--" ]; do shift; done; shift; exec "\$@"
S
cat > "$T/stub/systemctl" <<S
#!/bin/sh
echo "systemctl \$*" >> "$T/calls"
S
chmod +x "$T/stub/"*
out="$(PATH="$T/stub:$PATH" "$ROOT/scripts/batch-run.sh" /bin/echo hi)"
[ "$out" = "hi" ] && ok "command output preserved through systemd-run" || bad "wrapped: got '$out'"
grep -q -- '--user --scope --slice=batch.slice' "$T/calls" && ok "uses user scope in batch.slice" || bad "no batch.slice call"
grep -q 'set-property --runtime batch.slice CPUWeight=20 IOWeight=20' "$T/calls" && ok "sets slice weights" || bad "no set-property"

# 3. systemd-run failing (no user manager) -> fallback.
printf '#!/bin/sh\nexit 1\n' > "$T/stub/systemd-run"
out="$(PATH="$T/stub:$PATH" "$ROOT/scripts/batch-run.sh" /bin/echo hi)"
[ "$out" = "hi" ] && ok "falls back when systemd-run fails" || bad "failing systemd-run: got '$out'"

# 4. coordinator-claude.sh wiring is opt-in.
grep -q 'SWARM_BATCH_SLICE:-0}" = "1"' "$ROOT/scripts/coordinator-claude.sh" && ok "coordinator wrap gated on SWARM_BATCH_SLICE=1" || bad "wrap not gated"
grep -q 'SWARM_BATCH_SLICE' "$ROOT/.env.example" && ok ".env.example documents the knob" || bad ".env.example missing knob"
exit $fail
