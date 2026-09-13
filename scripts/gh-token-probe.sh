#!/usr/bin/env bash
#
# gh-token-probe.sh — does a candidate GitHub token cover everything the
# swarm's scripts and prompts actually ask `gh` to do?
#
# Run this BEFORE swapping the live credential. It never touches your
# keyring login: the candidate token is passed via GH_TOKEN for each call,
# which `gh` honours over its stored auth.
#
#   PROBE_TOKEN=github_pat_...  ./gh-token-probe.sh                     # read-only, against a real repo
#   PROBE_TOKEN=...  PROBE_WRITE=1 PROBE_REPO=seanoc5/swarm-token-probe ./gh-token-probe.sh
#                                                                        # + write ops, against a THROWAWAY repo
#   PROBE_TOKEN=...  PROBE_WRITE=1 PROBE_REPO=... PROBE_PR=3 ./gh-token-probe.sh
#                                                                        # + PR write ops on an existing open PR there
#   ... PROBE_MERGE=1                                                    # + actually merge PROBE_PR (destructive; last)
#
# Read phase defaults to seanoc5/llm-swarm-runner (public, harmless to read).
# Write phase REFUSES to run against any repo not named in PROBE_REPO, and
# you should point it at a throwaway repo you created for the purpose.
#
# Exit 0 = every probe passed. Otherwise the failing ops are listed with
# gh's own error text, which is what tells you which permission is missing.
set -uo pipefail

: "${PROBE_TOKEN:?set PROBE_TOKEN to the candidate token (never pass it as an argument)}"
READ_REPO="${PROBE_READ_REPO:-seanoc5/llm-swarm-runner}"
PROBE_REPO="${PROBE_REPO:-}"
PROBE_WRITE="${PROBE_WRITE:-0}"
PROBE_PR="${PROBE_PR:-}"
PROBE_MERGE="${PROBE_MERGE:-0}"

PASS=0; FAIL=0; FAILED=()

probe() {
    # probe "<label>" <command...>   — runs with the candidate token only.
    local label="$1"; shift
    local out
    if out="$(GH_TOKEN="$PROBE_TOKEN" "$@" 2>&1)"; then
        PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$label"
    else
        FAIL=$((FAIL + 1)); FAILED+=("$label")
        printf '  \033[31m✗\033[0m %s\n      %s\n' "$label" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    fi
}

echo
echo "=== identity ==="
probe "gh api user (who is this token?)"            gh api user --jq .login
probe "gh auth status accepts the token"           gh auth status
# gh cannot introspect fine-grained scopes; that line above will say so. Fine.

echo
echo "=== read ops the swarm runs constantly (against $READ_REPO) ==="
probe "gh repo view"                                gh repo view "$READ_REPO" --json name
probe "gh pr list"                                  gh pr list -R "$READ_REPO" --limit 3 --json number
probe "gh pr list --search merged:>= (gh_activity)" gh pr list -R "$READ_REPO" --state merged --limit 3 --search "merged:>=2026-01-01" --json number
probe "gh pr view (most-used call, 38 sites)"       bash -c 'n=$(gh pr list -R "$0" --limit 1 --state all --json number --jq ".[0].number"); gh pr view -R "$0" "$n" --json number,state,mergeStateStatus,statusCheckRollup' "$READ_REPO"
probe "gh pr diff"                                  bash -c 'n=$(gh pr list -R "$0" --limit 1 --state all --json number --jq ".[0].number"); gh pr diff -R "$0" "$n" >/dev/null' "$READ_REPO"
probe "gh pr checks"                                bash -c 'n=$(gh pr list -R "$0" --limit 1 --state all --json number --jq ".[0].number"); gh pr checks -R "$0" "$n" >/dev/null 2>&1 || [ $? -eq 8 ]' "$READ_REPO"
probe "gh issue list"                               gh issue list -R "$READ_REPO" --limit 3 --json number
probe "gh issue list --search closed:>="            gh issue list -R "$READ_REPO" --state closed --limit 3 --search "closed:>=2026-01-01" --json number
probe "gh issue view"                               bash -c 'n=$(gh issue list -R "$0" --limit 1 --state all --json number --jq ".[0].number"); gh issue view -R "$0" "$n" --json number' "$READ_REPO"
probe "gh run list (CI gate)"                       gh run list -R "$READ_REPO" --limit 3 --json conclusion
probe "gh workflow list (claude-code-action route)" gh workflow list -R "$READ_REPO"
probe "gh label list"                               gh label list -R "$READ_REPO" --limit 3
# review-scoreboard.sh's exact query shape. Fine-grained PATs and GraphQL
# have a history — this is the single most important line in the file.
probe "gh api graphql (review-scoreboard.sh shape)" gh api graphql -f owner="${READ_REPO%%/*}" -f name="${READ_REPO##*/}" \
    -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequests(first:2,orderBy:{field:CREATED_AT,direction:DESC}){nodes{number state createdAt comments(first:5){nodes{body}}}}}}'

