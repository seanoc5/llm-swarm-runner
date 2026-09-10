#!/usr/bin/env bash
#
# test-shape-git-identity.sh — agent commits are authored by the swarm, not
# by the human whose credentials the swarm borrows (#403).
#
# sandbox.sh mounts the host's ~/.gitconfig read-only, so before #403 every
# commit a worker made was authored "Sean O'Connor <seanoc5@gmail.com>" and
# `git log` could not distinguish agent work from hand-written work. The fix
# rides the `docker run` line (an env var Docker injects) rather than a
# prompt convention, so it cannot be forgotten by an agent.
#
# CI-safe: `docker` and `gh` are PATH-stubbed and HOME is redirected to a
# temp dir, so nothing here starts a container, touches the real home, or
# reaches the network.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$REPO_ROOT/sandbox.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Stubs ────────────────────────────────────────────────────────────────────
# docker: `image inspect` succeeds (so sandbox.sh never tries to build), and
# `run` dumps its argv one-per-line to $ARGV_FILE instead of starting a
# container. Everything else is a no-op success.
STUB="$TMP/stub"
mkdir -p "$STUB"
cat > "$STUB/docker" <<'STUB_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then
    printf '%s\n' "$@" > "$ARGV_FILE"
    exit 0
fi
exit 0
STUB_EOF
# gh: exits 1, the way a real `gh auth token` does when gh is installed but
# not logged in. That is deliberately the unhappy path: under `set -e` an
# assignment from a failing command substitution used to take sandbox.sh down
# silently before it reached `docker run`, so every test below doubles as a
# regression guard for that (they capture no argv at all if it returns).
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/gh"
chmod +x "$STUB/docker" "$STUB/gh"

# A real git worktree to point sandbox.sh at — it runs `git rev-parse` on the
# project dir to work out whether the .git common dir needs its own mount.
PROJECT="$TMP/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q 2>/dev/null

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
printf '{}\n' > "$FAKE_HOME/.claude.json"
printf '[user]\n\tname = Host Human\n\temail = human@example.com\n' > "$FAKE_HOME/.gitconfig"

# run_sandbox <env assignments...> — invoke sandbox.sh with the stubs in front
# of PATH and return the captured `docker run` argv on stdout.
run_sandbox() {
    ARGV_FILE="$TMP/argv.txt"
    rm -f "$ARGV_FILE"
    env -i \
        PATH="$STUB:/usr/bin:/bin" \
        HOME="$FAKE_HOME" \
        TERM=dumb \
        ARGV_FILE="$ARGV_FILE" \
        "$@" \
        bash "$SANDBOX" "$PROJECT" bash true >/dev/null 2>&1
    cat "$ARGV_FILE" 2>/dev/null
}

# argv_has <argv-text> <exact line> — the argv dump is one arg per line, so an
# exact line match avoids the false positives a substring grep would give.
argv_has() { printf '%s\n' "$1" | grep -qxF "$2"; }

echo ""
echo "=== git identity shape (#403) ==="
echo ""

# ── Test 1: default identity is injected ─────────────────────────────────────
ARGV="$(run_sandbox)"
if [ -z "$ARGV" ]; then
    bad "1. sandbox.sh reached 'docker run'" "no argv captured — the stub never fired"
elif argv_has "$ARGV" "GIT_AUTHOR_NAME=swarm" && argv_has "$ARGV" "GIT_AUTHOR_EMAIL=swarm@oconeco.dev"; then
    ok "1. default author identity 'swarm <swarm@oconeco.dev>' is injected"
else
    bad "1. default author identity is injected" "$(printf '%s\n' "$ARGV" | grep -i git || echo '(no GIT_* args at all)')"
fi

