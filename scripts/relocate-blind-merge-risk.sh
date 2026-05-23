#!/usr/bin/env bash
# relocate-blind-merge-risk.sh
#
# One-off helper: rewrites an existing PR body so the visible
# "**Blind-merge risk:** ..." line is moved from the top to the bottom,
# wrapped in <sub> + italics, matching the current PULL_REQUEST_TEMPLATE.
# The <!-- BLIND_MERGE_RISK: ... --> HTML comment at the top is left alone
# (the coordinator still scrapes it for the swarm session output).
#
# Usage:
#   scripts/relocate-blind-merge-risk.sh <PR_NUMBER> [<PR_NUMBER> ...]
#   scripts/relocate-blind-merge-risk.sh --dry-run <PR_NUMBER>
#
# Idempotent: if a PR already has the <sub>-wrapped footer, it is skipped.
# Each rewrite is shown for confirmation unless --yes is passed.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
PRS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) PRS+=("$arg") ;;
  esac
done

if [[ ${#PRS[@]} -eq 0 ]]; then
  echo "error: no PR numbers given. try --help" >&2
  exit 2
fi

rewrite_body() {
  local body="$1"

  # Already in new shape? Footer present → no-op.
  if grep -qE '<sub>.*Blind-merge risk' <<<"$body"; then
    return 1
  fi

  # Extract the visible top line (the one that starts with **Blind-merge risk:**).
  local visible_line
  visible_line=$(grep -m1 -E '^\*\*Blind-merge risk:\*\*' <<<"$body" || true)
  if [[ -z "$visible_line" ]]; then
    return 2
  fi

  # Strip the visible line (and any single trailing blank line right after it).
  local stripped
  stripped=$(awk -v line="$visible_line" '
    BEGIN { skipped = 0 }
    {
      if (!skipped && $0 == line) { skipped = 1; next }
      if (skipped == 1 && $0 == "") { skipped = 2; next }
      print
    }
  ' <<<"$body")

  # Append the demoted footer. Trim trailing blank lines first.
  stripped=$(awk 'BEGIN{n=0} {lines[n++]=$0} END{while(n>0 && lines[n-1]=="") n--; for(i=0;i<n;i++) print lines[i]}' <<<"$stripped")

  # Construct footer from the original visible line.
  local footer="<sub>_Swarm metadata (safe to ignore if you're reviewing this as a human)._ ${visible_line}</sub>"

  printf '%s\n\n---\n\n%s\n' "$stripped" "$footer"
}

for pr in "${PRS[@]}"; do
  printf '\n=== PR #%s ===\n' "$pr"
  current=$(gh pr view "$pr" --json body --jq .body)

  if new_body=$(rewrite_body "$current"); then
    :
  else
    rc=$?
    case "$rc" in
      1) echo "  skip: already has <sub>-wrapped footer" ;;
      2) echo "  skip: no visible **Blind-merge risk:** line found" ;;
      *) echo "  skip: rewrite failed (rc=$rc)" ;;
    esac
    continue
  fi

  echo "--- proposed diff (first 10 lines of head + last 5 of tail) ---"
  diff <(printf '%s\n' "$current") <(printf '%s\n' "$new_body") | head -40 || true
  echo "----------------------------------------------------------------"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  dry-run: not applying"
    continue
  fi

  if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "  apply to PR #$pr? [y/N] " ans
    [[ "$ans" =~ ^[yY] ]] || { echo "  skipped by user"; continue; }
  fi

  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$new_body" >"$tmp"
  gh pr edit "$pr" --body-file "$tmp"
  rm -f "$tmp"; trap - EXIT
  echo "  applied."
done