if [ "$PROBE_WRITE" != "1" ]; then
    echo
    echo "  (write phase skipped — set PROBE_WRITE=1 PROBE_REPO=<throwaway repo> to run it)"
else
    [ -n "$PROBE_REPO" ] || { echo "ERROR: PROBE_WRITE=1 needs PROBE_REPO=<owner/throwaway-repo>" >&2; exit 2; }
    case "$PROBE_REPO" in
        */fand-app|*/fand-etl|*/fand-guide|*/civicstrata|*/corpusminder-spring|*/SAMlytics|*/llm-swarm-runner)
            echo "REFUSING: $PROBE_REPO is a real swarm repo. Point PROBE_REPO at a throwaway." >&2; exit 2 ;;
    esac
    echo
    echo "=== write ops (against $PROBE_REPO) ==="
    STAMP="probe-$(date -u +%Y%m%dT%H%M%SZ)"
    ISSUE_URL=""
    if out="$(GH_TOKEN="$PROBE_TOKEN" gh issue create -R "$PROBE_REPO" --title "$STAMP" --body "token probe — safe to delete" 2>&1)"; then
        ISSUE_URL="$out"; ISSUE_NUM="${ISSUE_URL##*/}"
        PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m gh issue create (#%s)\n' "$ISSUE_NUM"
        probe "gh issue comment"                    gh issue comment -R "$PROBE_REPO" "$ISSUE_NUM" --body "probe comment"
        probe "gh issue edit --body (pre-assignments)" gh issue edit -R "$PROBE_REPO" "$ISSUE_NUM" --body "edited by probe"
        probe "gh label create"                     gh label create -R "$PROBE_REPO" "$STAMP" --color 0e8a16 --force
        probe "gh issue edit --add-label"           gh issue edit -R "$PROBE_REPO" "$ISSUE_NUM" --add-label "$STAMP"
        probe "gh issue close"                      gh issue close -R "$PROBE_REPO" "$ISSUE_NUM"
    else
        FAIL=$((FAIL + 1)); FAILED+=("gh issue create"); printf '  \033[31m✗\033[0m gh issue create\n      %s\n' "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    fi
    if [ -n "$PROBE_PR" ]; then
        probe "gh pr comment (marker comments)"     gh pr comment -R "$PROBE_REPO" "$PROBE_PR" --body "<!-- PROBE -->probe"
        probe "gh pr edit --body"                   gh pr edit -R "$PROBE_REPO" "$PROBE_PR" --body "edited by probe $STAMP"
        probe "gh pr ready"                         bash -c 'gh pr ready -R "$0" "$1" 2>&1 | grep -qi "already\|is ready\|marked" || gh pr ready -R "$0" "$1"' "$PROBE_REPO" "$PROBE_PR"
        probe "gh pr close"                         gh pr close -R "$PROBE_REPO" "$PROBE_PR"
        probe "gh pr reopen"                        gh pr reopen -R "$PROBE_REPO" "$PROBE_PR"
        if [ "$PROBE_MERGE" = "1" ]; then
            probe "gh pr merge --squash (Contents: write)" gh pr merge -R "$PROBE_REPO" "$PROBE_PR" --squash --delete-branch
        else
            echo "  (gh pr merge skipped — PROBE_MERGE=1 to run it; it is the one op that needs Contents: write)"
        fi
    else
        echo "  (PR write ops skipped — open a PR on $PROBE_REPO and pass PROBE_PR=<n>)"
    fi
fi

echo
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    printf '  failed: %s\n' "${FAILED[@]}"
fi
echo
echo "NOTE: git push/pull are NOT exercised here. The swarm's remotes are SSH"
echo "      (git@github.com:...), so pushes are authorised by the mounted ~/.ssh"
echo "      key, not by this token. Scoping the token limits API-side actions only."
[ "$FAIL" -eq 0 ]
