#!/usr/bin/env bash
#
# test-shape-review.sh — Non-LLM shape tests for the self-review machinery
# (ringer concept #2; docs/ringer-adoptions.md):
#
#   - self-review-pr.sh   verdict parsing, exit codes, --post, idempotency,
#                         WORKER_SELF_REVIEW kill switch
#   - swarm-merge.sh      BLOCK-verdict merge gate + --override-review
#
# Stubs `gh`, `claude`, and `tmux` via PATH override — no GitHub auth, no
# LLM tokens, no tmux server.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$SCRIPT_DIR/../scripts/self-review-pr.sh"
MERGE="$SCRIPT_DIR/../scripts/swarm-merge.sh"
for s in "$REVIEW" "$MERGE"; do
    [ -x "$s" ] || red "not executable: $s"
done

# This suite exercises the self-review verdict gate in isolation; the
# migration-collision gate (#294) is covered by its own
# tests/test-shape-migration-check.sh. Disable it here so the fixture repo
# (which has no real PR base/head branches for migration-collision-check.sh
# to fetch) doesn't trip an unrelated gate.
export MIGRATION_GATE=0

TEST_DIR=$(mktemp -d -t shape-review-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────── Stub gh + claude + tmux ───────────────────────────

export GH_LOG="$TEST_DIR/gh.log"
export GH_COMMENTS_FILE="$TEST_DIR/comments.txt"
export CLAUDE_STUB_OUTPUT="$TEST_DIR/review-output.txt"
export GH_PR_JSON_FILE="$TEST_DIR/pr.json"
export CODEX_ARGS_LOG="$TEST_DIR/codex.args"
export CODEX_PAYLOAD_LOG="$TEST_DIR/codex.payload"
unset SELF_REVIEW_CMD SELF_REVIEW_MODEL WORKER_CMD WORKER_MODEL SELF_REVIEW_UNSET_API_KEY ANTHROPIC_API_KEY
: > "$GH_COMMENTS_FILE"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
    "api repos/{owner}/{repo}/issues/"*) echo "false"; exit 0 ;;
    "pr diff")    echo "diff --git a/f.txt b/f.txt"; exit 0 ;;
    "pr comment") exit 0 ;;
    "pr merge")   exit 0 ;;
    "pr view")
        case "$*" in
            *"--json headRefOid --jq"*) echo "${GH_HEAD:-}"; exit 0 ;;
            *"--json comments") cat "$GH_PR_JSON_FILE" 2>/dev/null; exit 0 ;;
            *comments,headRefOid*) cat "$GH_PR_JSON_FILE" 2>/dev/null; exit 0 ;;
            *comments*)          cat "$GH_COMMENTS_FILE" 2>/dev/null; exit 0 ;;
            *title,body*)        printf 'Fake PR title\n\nFake PR body\n'; exit 0 ;;
            *state,mergeable*)   echo '{"state":"OPEN","mergeable":"MERGEABLE","headRefName":"fix/issue-9","title":"fake"}'; exit 0 ;;
        esac
        exit 0 ;;
    "issue view")
        case "$*" in
            *closedByPullRequestsReferences*) echo "77"; exit 0 ;;
            *"--json url"*)
                n="${3:-}"
                [[ " ${GH_ISSUES:-} " == *" $n "* ]] || exit 1
                jq -n -c --arg u "https://github.com/o/r/issues/$n" --arg s "${GH_ISSUE_STATE:-OPEN}" --arg b "${GH_ISSUE_BODY-Follow-up to #42}" --arg l "${GH_ISSUE_LABELS:-}" '{url:$u,state:$s,title:"follow-up",body:$b,labels:($l|split(",")|map(select(length>0)|{name:.}))}'; exit 0 ;;
            *state*)                          echo "OPEN"; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
