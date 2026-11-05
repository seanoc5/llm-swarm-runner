#!/usr/bin/env bash
#
# replay-gh-fixtures.sh — snapshot GitHub as it looked at a past moment, for
# scripts/replay-work-run.sh (issue #768, ADR 0006 section 9 step A5).
#
# Why: a replayed work run must see the PRs and issues as they were when the
# resident coordinator woke, not as they are today (today most are merged or
# closed, so a fresh run would find nothing to do and the comparison would be
# meaningless). This script reads live GitHub with the real `gh` (read-only
# calls only), then rewinds each object to the --asof time. The replayed run
# never gets a token; it reads these files through the stub gh.
#
# Usage:
#   replay-gh-fixtures.sh --repo OWNER/NAME --asof 2026-11-01T19:12:42Z \
#       --prs 681,685 --issues 660,671 [--drafts 681] --out DIR
#
# Writes into DIR: pr-<N>.json, issue-<N>.json, pr-list.json, issue-list.json.
#
# Rewind rules (approximations, listed so the report can say what they cost):
#   - A PR or issue merged/closed after --asof is shown OPEN, with no
#     mergedAt/closedAt. One created after --asof is shown as not found.
#   - Comments, reviews and commits dated after --asof are dropped;
#     headRefOid becomes the last kept commit.
#   - Check runs completed after --asof are dropped (no checks = pending).
#   - If every commit or check run would be dropped (the branch was force-pushed
#     after --asof), the original list is kept: the old one is unrecoverable.
#   - isDraft and the PR body are today's values: GitHub keeps no history of
#     them. --drafts 681,683 forces isDraft=true for PRs known to be draft then;
#     the body of a PR the coordinator edited since still shows today's text.

set -uo pipefail

REPO="" ASOF="" PRS="" ISSUES="" OUT="" DRAFTS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?}"; shift 2 ;;
        --asof) ASOF="${2:?}"; shift 2 ;;
        --prs) PRS="${2:-}"; shift 2 ;;
        --issues) ISSUES="${2:-}"; shift 2 ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --drafts) DRAFTS="${2:-}"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$REPO" ] && [ -n "$ASOF" ] && [ -n "$OUT" ] || { echo "usage: --repo R --asof ISO --out DIR [--prs a,b] [--issues a,b]" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
mkdir -p "$OUT"

PR_FIELDS=number,title,state,isDraft,mergeable,mergeStateStatus,headRefOid,headRefName,baseRefName,body,labels,author,createdAt,mergedAt,closedAt,commits,comments,reviews,statusCheckRollup,files,url,additions,deletions,updatedAt
ISSUE_FIELDS=number,title,state,body,labels,assignees,author,createdAt,closedAt,comments,url,updatedAt

