#!/usr/bin/env bash
#
# review-scoreboard.sh — Aggregate SWARM_SELF_REVIEW verdict markers across
# a repo's PRs into a review-coverage / verdict-history scoreboard.
#
# Sibling of swarm-scoreboard.sh (which scores task-level eval logs): this
# one answers "is the fresh-context self-review layer (self-review-pr.sh,
# ringer adoption #2) actually being exercised, and what is it finding?"
#
# Sources: PR number/state/createdAt/body + comments via one GraphQL sweep
# (`gh api graphql --paginate`). Verdict per PR = LATEST marker comment,
# the same rule swarm-merge.sh applies. Risk = first 🟢/🟡/🔴 emoji in the
# PR body (the blind-merge-risk rubric from the PR template); PRs with no
# emoji report as "unrated" (typically human/coordinator PRs).
#
# Reports, scoped to PRs created on/after the adoption date (the first
# marker anywhere in the repo; override with --since):
#   - review coverage by risk rating (🟢/unrated unreviewed is by design)
#   - verdict distribution (APPROVE / APPROVE_WITH_CAVEATS / BLOCK)
#   - ⚠ flags: merged PRs whose latest verdict is BLOCK (fix landed but
#     the marker was never refreshed with --force, or a genuine override);
#     merged 🟡/🔴 PRs with no review; open PRs sitting on a BLOCK
#
# Usage:
#   review-scoreboard.sh [--repo owner/name] [--since ISO8601] [--json] [file ...]
#
#   file args  — read PR nodes as JSONL (offline/test mode; same shape as
#                the GraphQL nodes: {number,state,createdAt,body,
#                comments:{nodes:[{body}]}})
#   no files   — fetch from GitHub: --repo, else the repo for the cwd
#   --since    — override the adoption cutoff (ISO8601, e.g. 2026-07-23)
#   --json     — emit the full aggregate as JSON instead of a table
#
# Caps (loud, not silent): comments are fetched first:100 per PR — a PR
# with more comments could hide a later marker; PR pages of 50, all pages
# fetched.
#
# Exit: 0 report produced (including "no markers found"), 1 error
# (gh/jq missing, fetch failure, bad args, no PRs).
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "review-scoreboard.sh: jq required" >&2; exit 1; }

REPO=""
SINCE=""
JSON_OUT=0
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)  shift; REPO="${1:?--repo requires owner/name}" ;;
        --since) shift; SINCE="${1:?--since requires an ISO8601 date}" ;;
        --json)  JSON_OUT=1 ;;
        -h|--help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        *)  FILES+=("$1") ;;
    esac
    shift
done

# --- gather PR nodes --------------------------------------------------------
if [ ${#FILES[@]} -gt 0 ]; then
    LABEL="${FILES[*]}"
    NODES="$(cat "${FILES[@]}")" || { echo "ERROR: cannot read input files" >&2; exit 1; }
else
    command -v gh >/dev/null 2>&1 || { echo "review-scoreboard.sh: gh required (or pass JSONL files)" >&2; exit 1; }
    if [ -z "$REPO" ]; then
        REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
            || { echo "ERROR: not in a GitHub repo and no --repo given" >&2; exit 1; }
    fi
    case "$REPO" in
        */*) ;;
        *) echo "ERROR: --repo must be owner/name, got '$REPO'" >&2; exit 1 ;;
    esac
    LABEL="$REPO"
    NODES="$(gh api graphql --paginate \
        -f owner="${REPO%%/*}" -f name="${REPO##*/}" \
        -f query='query($owner:String!,$name:String!,$endCursor:String){
            repository(owner:$owner,name:$name){
              pullRequests(first:50,after:$endCursor,orderBy:{field:CREATED_AT,direction:DESC}){
                pageInfo{hasNextPage endCursor}
                nodes{number state createdAt body comments(first:100){nodes{body}}}}}}' \
        --jq '.data.repository.pullRequests.nodes[]')" \
        || { echo "ERROR: GraphQL fetch failed for $REPO" >&2; exit 1; }
fi
[ -n "$NODES" ] || { echo "ERROR: no PRs found ($LABEL)" >&2; exit 1; }