cat > "$TEST_DIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # consume the payload from stdin
echo "$* | cwd=$PWD" >> "${CLAUDE_ARGS_LOG:-/dev/null}"
echo "key=${ANTHROPIC_API_KEY:-unset}" > "${CLAUDE_ENV_LOG:-/dev/null}"
cat "$CLAUDE_STUB_OUTPUT"
exit "${CLAUDE_STUB_EXIT:-0}"
EOF
cat > "$TEST_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEST_DIR/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CODEX_ARGS_LOG"
cat > "$CODEX_PAYLOAD_LOG"
while [ $# -gt 0 ]; do
    if [ "$1" = "--output-last-message" ]; then
        cp "$CLAUDE_STUB_OUTPUT" "$2"
        break
    fi
    shift
done
# A progress line must never be mistaken for the final verdict.
echo 'APPROVE'
exit "${CODEX_STUB_EXIT:-0}"
EOF
chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/claude" "$TEST_DIR/bin/codex" "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH"

# ============================================================================
heading "Test 1: APPROVE verdict → exit 0"
# ============================================================================
printf 'APPROVE\n' > "$CLAUDE_STUB_OUTPUT"
if OUT=$("$REVIEW" 42); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 for APPROVE, got $RC"
echo "$OUT" | grep -q "verdict: APPROVE" || red "verdict line missing"
green "APPROVE parsed, exit 0"

# ============================================================================
heading "Test 2: BLOCK verdict → exit 2; APPROVE_WITH_CAVEATS → exit 3"
# ============================================================================
printf 'BLOCK: missing null check in foo()\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "expected exit 2 for BLOCK, got $RC"
printf 'APPROVE_WITH_CAVEATS: no test for timeout path\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 3 ] || red "expected exit 3 for CAVEATS, got $RC"
green "BLOCK → 2, APPROVE_WITH_CAVEATS → 3"

# ============================================================================
heading "Test 3: unparseable output → exit 1"
# ============================================================================
printf 'I think this is probably fine?\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "expected exit 1 for unparseable, got $RC"
green "unparseable verdict → exit 1"

# ============================================================================
heading "Test 3b: markdown-wrapped verdicts still parse (#213)"
# ============================================================================
printf '`APPROVE_WITH_CAVEATS: no test for timeout path`\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 3 ] || red "backtick-wrapped CAVEATS: expected exit 3, got $RC"
printf '**BLOCK: broken invariant**\n' > "$CLAUDE_STUB_OUTPUT"
if "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "bold-wrapped BLOCK: expected exit 2, got $RC"
printf '```\nAPPROVE\n```\n' > "$CLAUDE_STUB_OUTPUT"
if OUT=$("$REVIEW" 42); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "code-fenced APPROVE: expected exit 0, got $RC"
echo "$OUT" | grep -q "verdict: APPROVE" || red "code-fenced APPROVE: verdict line missing"
green "backtick/bold/code-fence wrapped verdicts parse"

# ============================================================================
heading "Test 4: --post adds marker comment; idempotent on re-run"
# ============================================================================
printf 'BLOCK: broken invariant\n' > "$CLAUDE_STUB_OUTPUT"
: > "$GH_LOG"
if "$REVIEW" 42 --post >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "post run: expected exit 2, got $RC"
grep -q "pr comment 42" "$GH_LOG" || red "no pr comment call logged"
green "--post posts the verdict comment"

# Simulate the comment now existing → second --post must skip
printf '<!-- SWARM_SELF_REVIEW: BLOCK -->\nreview text\n' > "$GH_COMMENTS_FILE"
: > "$GH_LOG"
OUT=$("$REVIEW" 42 --post || true)
echo "$OUT" | grep -q "post: skipped" || red "expected idempotent skip"
grep -q "pr comment" "$GH_LOG" && red "comment posted despite existing marker"
green "idempotent: existing marker comment → post skipped"

# ============================================================================
heading "Test 5: WORKER_SELF_REVIEW=0 kill switch → exit 4"
# ============================================================================
if WORKER_SELF_REVIEW=0 "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 4 ] || red "expected exit 4 when kill switch set, got $RC"
green "WORKER_SELF_REVIEW=0 → skipped (exit 4)"

heading "Codex reviews use the selected model and final answer, and fail closed"
printf 'BLOCK: broken invariant\n' > "$CLAUDE_STUB_OUTPUT"
if WORKER_CMD=codex WORKER_MODEL=test-luna "$REVIEW" 42 >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "Codex final BLOCK must win over progress APPROVE (rc=$RC)"
grep -q -- '--model test-luna' "$CODEX_ARGS_LOG" || red "worker model not passed to Codex"
grep -q -- '--sandbox read-only' "$CODEX_ARGS_LOG" || red "Codex review must use read-only sandbox"
grep -q 'Fake PR body' "$CODEX_PAYLOAD_LOG" || red "Codex review missing PR body"
grep -q 'diff --git' "$CODEX_PAYLOAD_LOG" || red "Codex review missing diff"
if SELF_REVIEW_CMD=codex SELF_REVIEW_MODEL=test-sol "$REVIEW" 42 --model explicit-sol >/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "explicit Codex review failed (rc=$RC)"
grep -q -- '--model explicit-sol' "$CODEX_ARGS_LOG" || red "--model must override SELF_REVIEW_MODEL"
if WORKER_CMD=codex CODEX_STUB_EXIT=9 "$REVIEW" 42 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "failed Codex invocation must fail closed (rc=$RC)"
green "Codex model selection, stdin payload, final verdict, and failure handling"

heading "claude -p failure surfaces its output and the API-key hint (#673)"
printf 'API Error: 400 You have reached your specified API usage limits\n' > "$CLAUDE_STUB_OUTPUT"
ERR="$(ANTHROPIC_API_KEY=sk-test CLAUDE_STUB_EXIT=1 "$REVIEW" 42 2>&1 >/dev/null)" && RC=0 || RC=$?
[ "$RC" -eq 1 ] || red "failed claude -p must exit 1 (rc=$RC)"
printf '%s' "$ERR" | grep -q 'usage limits' || red "claude -p output not echoed on failure"
printf '%s' "$ERR" | grep -q 'env -u ANTHROPIC_API_KEY' || red "API-key hint missing"
printf '%s' "$ERR" | grep -q 'ERROR: claude -p review invocation failed' || red "ERROR line missing"
ERR="$(CLAUDE_STUB_EXIT=1 "$REVIEW" 42 2>&1 >/dev/null)" && RC=0 || RC=$?
printf '%s' "$ERR" | grep -q 'API-key auth' && red "API-key hint shown without a key set"
export CLAUDE_ENV_LOG="$TEST_DIR/claude.env"
printf 'APPROVE\n' > "$CLAUDE_STUB_OUTPUT"
ANTHROPIC_API_KEY=sk-test SELF_REVIEW_UNSET_API_KEY=1 "$REVIEW" 42 >/dev/null || red "review with key unset failed"
grep -q 'key=unset' "$CLAUDE_ENV_LOG" || red "SELF_REVIEW_UNSET_API_KEY=1 did not unset the key"
ANTHROPIC_API_KEY=sk-test "$REVIEW" 42 >/dev/null || red "review failed"
grep -q 'key=sk-test' "$CLAUDE_ENV_LOG" || red "key must pass through by default"
unset CLAUDE_ENV_LOG
green "failure output echoed, hint shown, unset knob works"

# ============================================================================
heading "Test 6: swarm-merge BLOCK gate"
# ============================================================================
# Fixture repo so swarm-merge can resolve a main worktree.
cd "$TEST_DIR"
mkdir repo && cd repo
git init -q -b master
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

printf '<!-- SWARM_SELF_REVIEW: BLOCK -->\nreview text\n' > "$GH_COMMENTS_FILE"
: > "$GH_LOG"
if "$MERGE" 9 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] || red "merge should refuse on BLOCK verdict"
grep -q "pr merge" "$GH_LOG" && red "gh pr merge was called despite BLOCK"
green "BLOCK verdict refuses merge, gh pr merge never called"

