#!/usr/bin/env bash
# test-coordinator-conversation.sh — scripts/coordinator-conversation.sh (issue #744):
# the clean conversation view shows operator messages and coordinator reply
# text only, hides every other transcript kind, picks the coordinator's own
# interactive session (never a worker's or a headless run), and follows a new
# session. No tmux, no claude; works on a fixture transcript.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/scripts/coordinator-conversation.sh"
FIX="$ROOT/tests/fixtures/coordinator-conversation/session.jsonl"
T="$(mktemp -d -t coord-conv-XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ── 1. fixture: exactly the SHOW lines, nothing HIDE ──
out="$("$VIEW" --file "$FIX" --once --tail 100)"
for want in SHOW-reply-one SHOW-operator-one SHOW-reply-two SHOW-operator-queued "SHOW-operator-two with a screenshot"; do
    grep -qF "$want" <<<"$out" || red "missing visible message: $want"
done
green "operator and coordinator messages shown"
if grep -n 'HIDE' <<<"$out"; then red "hidden kind leaked (lines above)"; fi
green "tool calls/results, thinking, doorbells, stop-hook text, task notifications, compaction, subagent and synthetic turns all hidden"
[ "$(grep -c "── you" <<<"$out")" = 3 ] && [ "$(grep -c '── coordinator' <<<"$out")" = 2 ] \
    || red "expected 3 operator + 2 coordinator messages"
green "message count and order"
first="$(grep -m1 -o 'SHOW-[a-z-]*' <<<"$out")"; [ "$first" = "SHOW-reply-one" ] || red "order wrong: $first"

# ── 2. --tail keeps only the last N messages ──
last="$("$VIEW" --file "$FIX" --once --tail 1)"
grep -qF "SHOW-operator-two" <<<"$last" && ! grep -qF "SHOW-reply-one" <<<"$last" || red "--tail 1 should keep only the last message"
green "--tail N"

# ── 3. session discovery ──
PROJ="$T/proj"; mkdir -p "$PROJ"
SLUG="$(printf '%s' "$(cd "$PROJ" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"
export CLAUDE_PROJECTS_DIR="$T/projects"
D="$CLAUDE_PROJECTS_DIR/$SLUG"; mkdir -p "$D" "$CLAUDE_PROJECTS_DIR/${SLUG}-worktrees-wt-issue-9"
rec() { printf '{"type":"assistant","entrypoint":"%s","timestamp":"2026-11-05T03:00:00.000Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$2"; }
rec cli  "SHOW-coordinator-session" > "$D/aaa.jsonl"; touch -d '2026-11-05 03:00:00' "$D/aaa.jsonl"
rec sdk-cli "HIDE-headless-run"      > "$D/bbb.jsonl"; touch -d '2026-11-05 04:00:00' "$D/bbb.jsonl"
rec cli  "HIDE-worker-session"       > "$CLAUDE_PROJECTS_DIR/${SLUG}-worktrees-wt-issue-9/ccc.jsonl"
mkdir -p "$D/aaa"; rec cli "HIDE-subagent-dir" > "$D/aaa/sub.jsonl"
out="$("$VIEW" "$PROJ" --once)"
grep -qF SHOW-coordinator-session <<<"$out" && ! grep -q HIDE <<<"$out" || red "session discovery picked the wrong transcript: $out"
green "picks the interactive project session; ignores headless runs, worker dirs and subagent files"

# ── 4. read-only: nothing under the project or transcripts changed ──
before="$(find "$T" -type f -printf '%p %s %T@\n' | sort | md5sum)"
"$VIEW" "$PROJ" --once >/dev/null
[ "$before" = "$(find "$T" -type f -printf '%p %s %T@\n' | sort | md5sum)" ] || red "files changed"
green "read-only"

# ── 5. follow mode: new lines appear; a newer session is followed ──
log="$T/follow.out"
timeout 8 "$VIEW" "$PROJ" --interval 1 --tail 0 >"$log" 2>&1 &
vp=$!
sleep 2
rec cli "SHOW-appended-line" >> "$D/aaa.jsonl"
sleep 2.5
rec cli "SHOW-new-session" > "$D/ddd.jsonl"; touch -d 'now + 1 hour' "$D/ddd.jsonl"
sleep 2.5
wait "$vp" 2>/dev/null || true
grep -qF SHOW-appended-line "$log" || red "appended line not followed: $(cat "$log")"
grep -qF SHOW-new-session "$log" || red "new session not followed: $(cat "$log")"
! grep -q HIDE "$log" || red "follow leaked hidden text"
green "follows appended lines and a newer session"
# ── 6. a bad CONV_HIDE_RE is refused, not silently blanking the view ──
if CONV_HIDE_RE="(" "$VIEW" --file "$FIX" --once >/dev/null 2>&1; then red "invalid CONV_HIDE_RE accepted"; fi
green "invalid CONV_HIDE_RE refused"

# ── 7. real operator messages that merely look like doorbells stay visible ──
# (review of PR #750: prefix/last-line matching hid these; the watcher's
# human_typed_since matches the whole message, issue #497)
hum() { jq -nc --arg t "$1" '{type:"user",entrypoint:"cli",timestamp:"2026-11-05T05:00:00.000Z",origin:{kind:"human"},message:{role:"user",content:$t}}'; }
NUDGE='Inbox: 2 item(s) in .swarm/coord-inbox/ — read and triage them (see prompts/coordinator.md "Inbox"). Woke for: 2 worker results.'
{
  hum "Stop hook is broken, fix it"                                  # 1: starts with the old "Stop hook" prefix
  hum "can you check why the nudge ended with Woke for: 2 workers"   # 2: not a doorbell line at all
  hum $'Woke for: ci is what I want to rename, thoughts?'            # 2b: line starting with the phrase
  hum $'Please look at this too.\n'"$NUDGE"                          # 3: operator text sharing a turn with a doorbell
  hum "$NUDGE"$'\nand also merge PR 12'                              # 3b: same, operator text after the doorbell
  hum "$NUDGE also merge PR 13"                                       # 3c: operator text on the doorbell's own line (after Woke for)
  hum "Continue your task from where you left off. Also merge PR 14"  # 3d: same line, bare nudge
  hum "Execute the Initial Startup Checklist. Then merge PR 15"       # 3e: same line, startup prompt
  hum "${NUDGE%% Woke for*} Also merge PR 16"                          # 3f: same line, tail with no Woke for
  hum "Continue your task from where you left off."                  # real nudge: hidden
  hum "$NUDGE"                                                       # real doorbell: must stay hidden
} > "$T/lookalike.jsonl"
out="$("$VIEW" --file "$T/lookalike.jsonl" --once --tail 100)"
for want in "Stop hook is broken, fix it" "why the nudge ended with Woke for" "Woke for: ci is what I want to rename" \
            "Please look at this too." "and also merge PR 12" "also merge PR 13" "Also merge PR 14" "Then merge PR 15" "Also merge PR 16"; do
    grep -qF "$want" <<<"$out" || red "real operator message hidden: $want"
done
[ "$(grep -c "── you" <<<"$out")" = 9 ] || red "expected 9 visible messages (the bare doorbells hidden): $out"
green "Stop hook / Woke for lookalikes and doorbell-sharing turns stay visible; bare doorbell hidden"
echo "all coordinator-conversation checks passed"
