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
#
#   ci_fallback_workflows_relevant_to_pr <pr> [gh-repo-args...]
#       issue #639: a repo can have `pull_request`-triggered workflows that
#       are configured but will NEVER run for a given PR — a `paths-ignore`
#       (or a `paths` allowlist none of the changed files match) means
#       GitHub creates no run at all, so "no checks reported" is a
#       permanent fact about this commit, not the ordinary post-push race
#       the "no checks reported" handling elsewhere in this file already
#       accounts for (a workflow count of 0 means nothing is configured at
#       all; this function instead asks "is anything configured that would
#       apply to THESE files"). Fetches the PR's changed files and every
#       active workflow's raw YAML, and farms the per-workflow trigger
#       decision out to `_workflow-path-filter.py` (a tiny stdlib-only
#       line scanner — no PyYAML dependency) since that parsing isn't
#       reliable in bash/jq. Only called once a caller has already
#       confirmed the repo has at least one workflow at all AND `gh pr
#       checks` reported "no checks reported" — this is not a substitute
#       for that cheaper check, only a refinement of it.
#
#       issue #644 round-3 self-review: before any of that YAML-fetch-and-
#       parse, if the PR's own changed files include anything under
#       .github/workflows/, this short-circuits straight to "yes" without
#       reading a single workflow file. GitHub evaluates a `pull_request`
#       event's workflow YAML from the PR's merge commit, not the base
#       branch, so a PR that removes a paths-ignore entry (or adds a new
#       workflow) gets a real run the base-branch YAML — which is all this
#       function can read — says will never happen. That's the fail-open
#       direction this whole function exists to avoid, so a workflow-file
#       edit is never read as path-filtered, full stop.
#
#       Sets two globals:
#         CI_FALLBACK_RELEVANT         "yes" | "no" | "unknown"
#         CI_FALLBACK_RELEVANT_DETAIL  one-line explanation
#
#       "no" means at least one active workflow's pull_request/push trigger
#       is CONFIDENTLY path-filtered-excluded for every one of the PR's
#       changed files, and no workflow came back "triggers" or "unknown" —
#       positive evidence that a real exclusion decision was made, not
#       merely the absence of a relevant trigger. "yes" means at least one
#       workflow would run, OR nothing could be determined confidently
#       (fails toward "yes": the safe direction is to keep treating this as
#       a real, awaitable CI gap, same posture as every other ambiguous
#       case in this file). "unknown" is set alongside "yes" so a caller
#       that wants to say WHY can still tell the two "yes" paths apart;
#       callers that don't care just check for "no".
#
#       issue #644 third follow-up: a workflow whose only triggers are
#       things like `schedule`/`workflow_dispatch` returns "no-trigger"
#       from the per-workflow filter script, not "excluded" — and
#       "no-trigger" must NEVER be folded into the same bucket as
#       "excluded". An all-"no-trigger" result means nothing confirms a
#       path-filter exclusion actually happened, only that this function
#       found nothing relevant to check; that is not evidence CI will
#       never register, so it also falls to "yes". A workflow whose only
#       PR-type/push trigger is itself unfiltered (`on: push` with no
#       `paths`/`paths-ignore` at all) is "triggers", never "no-trigger" —
#       GitHub still creates a real run on the PR's head commit for it.
#
#       Always returns 0 (never fails the caller's `set -e`) — every
#       failure mode (an unreadable PR, an unreadable workflow list, an
#       unreadable workflow file, a parse the Python helper couldn't
#       confidently make) is folded into CI_FALLBACK_RELEVANT=yes/unknown,
#       not a nonzero return, so callers never need their own try/catch
#       around this call.
_CI_FALLBACK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ci_fallback_workflows_relevant_to_pr() {
    local pr="$1"; shift
    local repo_args=("$@")
    local repo_path="repos/{owner}/{repo}"
    local i
    for ((i = 0; i < ${#repo_args[@]}; i++)); do
        if [ "${repo_args[$i]}" = "--repo" ]; then
            repo_path="repos/${repo_args[$((i + 1))]}"
        fi
    done

    # `gh pr view --json files` truncates at 100 files (cli/cli#5366) — a
    # large PR past that cap would silently drop files from the relevance
    # check, so this goes through the REST files endpoint with --paginate
    # instead, which follows every Link header.
    local files_list files_rc
    set +e
    files_list="$(gh api --paginate "$repo_path/pulls/$pr/files" --jq '.[].filename' 2>&1)"
    files_rc=$?
    set -e
    if [ "$files_rc" -ne 0 ] || [ -z "$files_list" ]; then
        CI_FALLBACK_RELEVANT="yes"
        CI_FALLBACK_RELEVANT_DETAIL="couldn't read PR #$pr's changed file list"
        return 0
    fi

    # issue #644 round-3 self-review: for `pull_request` events GitHub runs
    # the workflow YAML from the PR's MERGE COMMIT, not the base branch —
    # so a PR that itself edits a workflow (removes a paths-ignore entry,
    # adds a new workflow) can get a real run the base-branch YAML this
    # function fetches below says will never happen. Parsing the head-ref
    # YAML instead would just move the trust problem (a PR could edit the
    # workflow to claim a filter it won't actually run under), so this
    # takes the cheap, safe-direction fix instead: any changed file under
    # .github/workflows/ makes CI relevance unconditional, no YAML read or
    # parse at all. This can never be reached via the "excluded" return
    # path below with a workflow-editing PR, closing the fail-open.
    if grep -q '^\.github/workflows/' <<<"$files_list"; then
        CI_FALLBACK_RELEVANT="yes"
        CI_FALLBACK_RELEVANT_DETAIL="PR #$pr changes a workflow file itself (.github/workflows/) — GitHub runs the merge-commit version of that workflow, not the base branch's, so path-filter exclusions can't be trusted"
        return 0
    fi

    local wf_json wf_rc
    set +e
    wf_json="$(gh api "$repo_path/actions/workflows" --jq '[.workflows[] | select(.state == "active") | .path]' 2>&1)"
    wf_rc=$?
    set -e
    if [ "$wf_rc" -ne 0 ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$wf_json"; then
        CI_FALLBACK_RELEVANT="yes"
        CI_FALLBACK_RELEVANT_DETAIL="couldn't list this repo's active workflows"
        return 0
    fi
    if ! jq -e 'length > 0' >/dev/null 2>&1 <<<"$wf_json"; then
        # A caller only reaches this function after confirming the repo's
        # workflow count is nonzero, so an empty active-workflow list here
        # is itself a surprise (a race between the two separate `gh api`
        # calls, a state filter mismatch, ...) — fail toward "yes" rather
        # than silently concluding "nothing is configured, so nothing can
        # be relevant."
        CI_FALLBACK_RELEVANT="yes"
        CI_FALLBACK_RELEVANT_DETAIL="this repo's active-workflow list came back empty, inconsistent with its own nonzero workflow count"
        return 0
    fi

    local tmp_files tmp_wf
    tmp_files="$(mktemp)"
    tmp_wf="$(mktemp)"
    printf '%s\n' "$files_list" > "$tmp_files"

    local path content content_rc verdict saw_excluded
    saw_excluded=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        set +e
        content="$(gh api -H "Accept: application/vnd.github.raw" "$repo_path/contents/$path" 2>&1)"
        content_rc=$?
        set -e
        if [ "$content_rc" -ne 0 ]; then
            CI_FALLBACK_RELEVANT="yes"
            CI_FALLBACK_RELEVANT_DETAIL="couldn't read workflow file $path"
            rm -f "$tmp_files" "$tmp_wf"
            return 0
        fi
        printf '%s' "$content" > "$tmp_wf"
        verdict="$(python3 "$_CI_FALLBACK_SCRIPT_DIR/_workflow-path-filter.py" "$tmp_wf" "$tmp_files" 2>/dev/null || echo unknown)"
        case "$verdict" in
            triggers)
                CI_FALLBACK_RELEVANT="yes"
                CI_FALLBACK_RELEVANT_DETAIL="$path has a pull_request/push trigger matching at least one changed file"
                rm -f "$tmp_files" "$tmp_wf"
                return 0
                ;;
            unknown)
                CI_FALLBACK_RELEVANT="yes"
                CI_FALLBACK_RELEVANT_DETAIL="couldn't confidently parse $path's trigger (or it has a workflow_run trigger, which this scanner never clears)"
                rm -f "$tmp_files" "$tmp_wf"
                return 0
                ;;
            excluded)
                # Positive evidence: this workflow DOES have a
                # pull_request/push trigger, and its path filter
                # confidently excludes every changed file. Keep checking
                # the remaining workflows before concluding "no".
                saw_excluded=1
                ;;
            no-trigger)
                # issue #644 third follow-up: this workflow has no
                # pull_request/pull_request_target/push/workflow_run
                # trigger at all (e.g. schedule/workflow_dispatch-only) —
                # that is NOT the same as a confident path-filter
                # exclusion, and must never be folded into "excluded".
                # Keep checking; it contributes no evidence either way.
                : ;;
        esac
    done < <(jq -r '.[]' <<<"$wf_json")
    rm -f "$tmp_files" "$tmp_wf"

    if [ "$saw_excluded" -eq 1 ]; then
        CI_FALLBACK_RELEVANT="no"
        CI_FALLBACK_RELEVANT_DETAIL="every pull_request/push-triggered workflow's path filter excludes all of PR #$pr's changed files"
    else
        # No workflow was even confidently "excluded" — every one was
        # "no-trigger" (nothing checked applies to this PR at all). That's
        # the absence of evidence, not evidence of absence: fail toward
        # "yes" rather than concluding no CI will ever register.
        CI_FALLBACK_RELEVANT="yes"
        CI_FALLBACK_RELEVANT_DETAIL="no active workflow has a confidently path-filtered pull_request/push trigger for PR #$pr — can't confirm no CI will ever register"
    fi
    return 0
}

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
        end' <<<"$runs_json" 2>/dev/null)" || {
        # Valid JSON that isn't an array (e.g. `{}`) passes the parse check
        # above but fails group_by here; without this, the function returned
        # 0 with an empty state and ci-wait.sh polled until its timeout.
        CI_FALLBACK_STATE="error"
        CI_FALLBACK_DETAIL="gh run list --commit $sha returned JSON that isn't a list of runs: $runs_json"
        return 1
    }
    return 0
}
