#!/usr/bin/env bash
#
# _ci-fallback.sh — shared Actions-runs fallback for when `gh pr checks` is
# unreadable by a fine-grained personal access token ("Resource not
# accessible by personal access token" — fine-grained PATs get Actions:read
# but no Checks permission, so `gh pr checks` fails outright instead of
# returning a real/pending/failed result).
#
# ci-wait.sh (#513/#540, inside its poll loop) and pr-ready.sh (#560, a
# single pre-ready snapshot) both hit this exact gap and need the identical
# run-state mapping, so it lives here once instead of as two copies that
# would drift.
#
# Sourced, not executed: `. "$SCRIPT_DIR/_ci-fallback.sh"`. Depends on `gh`
# and `jq` being on PATH, same as every caller already requires.
#
# Functions:
#
#   ci_fallback_is_token_error <text>
#       True (exit 0) if <text> contains the exact token-permission-error
#       string `gh pr checks` emits for a fine-grained PAT. Callers grep
#       their own captured `gh pr checks` output/stderr against this before
#       deciding whether to fall back at all.
#
#   ci_fallback_run_state <sha> [gh-repo-args...]
#       Queries `gh run list --commit <sha> [gh-repo-args...]` and maps the
#       newest run per workflow name to a verdict:
#         - any completed run concluding failure/cancelled/timed_out/
#           action_required/startup_failure/stale -> fail
#         - every run completed with success/skipped/neutral -> pass
#         - anything still queued/in_progress, or no runs yet -> pending
#       Dedupes by workflow name (keeping only the newest `createdAt`)
#       before mapping, so a re-run or a concurrency-cancelled older run
#       doesn't falsely fail a PR whose current run is green (#513/#540
#       self-review finding). stdout/stderr are kept apart so `gh`'s own
#       stderr noise can never corrupt the JSON parse (same finding).
#
#       Sets two globals for the caller to read immediately after calling
#       (not `local` — that's the point):
#         CI_FALLBACK_STATE   "pass" | "fail" | "pending" | "error"
#         CI_FALLBACK_DETAIL  raw runs JSON for pass/fail/pending, or the
#                              gh/jq error text for error
#
#       Returns 0 when a real verdict was reached (pass/fail/pending) — the
#       token-permission gap was successfully routed around. Returns 1 when
#       the fallback itself couldn't decide either (`gh run list` failed,
#       or returned unparseable output) — CI_FALLBACK_STATE is "error" in
#       that case. A caller MUST treat that 1 as "can't read CI status",
#       never silently as "failing CI": the whole reason this function
#       exists is to stop a permission gap from being misread as red CI
#       (issue #560).
ci_fallback_is_token_error() {
    grep -qi "resource not accessible by personal access token" <<<"$1"
}

ci_fallback_run_state() {
    local sha="$1"; shift
    local repo_args=("$@")
    local runs_json runs_rc err_file
    err_file="$(mktemp)"
    set +e
    runs_json="$(gh run list --commit "$sha" "${repo_args[@]}" --json status,conclusion,workflowName,createdAt --limit 100 2>"$err_file")"
    runs_rc=$?
    set -e
    if [ "$runs_rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$runs_json"; then
        CI_FALLBACK_STATE="error"
        CI_FALLBACK_DETAIL="gh run list --commit $sha failed or returned unparseable output: $(cat "$err_file")$runs_json"
        rm -f "$err_file"
        return 1
    fi
    rm -f "$err_file"

    CI_FALLBACK_DETAIL="$runs_json"
    CI_FALLBACK_STATE="$(jq -r '
        (group_by(.workflowName) | map(max_by(.createdAt))) as $latest |
        ($latest | map(select(.status == "completed"))) as $done |
        if ($done | map(select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale")) | length) > 0 then "fail"
        elif (($latest | length) > 0) and (($done | length) == ($latest | length)) and (($done | map(select(.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral")) | length) == ($done | length)) then "pass"
        else "pending"
        end' <<<"$runs_json")"
    return 0
}