# --- aggregate --------------------------------------------------------------
AGG="$(printf '%s\n' "$NODES" | jq -s --arg since "$SINCE" '
    def rank: if . == "🔴" then 0 elif . == "🟡" then 1
              elif . == "🟢" then 2 else 3 end;
    map(select(type == "object"))
    | map({
        number, state, createdAt,
        risk: ((((.body // "") | capture("(?<r>🟢|🟡|🔴)").r?) // "unrated")),
        verdict: ([(.comments.nodes // [])[] | (.body // "")
                   | capture("SWARM_SELF_REVIEW: (?<v>APPROVE_WITH_CAVEATS|APPROVE|BLOCK)").v]
                  | last)
      }) as $prs
    | (if $since != "" then $since
       else ([$prs[] | select(.verdict != null) | .createdAt] | min)
       end) as $adopt
    | if $adopt == null then
        {total: ($prs | length), adoption: null}
      else
        [$prs[] | select(.createdAt >= $adopt)] as $elig
        | {
            total: ($prs | length),
            adoption: $adopt,
            eligible: ($elig | length),
            reviewed: ([$elig[] | select(.verdict != null)] | length),
            coverage_by_risk:
                ($elig | group_by(.risk) | map({
                    risk: .[0].risk,
                    total: length,
                    reviewed: ([.[] | select(.verdict != null)] | length)
                  })
                | map(. + {coverage_pct: (.reviewed * 100 / .total | round)})
                | sort_by(.risk | rank)),
            verdicts:
                ([$elig[] | select(.verdict != null) | .verdict]
                 | group_by(.) | map({key: .[0], value: length}) | from_entries),
            flags: {
                merged_block:
                    ([$elig[] | select(.state == "MERGED" and .verdict == "BLOCK") | .number] | sort),
                open_block:
                    ([$elig[] | select(.state == "OPEN" and .verdict == "BLOCK") | .number] | sort),
                merged_high_unreviewed:
                    ([$elig[] | select(.state == "MERGED" and .verdict == null and .risk == "🔴") | .number] | sort),
                merged_medium_unreviewed:
                    ([$elig[] | select(.state == "MERGED" and .verdict == null and .risk == "🟡") | .number] | sort)
            }
          }
        | . + {reviewed_pct: (if .eligible == 0 then 0 else (.reviewed * 100 / .eligible | round) end)}
      end')"

if [ "$JSON_OUT" = "1" ]; then
    printf '%s\n' "$AGG"
    exit 0
fi

# --- render -----------------------------------------------------------------
ADOPT="$(jq -r '.adoption // empty' <<<"$AGG")"
if [ -z "$ADOPT" ]; then
    jq -r --arg l "$LABEL" \
        '"Repo: \($l) — \(.total) PRs, no SWARM_SELF_REVIEW markers found; nothing to score."' \
        <<<"$AGG"
    exit 0
fi

echo "Repo: $LABEL"
jq -r '"PRs: \(.total) total · adoption (first marker): \(.adoption)\nEligible since adoption: \(.eligible) · reviewed: \(.reviewed) (\(.reviewed_pct)%)"' <<<"$AGG"
echo ""
{
    echo "RISK|TOTAL|REVIEWED|COV%"
    jq -r '.coverage_by_risk[] | [.risk, .total, .reviewed, "\(.coverage_pct)%"] | join("|")' <<<"$AGG"
} | column -t -s'|'
echo ""
jq -r '"Verdicts: APPROVE \(.verdicts.APPROVE // 0) · APPROVE_WITH_CAVEATS \(.verdicts.APPROVE_WITH_CAVEATS // 0) · BLOCK \(.verdicts.BLOCK // 0)"' <<<"$AGG"
echo ""

FLAGGED=0
flag() {
    local nums
    nums="$(jq -r "$1 | map(\"#\(.)\") | join(\" \")" <<<"$AGG")"
    if [ -n "$nums" ]; then
        printf '⚠ %s: %s\n' "$2" "$nums"
        FLAGGED=1
    fi
}
flag '.flags.merged_block'             "merged with latest verdict BLOCK (fixed-then-merged without --force re-review, or an override)"
flag '.flags.open_block'               "open sitting on a BLOCK"
flag '.flags.merged_high_unreviewed'   "merged 🔴 with no review"
flag '.flags.merged_medium_unreviewed' "merged 🟡 with no review"
[ "$FLAGGED" = "1" ] || echo "No ⚠ flags — review hygiene clean."
echo ""
echo "(🟢/unrated unreviewed is by design — only 🟡/🔴 require self-review;"
echo " unrated = no risk emoji in the PR body, typically human PRs.)"
