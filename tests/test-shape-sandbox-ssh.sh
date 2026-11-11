#!/usr/bin/env bash
#
#
# test-shape-sandbox-ssh.sh — workers get no SSH identity by default (#638).
#
# The operator's ~/.ssh key logs in to other hosts (live kdeyoga), so sandbox.sh
# no longer mounts ~/.ssh or forwards the agent unless SANDBOX_SSH=1. Git over
# github.com is rewritten to HTTPS (authenticated by GH_TOKEN) with env-based
# git config, and signing is turned off because the signing key is the SSH key.
#
# CI-safe: docker and gh are PATH-stubbed, HOME is a temp dir.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$REPO_ROOT/sandbox.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"
mkdir -p "$STUB"
cat > "$STUB/docker" <<'STUB_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then
    printf '%s\n' "$@" > "$ARGV_FILE"
fi
exit 0
STUB_EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/gh"
chmod +x "$STUB/docker" "$STUB/gh"

PROJECT="$TMP/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q 2>/dev/null
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.ssh"
printf '{}\n' > "$FAKE_HOME/.claude.json"
printf '[user]\n\tname = Host Human\n' > "$FAKE_HOME/.gitconfig"

run_sandbox() {
    ARGV_FILE="$TMP/argv.txt"
    rm -f "$ARGV_FILE"
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$FAKE_HOME" TERM=dumb \
        ARGV_FILE="$ARGV_FILE" "$@" \
        bash "$SANDBOX" "$PROJECT" bash true >/dev/null 2>&1
    cat "$ARGV_FILE" 2>/dev/null
}
argv_has() { printf '%s\n' "$1" | grep -qxF "$2"; }
argv_grep() { printf '%s\n' "$1" | grep -q -- "$2"; }

echo ""
echo "=== sandbox ssh shape (#638) ==="
echo ""

ARGV="$(run_sandbox SSH_AUTH_SOCK=/tmp/fake-agent.sock)"
if [ -z "$ARGV" ]; then
    bad "default run reached docker run" "no argv captured"
else
    if argv_grep "$ARGV" '\.ssh'; then
        bad "1. default: ~/.ssh is not mounted" "$(printf '%s\n' "$ARGV" | grep '\.ssh')"
    else
        ok "1. default: ~/.ssh is not mounted"
    fi
    if argv_grep "$ARGV" 'SSH_AUTH_SOCK\|ssh-agent'; then
        bad "2. default: agent is not forwarded" "$(printf '%s\n' "$ARGV" | grep 'SSH_AUTH_SOCK\|ssh-agent')"
    else
        ok "2. default: agent is not forwarded (SSH_AUTH_SOCK unset in container)"
    fi
    if argv_has "$ARGV" "GIT_CONFIG_COUNT=4" \
       && argv_has "$ARGV" "GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf" \
       && argv_has "$ARGV" "GIT_CONFIG_VALUE_0=git@github.com:" \
       && argv_has "$ARGV" "GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf" \
       && argv_has "$ARGV" "GIT_CONFIG_VALUE_1=ssh://git@github.com/"; then
        ok "3. default: both github SSH remote forms are rewritten to HTTPS"
    else
        bad "3. default: github SSH remotes rewritten to HTTPS" "$(printf '%s\n' "$ARGV" | grep GIT_CONFIG | tr '\n' ' ')"
    fi
    if argv_has "$ARGV" "GIT_CONFIG_KEY_2=commit.gpgsign" && argv_has "$ARGV" "GIT_CONFIG_VALUE_2=false"; then
        ok "4. default: commit signing disabled (the signing key is the SSH key)"
    else
        bad "4. default: commit signing disabled" "$(printf '%s\n' "$ARGV" | grep GIT_CONFIG | tr '\n' ' ')"
    fi
fi

ARGV="$(run_sandbox SANDBOX_SSH=1 SSH_AUTH_SOCK=/tmp/fake-agent.sock)"
if argv_has "$ARGV" "$FAKE_HOME/.ssh:/home/sandbox/.ssh:ro" \
   && argv_has "$ARGV" "$FAKE_HOME/.ssh:$FAKE_HOME/.ssh:ro" \
   && argv_has "$ARGV" "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"; then
    ok "5. SANDBOX_SSH=1 restores both ~/.ssh mounts and agent forwarding"
else
    bad "5. SANDBOX_SSH=1 restores today's behaviour" "$(printf '%s\n' "$ARGV" | grep -i 'ssh' | tr '\n' ' ')"
fi
if argv_grep "$ARGV" 'insteadOf\|gpgsign'; then
    bad "6. SANDBOX_SSH=1 adds no HTTPS rewrite or signing override" "$(printf '%s\n' "$ARGV" | grep 'insteadOf\|gpgsign')"
else
    ok "6. SANDBOX_SSH=1 adds no HTTPS rewrite or signing override"
fi

# A caller's own GIT_CONFIG_* entries must survive: ours append after them.
ARGV="$(run_sandbox GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=foo.bar GIT_CONFIG_VALUE_0=baz)"
if argv_has "$ARGV" "GIT_CONFIG_COUNT=5" && argv_has "$ARGV" "GIT_CONFIG_KEY_0" \
   && argv_has "$ARGV" "GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf"; then
    ok "7. caller's GIT_CONFIG_* entries are kept; sandbox entries append after them"
else
    bad "7. caller's GIT_CONFIG_* entries are kept" "$(printf '%s\n' "$ARGV" | grep GIT_CONFIG | tr '\n' ' ')"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
