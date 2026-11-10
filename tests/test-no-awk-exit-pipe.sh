#!/usr/bin/env bash
#
# test-no-awk-exit-pipe.sh — issues #746 and #807. Under `set -o pipefail`,
# `producer | READER` races whenever READER quits before it has read all of
# the producer's output: the producer takes SIGPIPE, the pipeline returns 141,
# and inside `$(...)` / `if` the script either dies silently or a condition
# flips (swarm-merge.sh died with exit 141 and no output before any gate ran).
# Same class as #648. Checks:
#   1. static scan: no script pipes into an early-exit reader — `awk '... exit
#      ...'`, `head -1` / `head -n1`, `grep -q…`, `grep -m1`. Use a here-string,
#      `sed -n 1p`, `grep … >/dev/null`, or an awk done-flag instead. A pipe
#      split across lines is joined first. Opt out one line with a trailing
#      `# pipe-ok` comment (only when the producer provably cannot outlive the
#      reader, e.g. a single-write literal; say why).
#   2. the scan catches the old forms (self-test on a fixture).
#   3. the replacement idioms survive a producer larger than the 64 KB pipe
#      buffer, while the old idioms demonstrably die with 141 (proves the
#      harness can see the race at all).
#   4. no-regression only: swarm-merge.sh's main_worktree in a 21-worktree
#      repo. ~2 KB of porcelain is flushed in one write, so the pre-#746 code
#      passes this loop too; checks 1 and 3 are what guard the race.
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"

# scan FILE... — print `file:line:logical-line` for each early-exit pipe.
# Lines ending in `|` or `\` are joined with the next line, so a pipe at the
# end of one line and the reader on the next is still seen. Comment-only lines
# and lines carrying `pipe-ok` / `exit-ok` are skipped.
scan() {
    local f
    for f in "$@"; do
        awk -v F="$f" '
            { line = $0
              if (buf == "") start = FNR
              buf = (buf == "" ? line : buf " " line)
              if (line ~ /(\||\\)[[:space:]]*$/) next
              print F ":" start ":" buf; buf = "" }
            END { if (buf != "") print F ":" start ":" buf }' "$f"
    done | grep -E '\|[[:space:]]*(awk[^|]*[{; ]exit[ ;}]|head[[:space:]]+-(n[[:space:]]*)?1([^0-9]|$)|grep[[:space:]]+(-[a-zA-Z]*q|-m[[:space:]]*1|--quiet))' \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE 'pipe-ok|exit-ok' || true
}

# 1. Static scan of the real scripts.
hits="$(scan "$SCRIPTS"/*.sh)"
[ -z "$hits" ] || red "early-exit reader in a pipe (SIGPIPE race under pipefail):
$hits"
green "no early-exit pipes (awk exit / head -1 / grep -q / grep -m1) in scripts/"

# 2. The scan sees every old form, including a pipe split across lines.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/old.sh" <<'FIXTURE'
a="$(git merge-tree --write-tree X HEAD 2>/dev/null | head -1)" || return 1
if tmux list-windows -t s -F '#W' 2>/dev/null | grep -qx "iss-1"; then :; fi
if gh pr view 1 --json comments \
        --jq '.comments[].body' 2>/dev/null | grep -q 'MARK:'; then :; fi
x="$(printf '%s\n' "$r" |
    grep -m1 -E '^A')"
y="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
z="$(producer |
    awk 'NR==1{print; exit}')"
FIXTURE
n="$(scan "$TMP/old.sh" | wc -l)"
[ "$n" -eq 6 ] || red "scan self-test: expected 6 old-form hits, got $n:
$(scan "$TMP/old.sh")"
cat > "$TMP/new.sh" <<'FIXTURE'
a="$(git merge-tree --write-tree X HEAD 2>/dev/null | sed -n 1p)" || return 1
if tmux list-windows -t s 2>/dev/null | grep -x "iss-1" >/dev/null; then :; fi
b="$(cat f | head -1)"  # pipe-ok: fixture
FIXTURE
[ -z "$(scan "$TMP/new.sh")" ] || red "scan self-test: new forms flagged: $(scan "$TMP/new.sh")"
green "scan flags every old form and none of the replacements"

# 3. Behavioural: 2 MB producer vs. the old and new idioms.
big() { head -c 2000000 /dev/zero | tr '\0' 'a' | fold -w 80; }
status_of() { local rc=0; ( "$@" ) >/dev/null 2>&1 || rc=$?; echo "$rc"; }
old_head()  { big | head -1; }
old_grep()  { big | grep -q a; }
new_head()  { big | sed -n 1p; }
new_grep()  { big | grep a >/dev/null; }
new_here()  { local v; v="$(big)"; grep -q a <<<"$v"; }
for fn in old_head old_grep; do
    rc="$(status_of bash -c "set -o pipefail; $(declare -f big "$fn"); $fn")"
    # 141 normally; a CI runner that starts us with SIGPIPE ignored gives the
    # writer EPIPE instead (another nonzero code) — either way the pipeline fails.
    [ "$rc" != 0 ] || red "harness cannot reproduce the race: $fn exited 0"
done
for fn in new_head new_grep new_here; do
    rc="$(status_of bash -c "set -o pipefail; $(declare -f big "$fn"); $fn")"
    [ "$rc" = 0 ] || red "$fn exited $rc on a 2 MB producer"
done
green "old head -1 / grep -q fail (141) on a 2 MB producer; replacements exit 0"

# 4. No-regression loop on the real function (cannot reproduce the race; see header).
git init -q "$TMP/main"
git -C "$TMP/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
for i in $(seq 1 20); do git -C "$TMP/main" worktree add -q -b "b$i" "$TMP/wt-$i"; done
eval "$(awk '/^main_worktree\(\)/,/^}/' "$SCRIPTS/swarm-merge.sh")"
cd "$TMP/main"
want="$(cd "$TMP/main" && pwd -P)"
for n in $(seq 1 300); do
  got="$(main_worktree)" || red "main_worktree failed (exit $?) on iteration $n"
  [ "$(cd "$got" && pwd -P)" = "$want" ] || red "wrong main worktree: $got"
done
green "main_worktree x300 with 21 worktrees: no 141, correct path (no-regression check only)"