# jq: rewind a PR object to $asof.
REWIND_PR='
  def before: . != null and . <= $asof;
  if .createdAt > $asof then {error: "not found (created after asof)"} else
  (.mergedAt != null and .mergedAt > $asof or .closedAt != null and .closedAt > $asof) as $reopen
  | (.commits | map(select(.committedDate | before))) as $kc
  | (if ($kc|length) > 0 then .commits = $kc else . end)
  | .headRefOid = (if (.commits|length) > 0 then .commits[-1].oid else .headRefOid end)
  | .comments |= map(select(.createdAt | before))
  | .reviews |= map(select(.submittedAt | before))
  | (.statusCheckRollup | map(select((.completedAt // "") | (. == "" or . == "0001-01-01T00:00:00Z" or . <= $asof)))) as $kk
  | (if ($kk|length) > 0 then .statusCheckRollup = $kk else . end)
  | if $reopen or (.state == "OPEN") then .state = "OPEN" | .mergedAt = null | .closedAt = null
    elif .mergedAt != null and .mergedAt <= $asof then .state = "MERGED" else . end
  | if .state == "OPEN" then .mergeable = "MERGEABLE" else . end
  | if .state != "OPEN" then .isDraft = false else . end
  | .number as $num | if ($drafts | index($num)) != null then .isDraft = true else . end
  | .asof = $asof
  end'
REWIND_ISSUE='
  if .createdAt > $asof then {error: "not found (created after asof)"} else
  .comments |= map(select(.createdAt <= $asof))
  | if (.closedAt != null and .closedAt > $asof) then .state = "OPEN" | .closedAt = null else . end
  | .asof = $asof
  end'

# PRs that were open at asof (discovered), unioned with --prs.
OPEN_NUMS="$(gh pr list -R "$REPO" --state all --limit 300 --json number,createdAt,mergedAt,closedAt 2>/dev/null \
  | jq -r --arg asof "$ASOF" '.[] | select(.createdAt <= $asof and ((.mergedAt // "9999") > $asof) and ((.closedAt // "9999") > $asof)) | .number' | paste -sd, -)"
PRS="$(printf '%s,%s' "$PRS" "$OPEN_NUMS" | tr ',' '\n' | sed '/^$/d' | sort -un | paste -sd, -)"
IFS=',' read -r -a PR_ARR <<< "$PRS"
for n in "${PR_ARR[@]}"; do
    [ -n "$n" ] || continue
    # Some tokens cannot read check runs (fand-app: "Resource not accessible");
    # retry without them and record an empty list, so the run sees "no CI data".
    raw="$(gh pr view "$n" -R "$REPO" --json "$PR_FIELDS" 2>/dev/null)" \
        || { raw="$(gh pr view "$n" -R "$REPO" --json "${PR_FIELDS/,statusCheckRollup/}" 2>/dev/null | jq '.statusCheckRollup = []' 2>/dev/null)" \
             && [ -n "$raw" ] && echo "warn: pr $n: check runs unreadable, fixture has none" >&2; }
    if [ -n "$raw" ]; then
        printf '%s' "$raw" | jq --arg asof "$ASOF" --argjson drafts "[${DRAFTS:-}]" "$REWIND_PR" > "$OUT/pr-$n.json" \
            && [ -s "$OUT/pr-$n.json" ] || { echo '{"error":"rewind failed"}' > "$OUT/pr-$n.json"; echo "warn: rewind of pr $n failed" >&2; }
    else
        echo '{"error":"not found"}' > "$OUT/pr-$n.json"; echo "warn: pr $n not readable" >&2
    fi
done
IFS=',' read -r -a IS_ARR <<< "$ISSUES"
for n in "${IS_ARR[@]}"; do
    [ -n "$n" ] || continue
    if raw="$(gh issue view "$n" -R "$REPO" --json "$ISSUE_FIELDS" 2>/dev/null)"; then
        printf '%s' "$raw" | jq --arg asof "$ASOF" "$REWIND_ISSUE" > "$OUT/issue-$n.json" \
            && [ -s "$OUT/issue-$n.json" ] || { echo '{"error":"rewind failed"}' > "$OUT/issue-$n.json"; echo "warn: rewind of issue $n failed" >&2; }
    else
        echo '{"error":"not found"}' > "$OUT/issue-$n.json"; echo "warn: issue $n not readable" >&2
    fi
done

# Lists: everything alive at asof. PR list is built from the rewound per-PR files,
# so its heads and drafts agree with `pr view`.
for f in "$OUT"/pr-[0-9]*.json; do
    # if/then, not `&&`: under pipefail a trailing error-file would fail the whole list
    if jq -e 'has("error") | not' "$f" >/dev/null 2>&1; then
        jq -c '{number,title,state,isDraft,headRefName,createdAt,mergedAt,closedAt,labels,author,url,headRefOid}' "$f"
    fi
done | jq -s --arg asof "$ASOF" 'map(select(.state == "OPEN" and .createdAt <= $asof))' > "$OUT/pr-list.json" || echo '[]' > "$OUT/pr-list.json"
gh issue list -R "$REPO" --state all --limit 600 \
    --json number,title,state,labels,assignees,createdAt,closedAt,url 2>/dev/null \
  | jq --arg asof "$ASOF" '
      map(select(.createdAt <= $asof and ((.closedAt // "9999") > $asof))
          | .state = "OPEN" | .closedAt = null)' > "$OUT/issue-list.json" \
  || echo '[]' > "$OUT/issue-list.json"

echo "fixtures: repo=$REPO asof=$ASOF prs=$(ls "$OUT"/pr-[0-9]*.json 2>/dev/null | wc -l) issues=$(ls "$OUT"/issue-[0-9]*.json 2>/dev/null | wc -l) open_prs=$(jq length "$OUT/pr-list.json") open_issues=$(jq length "$OUT/issue-list.json") out=$OUT"
