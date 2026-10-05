#!/usr/bin/env bash
#
# test-shape-nightly-full-tests.sh — shape tests for scripts/nightly-full-tests.sh:
# lanes run in a fresh clone of origin (not the checkout), @copy brings an
# untracked file, the dispatch pause exists during the run and is gone after,
# a failing lane opens a tracking issue then comments on it the next night,
# and @needs-docker skips rather than fails when Docker is down. Stubs gh/docker.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIGHTLY="$SCRIPT_DIR/../scripts/nightly-full-tests.sh"
T=$(mktemp -d -t shape-nightly-XXXXXX)
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/host-state"

mkrepo() {  # $1 name: a checkout with an origin, one tracked marker, untracked .env
    git init -q -b master "$T/$1"
    echo "origin-content" > "$T/$1/marker"
    git -C "$T/$1" add marker
    git -C "$T/$1" -c user.name=t -c user.email=t@t commit -q -m init
    git clone -q --bare "$T/$1" "$T/$1.git"
    git -C "$T/$1" remote add origin "$T/$1.git"
    echo "local-dirty" > "$T/$1/marker"      # uncommitted change must not reach the clone
    echo "SECRET=1" > "$T/$1/.env"
}
mkrepo alpha; mkrepo beta

cat > "$T/bin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$T/gh.log"
case "\$1 \$2" in
    "repo view")    echo "owner/\$(basename "\$PWD")" ;;
    "issue list")   [ -e "$T/issue-open" ] && echo 7 || true ;;
    "issue create") touch "$T/issue-open" ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\n[ -e "%s/docker-down" ] && exit 1; exit 0\n' "$T" > "$T/bin/docker"
chmod +x "$T"/bin/*
export PATH="$T/bin:$PATH" HOST_STATE_DIR="$T/host-state" NIGHTLY_HOME="$T/clones" NIGHTLY_LOG_DIR="$T/logs"
export NIGHTLY_CONF="$T/nightly.conf"
cat > "$NIGHTLY_CONF" <<CONF
# comment
$T/alpha @copy .env
$T/alpha content grep -qx origin-content marker && grep -q SECRET .env && [ -s "$HOST_STATE_DIR/dispatch-paused" ]
$T/beta @needs-docker
$T/beta @issue-title beta deep tracking
$T/beta broken  echo boom-output; exit 5
CONF

run() { set +e; bash "$NIGHTLY" "$@" > "$T/out.log" 2>&1; local rc=$?; set -e; echo "$rc"; }

heading "1: lanes run in a clean clone of origin, pause held during the run"
rc=$(run)
[ "$rc" -eq 1 ] || red "expected exit 1 (beta fails), rc=$rc: $(cat "$T/out.log")"
grep -q '| alpha | content | pass |' "$T/out.log" || red "alpha lane should pass (origin content, copied .env, pause file): $(cat "$T/out.log")"
[ ! -e "$HOST_STATE_DIR/dispatch-paused" ] || red "pause file should be removed on exit"
green "alpha passed in clone with .env and live pause; pause removed after"

heading "2: failing lane opens the tracking issue with its title, then comments next night"
grep -q '| beta | broken | FAIL (exit 5) |' "$T/out.log" || red "beta should FAIL (exit 5)"
grep -q 'issue create -R owner/beta --title beta deep tracking' "$T/gh.log" || red "expected issue create: $(cat "$T/gh.log")"
grep -q 'boom-output' "$T/gh.log" || red "issue body should carry the lane's log tail"
grep -q 'drafted by claude' "$T/gh.log" || red "issue body should end with the drafted-by line"
rc=$(run)
grep -q 'issue comment 7 -R owner/beta' "$T/gh.log" || red "second failure should comment on #7: $(cat "$T/gh.log")"
green "issue created once, commented the second time"

heading "3: @needs-docker skips when Docker is down; --only filters repos"
touch "$T/docker-down"; : > "$T/gh.log"
rc=$(run --only beta)
[ "$rc" -eq 0 ] || red "skipped lanes are not failures, rc=$rc: $(cat "$T/out.log")"
grep -q '| beta | broken | skipped (Docker unreachable) |' "$T/out.log" || red "beta should be skipped"
! grep -q '| alpha |' "$T/out.log" || red "--only beta should not run alpha"
[ ! -s "$T/gh.log" ] || ! grep -q issue "$T/gh.log" || red "skip should not touch issues"
green "beta skipped with Docker down, alpha excluded by --only"

echo
green "all nightly-full-tests shape tests passed"