: > "$GH_LOG"
if "$MERGE" 9 --override-review >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "override-review merge failed (rc=$RC)"
grep -q "pr merge 77" "$GH_LOG" || red "gh pr merge not called under --override-review"
green "--override-review proceeds to merge"

# No verdict comment → merge proceeds (informational only)
: > "$GH_COMMENTS_FILE"
: > "$GH_LOG"
if "$MERGE" 9 >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "merge without verdict comment should proceed (rc=$RC)"
grep -q "pr merge 77" "$GH_LOG" || red "gh pr merge not called in no-verdict case"
green "no verdict comment → merge proceeds"

# ============================================================================
heading "Test N: --caveats-nonblocking records the follow-up marker (no review run)"
# ============================================================================
pr_json() {   # pr_json <head> <marker>...
    local head="$1"; shift
    printf '%s\n' "$@" | jq -R -s -c --arg h "$head" \
        '{headRefOid:$h, comments: (split("\n") | map(select(length>0)) | map({body:., authorAssociation:"OWNER"}))}' \
        > "$GH_PR_JSON_FILE"
}
printf 'BLOCK: the stub review must never run in this mode\n' > "$CLAUDE_STUB_OUTPUT"
pr_json abc123 '<!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=coordinator head=abc123 -->'
: > "$GH_LOG"
if OUT=$(GH_ISSUES=900 "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "expected exit 0 recording non-blocking caveats, got $RC (output: $OUT)"
grep -q "pr comment 42 --body <!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=coordinator head=abc123 caveats=nonblocking followup=900 -->" "$GH_LOG" \
    || red "marker with caveats=nonblocking followup=900 not posted. gh log: $(cat "$GH_LOG")"
grep -q "pr diff" "$GH_LOG" && red "--caveats-nonblocking must not run a review"
green "--caveats-nonblocking posts the marker on the reviewed head"

: > "$GH_LOG"
if OUT=$(GH_ISSUES= "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "missing follow-up issue should exit 1, got $RC"
grep -q "pr comment" "$GH_LOG" && red "posted despite a missing follow-up issue"
green "refuses when the follow-up issue doesn't exist"

if OUT=$(GH_ISSUES=900 "$REVIEW" 42 --caveats-nonblocking 900 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "actor=worker should be refused, got $RC"
green "refuses for the worker (author) actor"

pr_json abc123 '<!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=coordinator head=abc123 -->'
: > "$GH_LOG"
if OUT=$(GH_ISSUES=900 GH_ISSUE_STATE=CLOSED "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "a CLOSED follow-up should exit 1, got $RC"
echo "$OUT" | grep -q "not OPEN" || red "refusal should say the follow-up is not OPEN (output: $OUT)"
grep -q "pr comment" "$GH_LOG" && red "posted despite a closed follow-up issue"
: > "$GH_LOG"
if OUT=$(GH_ISSUES=900 GH_ISSUE_BODY="Unrelated; mentions #421 and #4200 only" "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "an unrelated follow-up should exit 1, got $RC"
echo "$OUT" | grep -q "does not mention #42" || red "refusal should say the follow-up lacks the PR reference (output: $OUT)"
grep -q "pr comment" "$GH_LOG" && red "posted despite an unrelated follow-up issue"
green "refuses a closed follow-up and one that doesn't reference the PR (#421/#4200 are not #42)"

pr_json abc123 '<!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=coordinator head=abc123 -->'
: > "$GH_LOG"
if OUT=$(GH_ISSUES=900 GH_ISSUE_STATE=CLOSED GH_ISSUE_BODY="Unrelated" GH_ISSUE_LABELS="from-pr-42" "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "a CLOSED from-pr-42 follow-up should still exit 1, got $RC"
grep -q "pr comment" "$GH_LOG" && red "posted despite a closed labelled follow-up"
: > "$GH_LOG"
if OUT=$(GH_ISSUES=900 GH_ISSUE_BODY="Unrelated" GH_ISSUE_LABELS="swarm-followup,from-pr-42" "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 0 ] || red "an OPEN from-pr-42 follow-up with no #42 text should pass, got $RC (output: $OUT)"
grep -q "pr comment 42" "$GH_LOG" || red "marker not posted for the labelled follow-up"
if OUT=$(GH_ISSUES=900 GH_ISSUE_BODY="Unrelated" GH_ISSUE_LABELS="from-pr-421" "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "label from-pr-421 must not match PR 42, got $RC"
green "accepts an open from-pr-N-labelled follow-up; closed or other-PR labels refused"


pr_json abc123 '<!-- SWARM_SELF_REVIEW: APPROVE_WITH_CAVEATS actor=coordinator head=0ldc0de -->'
: > "$GH_LOG"
if OUT=$(GH_ISSUES=900 "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "stale-head review should exit 1, got $RC"
grep -q "pr comment" "$GH_LOG" && red "posted a record for a stale head"
pr_json abc123 '<!-- SWARM_SELF_REVIEW: BLOCK actor=coordinator head=abc123 -->'
if OUT=$(GH_ISSUES=900 "$REVIEW" 42 --caveats-nonblocking 900 --actor coordinator 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 1 ] || red "a BLOCK review must not be recorded as non-blocking caveats, got $RC"
green "refuses on a stale head or a non-caveats verdict"

[ "$(head -n1 "$REVIEW")" = "#!/usr/bin/env bash" ] || red "self-review-pr.sh must start with its shebang"

# ============================================================================
heading "Test R: the claude review is read-only and runs from a scratch dir (#599)"
# ============================================================================
export CLAUDE_ARGS_LOG="$TEST_DIR/claude.args"
: > "$CLAUDE_ARGS_LOG"
printf 'APPROVE\n' > "$CLAUDE_STUB_OUTPUT"
( cd "$TEST_DIR" && "$REVIEW" 42 >/dev/null )
ARGS="$(cat "$CLAUDE_ARGS_LOG")"
case "$ARGS" in *dangerously-skip-permissions*) red "review must not skip permissions: $ARGS" ;; esac
case "$ARGS" in *"--permission-mode dontAsk"*) ;; *) red "review must deny unlisted tools (dontAsk): $ARGS" ;; esac
case "$ARGS" in *"--tools Read,Grep,Glob,Bash "*) ;; *) red "available tools must exclude Write/Edit: $ARGS" ;; esac
case "$ARGS" in *"Bash(gh pr diff:*) Bash(git log:*) Bash(git show:*)"*) ;; *) red "allowlist must be the three read-only prefixes: $ARGS" ;; esac
case "$ARGS" in *"cwd=$TEST_DIR") red "review must not run from the caller's cwd: $ARGS" ;; esac
case "$ARGS" in *"cwd=/"*swarm-review-scratch-*) ;; *) red "review must run from a scratch dir: $ARGS" ;; esac
green "claude -p: no skip-permissions, dontAsk, Read/Grep/Glob/Bash only, three read-only Bash prefixes, scratch cwd"

