#!/usr/bin/env bash
#
# test-shape-provision-https-origin.sh — Regression test for #576: a project
# whose origin is https://<token>@github.com/... gets a workflow-push warning
# plus a worker-brief "Push note" (workflow scope / outbox / SANDBOX_SSH=1; no
# SSH-URL retry since #638 rewrites it to HTTPS), and the token never
# appears in either. SSH-origin projects get neither.
#
# The snippet is lifted from provision-worker.sh with sed (never hand-copied),
# same technique as test-shape-provision-info-exclude.sh.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/../scripts/provision-worker.sh"
[ -r "$PROVISION" ] || red "provision-worker.sh not readable"

body="$(sed -n '/^PUSH_NOTE=""$/,/^esac$/p' "$PROVISION")"
[ -n "$body" ] || red "could not extract the PUSH_NOTE snippet from $PROVISION"

TEST_DIR=$(mktemp -d -t shape-provision-https-origin-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

run_with_origin() {
    local url="$1" repo="$TEST_DIR/r$RANDOM"
    git init -q "$repo"
    git -C "$repo" remote add origin "$url"
    ( cd "$repo" && eval "$body" && printf '%s' "$PUSH_NOTE" ) 2>"$TEST_DIR/stderr"
}

SECRET="github_pat_SECRET123"
note="$(run_with_origin "https://$SECRET@github.com/seanoc5/corpusminder-spring.git")"
err="$(cat "$TEST_DIR/stderr")"
grep -q 'workflow scope' <<<"$note" || red "note lacks the workflow-scope advice: $note"
grep -q 'SANDBOX_SSH=1' <<<"$note" || red "note lacks the SANDBOX_SSH opt-in: $note"
grep -q 'decision-needed' <<<"$note" || red "note lacks the outbox hand-back: $note"
if grep -q 'git push git@github.com' <<<"$note"; then red "note still advises an SSH-URL push (rewritten to HTTPS, same refusal)"; fi
grep -q '^## Push note' <<<"$note" || red "note lacks heading"
grep -q 'WARN: origin is HTTPS' <<<"$err" || red "no WARN on stderr: $err"
if grep -q "$SECRET" <<<"$note$err"; then red "token leaked into note or warning"; fi
green "HTTPS+token origin: warning + brief note, token not leaked"

note="$(run_with_origin "git@github.com:seanoc5/llm-swarm-runner.git")"
[ -z "$note" ] || red "SSH origin should yield no note: $note"
[ ! -s "$TEST_DIR/stderr" ] || red "SSH origin should not warn"
green "SSH origin: no note, no warning"

note="$(run_with_origin "https://github.com/seanoc5/public.git")"
[ -z "$note" ] || red "tokenless HTTPS should yield no note"
green "tokenless HTTPS origin: no note"
