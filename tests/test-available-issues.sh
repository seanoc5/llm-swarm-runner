#!/usr/bin/env bash
#
# test-available-issues.sh — scripts/available-issues.sh label filtering (#409).
#
# The hazard this guards: demo-labeled issues are deliberately kept open as
# demo-driver.sh recording fodder, yet the mechanical AVAILABLE filter used to
# return them every run, forcing coordinator judgment to re-exclude them by
# hand each session. EXTRA_STOP_LABELS (default "demo") must exclude them,
# an empty override must re-include them, and the pre-existing built-in
# stop-labels (blocked/deferred/awaiting-review) must be unaffected either way.
#
# CI-safe: gh is PATH-stubbed to record its argv and print a fixed empty
# result. No network, no real repo.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/available-issues.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stub"; mkdir -p "$STUB"

# gh stub: `gh api user --jq .login` prints a fixed login; `gh issue list ...`
# appends its full argv (one call per line) to CALLS_FILE and prints `[]`.
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
    echo "me"
    exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    printf '%s\n' "$*" >> "$CALLS_FILE"
    echo '[]'
    exit 0
fi
exit 1
EOF
chmod +x "$STUB/gh"

# run <env...> — executes the script with the given extra env vars, capturing
# every `gh issue list` call's argv into CALLS_FILE.
run() {
    CALLS_FILE="$TMP/calls.txt"; rm -f "$CALLS_FILE"
    env -i PATH="$STUB:/usr/bin:/bin" CALLS_FILE="$CALLS_FILE" "$@" \
        bash "$SCRIPT" >/dev/null 2>"$TMP/stderr.txt"
    echo $?
}

echo; echo "=== available-issues.sh label filtering (#409) ==="; echo

# ── 1. default run excludes demo via EXTRA_STOP_LABELS default ──
rc="$(run)"
if [ "$rc" = "0" ] && grep -q -- '-label:demo' "$TMP/calls.txt"; then
    ok "1. default run: -label:demo present in every gh issue list search"
else
    bad "1. default run: -label:demo present" "rc=$rc calls: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

# ── 2. built-in stop-labels unchanged by the default ──
if grep -q -- '-label:blocked' "$TMP/calls.txt" && \
   grep -q -- '-label:deferred' "$TMP/calls.txt" && \
   grep -q -- '-label:awaiting-review' "$TMP/calls.txt"; then
    ok "2. built-in stop-labels (blocked/deferred/awaiting-review) still present"
else
    bad "2. built-in stop-labels still present" "calls: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

# ── 3. EXTRA_STOP_LABELS="" re-includes demo ──
rc="$(run EXTRA_STOP_LABELS=)"
if [ "$rc" = "0" ] && ! grep -q -- '-label:demo' "$TMP/calls.txt"; then
    ok "3. EXTRA_STOP_LABELS=\"\" → -label:demo absent"
else
    bad "3. EXTRA_STOP_LABELS=\"\" → -label:demo absent" "rc=$rc calls: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

# ── 4. EXTRA_STOP_LABELS="" still leaves built-in stop-labels intact ──
if grep -q -- '-label:blocked' "$TMP/calls.txt" && \
   grep -q -- '-label:deferred' "$TMP/calls.txt" && \
   grep -q -- '-label:awaiting-review' "$TMP/calls.txt"; then
    ok "4. EXTRA_STOP_LABELS=\"\": built-in stop-labels still present"
else
    bad "4. EXTRA_STOP_LABELS=\"\": built-in stop-labels still present" "calls: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

# ── 5. EXTRA_STOP_LABELS overrides the default label set (not additive) ──
rc="$(run EXTRA_STOP_LABELS=foo,bar)"
if [ "$rc" = "0" ] && grep -q -- '-label:foo' "$TMP/calls.txt" && grep -q -- '-label:bar' "$TMP/calls.txt" \
   && ! grep -q -- '-label:demo' "$TMP/calls.txt"; then
    ok "5. EXTRA_STOP_LABELS=foo,bar → foo/bar excluded, demo not"
else
    bad "5. EXTRA_STOP_LABELS=foo,bar → foo/bar excluded, demo not" "rc=$rc calls: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

# ── 6. INCLUDE_ASSIGNED_TO_OTHERS=1 (single gh issue list call) still gets the demo exclusion ──
rc="$(run INCLUDE_ASSIGNED_TO_OTHERS=1)"
if [ "$rc" = "0" ] && [ "$(wc -l < "$TMP/calls.txt")" -eq 1 ] && grep -q -- '-label:demo' "$TMP/calls.txt"; then
    ok "6. INCLUDE_ASSIGNED_TO_OTHERS=1: single call still excludes demo"
else
    bad "6. INCLUDE_ASSIGNED_TO_OTHERS=1: single call still excludes demo" "rc=$rc calls: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

# ── 7. OWNER_LABELS combine with the demo exclusion (both applied) ──
rc="$(run OWNER_LABELS=sean-owns)"
if [ "$rc" = "0" ] && grep -q -- '-label:sean-owns' "$TMP/calls.txt" && grep -q -- '-label:demo' "$TMP/calls.txt"; then
    ok "7. OWNER_LABELS and EXTRA_STOP_LABELS default combine"
else
    bad "7. OWNER_LABELS and EXTRA_STOP_LABELS default combine" "rc=$rc calls: $(cat "$TMP/calls.txt" 2>/dev/null)"
fi

echo; echo "  $PASS passed, $FAIL failed"; echo
[ "$FAIL" -eq 0 ]
