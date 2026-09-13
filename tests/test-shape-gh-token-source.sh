#!/usr/bin/env bash
#
# test-shape-gh-token-source.sh — a project-scoped GH_TOKEN in .sandbox-env
# is honoured, and the host token is NOT injected on top of it (#418).
#
# The hazard this guards: sandbox.sh passes `-e GH_TOKEN` (host token) and
# `--env-file .sandbox-env` to the same `docker run`, and `-e` outranks the
# env-file for the same key. So a project that sets a narrow token would
# silently get the operator's broad one unless sandbox.sh steps aside.
#
# CI-safe: docker and gh are PATH-stubbed, HOME is redirected. No container,
# no network, no real credential — the "token" values here are strings.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$REPO_ROOT/sandbox.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then printf '%s\n' "$@" > "$ARGV_FILE"; env > "$ENV_FILE"; exit 0; fi
exit 0
EOF
# gh stub: `gh auth token` prints whatever GH_STUB_TOKEN holds (empty = not logged in → exit 1).
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
    [ -n "${GH_STUB_TOKEN:-}" ] || exit 1
    printf '%s\n' "$GH_STUB_TOKEN"; exit 0
fi
exit 0
EOF
chmod +x "$STUB/docker" "$STUB/gh"

FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"; printf '{}\n' > "$FAKE_HOME/.claude.json"

# fresh_project — a new git repo dir per scenario so .sandbox-env state can't leak between them.
fresh_project() { local d; d="$(mktemp -d "$TMP/proj.XXXX")"; git -C "$d" init -q; echo "$d"; }

# run_sandbox <project> [env...] → prints "ARGV<newline>---HEADER---<newline>header"
run_sandbox() {
    local project="$1"; shift
    ARGV_FILE="$TMP/argv.txt"; ENV_FILE="$TMP/env.txt"; rm -f "$ARGV_FILE" "$ENV_FILE"
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$FAKE_HOME" TERM=dumb \
        ARGV_FILE="$ARGV_FILE" ENV_FILE="$ENV_FILE" "$@" \
        bash "$SANDBOX" "$project" bash true 2>/dev/null > "$TMP/header.txt"
}
argv_has() { grep -qxF -- "$1" "$TMP/argv.txt" 2>/dev/null; }  # `--`: patterns like --env-file are not options

echo; echo "=== GH token source (#418) ==="; echo

# ── 1. no .sandbox-env, host logged in → host token via -e GH_TOKEN (value-less) ──
P="$(fresh_project)"
run_sandbox "$P" GH_STUB_TOKEN="host-token-value"
if argv_has "GH_TOKEN" && ! grep -q 'host-token-value' "$TMP/argv.txt" && grep -q '^GH_TOKEN=host-token-value$' "$TMP/env.txt"; then
    ok "1. host login → '-e GH_TOKEN' (value in env, never in argv)"
else
    bad "1. host login → '-e GH_TOKEN' (value in env, never in argv)" "argv: $(grep -n GH_TOKEN "$TMP/argv.txt" | tr '\n' ' ')"
fi
grep -q 'GH token: host gh login' "$TMP/header.txt" && ok "1b. header says 'host gh login'" || bad "1b. header says 'host gh login'" "$(grep 'GH token' "$TMP/header.txt")"

# ── 2. .sandbox-env sets GH_TOKEN → host token NOT injected, env-file passed ──
P="$(fresh_project)"; printf 'GH_TOKEN=project-scoped-token\nOTHER=1\n' > "$P/.sandbox-env"
run_sandbox "$P" GH_STUB_TOKEN="host-token-value"
if ! argv_has "GH_TOKEN" && ! grep -q '^GH_TOKEN=' "$TMP/env.txt" && argv_has "--env-file" && argv_has "$P/.sandbox-env"; then
    ok "2. .sandbox-env GH_TOKEN → host token stays out; env-file reaches docker"
else
    bad "2. .sandbox-env GH_TOKEN → host token stays out" "argv GH_TOKEN lines: $(grep -c 'GH_TOKEN' "$TMP/argv.txt"); env GH_TOKEN: $(grep '^GH_TOKEN=' "$TMP/env.txt" || echo none)"
fi
grep -q 'GH token: .sandbox-env' "$TMP/header.txt" && ok "2b. header says '.sandbox-env'" || bad "2b. header says '.sandbox-env'" "$(grep 'GH token' "$TMP/header.txt")"

# ── 3. .sandbox-env present but WITHOUT GH_TOKEN → host token still used ──
P="$(fresh_project)"; printf 'PGHOST=localhost\n# GH_TOKEN=commented-out\n' > "$P/.sandbox-env"
run_sandbox "$P" GH_STUB_TOKEN="host-token-value"
if argv_has "GH_TOKEN" && grep -q 'GH token: host gh login' "$TMP/header.txt"; then
    ok "3. .sandbox-env without GH_TOKEN (comment doesn't count) → host token used"
else
    bad "3. .sandbox-env without GH_TOKEN → host token used" "$(grep 'GH token' "$TMP/header.txt")"
fi

# ── 4. neither → none, and sandbox.sh still reaches docker run ──
P="$(fresh_project)"
run_sandbox "$P"
if [ -s "$TMP/argv.txt" ] && ! argv_has "GH_TOKEN" && grep -q 'GH token: none' "$TMP/header.txt"; then
    ok "4. no .sandbox-env, gh not logged in → 'none', docker run still reached"
else
    bad "4. no .sandbox-env, gh not logged in → 'none'" "argv lines: $(wc -l < "$TMP/argv.txt" 2>/dev/null || echo 0); $(grep 'GH token' "$TMP/header.txt")"
fi

# ── 5. the probe script itself is sane ──
if bash -n "$REPO_ROOT/scripts/gh-token-probe.sh" && [ -x "$REPO_ROOT/scripts/gh-token-probe.sh" ]; then
    ok "5. scripts/gh-token-probe.sh parses and is executable"
else
    bad "5. scripts/gh-token-probe.sh parses and is executable"
fi
# It must refuse to run write ops against a real swarm repo, whatever the token.
out="$(PROBE_TOKEN=x PROBE_WRITE=1 PROBE_REPO=seanoc5/fand-app PATH="$STUB:$PATH" bash "$REPO_ROOT/scripts/gh-token-probe.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'REFUSING' <<<"$out"; then
    ok "5b. probe refuses write ops against a real swarm repo (exit 2)"
else
    bad "5b. probe refuses write ops against a real swarm repo" "rc=$rc"
fi

echo; echo "  $PASS passed, $FAIL failed"; echo
[ "$FAIL" -eq 0 ]