# ============================================================================
heading "Test S: --post on an unchanged head is a no-op per actor (#599)"
# ============================================================================
export GH_HEAD=abc123
printf 'APPROVE\n' > "$CLAUDE_STUB_OUTPUT"
: > "$CLAUDE_ARGS_LOG"; : > "$GH_LOG"
pr_json abc123 '<!-- SWARM_SELF_REVIEW: BLOCK actor=worker head=abc123 -->'
if OUT=$("$REVIEW" 42 --post --actor worker 2>&1); then RC=0; else RC=$?; fi
[ "$RC" -eq 2 ] || red "repeat on same head+actor must replay BLOCK (exit 2), got $RC: $OUT"
[ ! -s "$CLAUDE_ARGS_LOG" ] || red "same head+actor must not launch a review"
grep -q "pr comment" "$GH_LOG" && red "same head+actor must not post"
grep -q "pr diff" "$GH_LOG" && red "same head+actor must not even fetch the diff"
# Different actor on the same head is the independent review: runs.
if "$REVIEW" 42 --post --actor coordinator >/dev/null 2>&1; then RC=0; else RC=$?; fi
[ -s "$CLAUDE_ARGS_LOG" ] || red "coordinator review on a worker-reviewed head must run"
# Same actor, but the head moved: runs.
: > "$CLAUDE_ARGS_LOG"
export GH_HEAD=def456
"$REVIEW" 42 --post --actor worker >/dev/null 2>&1 || true
[ -s "$CLAUDE_ARGS_LOG" ] || red "a new head must be reviewed again"
# --force overrides.
: > "$CLAUDE_ARGS_LOG"; export GH_HEAD=abc123
"$REVIEW" 42 --post --force --actor worker >/dev/null 2>&1 || true
[ -s "$CLAUDE_ARGS_LOG" ] || red "--force must re-run"
# A marker from a non-owner commenter cannot suppress the review.
printf '%s\n' '<!-- SWARM_SELF_REVIEW: APPROVE actor=worker head=abc123 -->' | jq -R -s -c '{headRefOid:"abc123",comments:[{body:.,authorAssociation:"NONE"}]}' > "$GH_PR_JSON_FILE"
: > "$CLAUDE_ARGS_LOG"
"$REVIEW" 42 --post --actor worker >/dev/null 2>&1 || true
[ -s "$CLAUDE_ARGS_LOG" ] || red "an untrusted marker must not suppress the review"
green "same head+actor skipped (verdict replayed); other actor, new head, --force, untrusted marker all run"

# ============================================================================
heading "All self-review machinery shape tests passed"
green "verdict parsing, exit codes, --post idempotency, kill switch, merge gate"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