# ── Test 2: committer is deliberately NOT overridden ─────────────────────────
# The human's credentials really did push the commit; overriding the committer
# too would both misreport that and break signing (the signature covers the
# committer, whose key is the one mounted at ~/.ssh).
if [ -z "$ARGV" ]; then
    # Guard against a vacuous pass: an empty argv contains no GIT_COMMITTER
    # either, and would otherwise look like proof of the thing we are testing.
    bad "2. committer left as the host identity" "no argv captured"
elif printf '%s\n' "$ARGV" | grep -q 'GIT_COMMITTER'; then
    bad "2. committer left as the host identity" "found: $(printf '%s\n' "$ARGV" | grep GIT_COMMITTER | tr '\n' ' ')"
else
    ok "2. committer left as the host identity (no GIT_COMMITTER_* injected)"
fi

# ── Test 3: overridable ──────────────────────────────────────────────────────
ARGV="$(run_sandbox SWARM_GIT_AUTHOR_NAME="other-swarm" SWARM_GIT_AUTHOR_EMAIL="bots@example.org")"
if argv_has "$ARGV" "GIT_AUTHOR_NAME=other-swarm" && argv_has "$ARGV" "GIT_AUTHOR_EMAIL=bots@example.org"; then
    ok "3. SWARM_GIT_AUTHOR_NAME/EMAIL override the defaults"
else
    bad "3. SWARM_GIT_AUTHOR_NAME/EMAIL override the defaults" "$(printf '%s\n' "$ARGV" | grep -i git_author || echo '(none)')"
fi

# ── Test 4: opt-out restores pre-#403 behaviour ──────────────────────────────
ARGV="$(run_sandbox SWARM_GIT_IDENTITY=0)"
if [ -z "$ARGV" ]; then
    bad "4. SWARM_GIT_IDENTITY=0 disables the override" "no argv captured"
elif printf '%s\n' "$ARGV" | grep -q 'GIT_AUTHOR'; then
    bad "4. SWARM_GIT_IDENTITY=0 disables the override" "still injected: $(printf '%s\n' "$ARGV" | grep GIT_AUTHOR | tr '\n' ' ')"
else
    ok "4. SWARM_GIT_IDENTITY=0 disables the override (falls back to ~/.gitconfig)"
fi

# ── Test 5: the mechanism actually works in git ──────────────────────────────
# Tests 1-4 prove the flag is passed. This proves the flag does what we claim:
# GIT_AUTHOR_* really does split author from committer, so `git log` can
# answer "agent or human?" per commit.
LIVE="$TMP/live"
mkdir -p "$LIVE"
git -C "$LIVE" init -q
: > "$LIVE/f"
git -C "$LIVE" add f
GIT_AUTHOR_NAME="swarm" GIT_AUTHOR_EMAIL="swarm@oconeco.dev" \
    git -C "$LIVE" \
        -c user.name="Host Human" -c user.email="human@example.com" \
        -c commit.gpgsign=false \
        commit -q -m "agent commit" 2>/dev/null
GOT="$(git -C "$LIVE" log -1 --format='%an|%ae|%cn|%ce' 2>/dev/null)"
if [ "$GOT" = "swarm|swarm@oconeco.dev|Host Human|human@example.com" ]; then
    ok "5. git records author=swarm, committer=host ('agent wrote it, human shipped it')"
else
    bad "5. git records author=swarm, committer=host" "got: ${GOT:-<no commit>}"
fi

# ── Test 6: the identity is visible to whoever is watching the pane ──────────
# A silent override is a debugging trap: someone reading `git log` and seeing
# an unfamiliar name needs the session header to explain where it came from.
HEADER="$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$FAKE_HOME" TERM=dumb \
    ARGV_FILE="$TMP/argv2.txt" bash "$SANDBOX" "$PROJECT" bash true 2>/dev/null)"
if printf '%s\n' "$HEADER" | grep -q 'swarm@oconeco.dev'; then
    ok "6. session header announces the author identity in use"
else
    bad "6. session header announces the author identity in use" "header: $(printf '%s' "$HEADER" | tr '\n' ' ')"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ]
