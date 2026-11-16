#!/usr/bin/env bash
#
# test-claude-trust.sh — issue #950: scripts/_claude-trust.sh pre-accepts the
# "trust this folder" dialog in a per-container ~/.claude.json copy, for both
# the symlinked and the symlink-resolved worktree path; and the watcher's
# worker_pane_trust_dialog recognises the dialog text in a pane.
# No docker needed.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/.."
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
# shellcheck source=../scripts/_claude-trust.sh
. "$REPO/scripts/_claude-trust.sh"

T="$(mktemp -d -t claude-trust-XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/real/wt-issue-9"
ln -s "$T/real" "$T/link"
RESOLVED="$(realpath "$T/link/wt-issue-9")"
LINKED="$(realpath -s "$T/link/wt-issue-9")"
[ "$RESOLVED" != "$LINKED" ] || red "fixture: symlink did not diverge"

CFG="$T/cfg.json"
echo '{"hasCompletedOnboarding":true,"projects":{"/other":{"allowedTools":["x"]}}}' > "$CFG"
claude_config_trust_paths "$CFG" "$RESOLVED" "$LINKED"
for p in "$RESOLVED" "$LINKED"; do
    [ "$(jq -r --arg p "$p" '.projects[$p].hasTrustDialogAccepted' "$CFG")" = true ] || red "no trust for $p: $(cat "$CFG")"
done
[ "$(jq -r '.hasCompletedOnboarding' "$CFG")" = true ] || red "top-level field lost"
[ "$(jq -c '.projects["/other"]' "$CFG")" = '{"allowedTools":["x"]}' ] || red "other project clobbered"
green "trust set for resolved + symlinked path, rest of config kept"

# Existing entry keeps its own fields; idempotent (byte-identical on rerun).
jq --arg p "$RESOLVED" '.projects[$p].allowedTools=["Bash"] | .projects[$p].hasTrustDialogAccepted=false' "$CFG" > "$CFG.n" && mv "$CFG.n" "$CFG"
claude_config_trust_paths "$CFG" "$RESOLVED"
[ "$(jq -cS --arg p "$RESOLVED" '.projects[$p]' "$CFG")" = '{"allowedTools":["Bash"],"hasTrustDialogAccepted":true}' ] || red "entry merge wrong: $(cat "$CFG")"
before="$(cksum < "$CFG")"; claude_config_trust_paths "$CFG" "$RESOLVED" "$LINKED"
[ "$before" = "$(cksum < "$CFG")" ] || red "second run changed the file"
green "false -> true, sibling fields kept, idempotent"

# No .projects key yet.
echo '{"a":1}' > "$CFG"; claude_config_trust_paths "$CFG" "$RESOLVED"
[ "$(jq -r --arg p "$RESOLVED" '.projects[$p].hasTrustDialogAccepted' "$CFG")" = true ] || red "missing projects key not handled"
green "config without a projects key"

# Bad inputs are left alone.
: > "$CFG"; claude_config_trust_paths "$CFG" "$RESOLVED"; [ ! -s "$CFG" ] || red "empty file was written"
echo 'not json {' > "$CFG"; claude_config_trust_paths "$CFG" "$RESOLVED"; [ "$(cat "$CFG")" = 'not json {' ] || red "invalid file was modified"
claude_config_trust_paths "$T/missing.json" "$RESOLVED"; [ ! -e "$T/missing.json" ] || red "missing file was created"
echo '{"projects":[1]}' > "$CFG"; claude_config_trust_paths "$CFG" "$RESOLVED"; [ "$(cat "$CFG")" = '{"projects":[1]}' ] || red "non-object projects modified"
ls "$T"/cfg.json.trust.* >/dev/null 2>&1 && red "temp file leaked"
green "empty / invalid / missing / malformed-projects files untouched, no temp leak"

# Detection regex (extracted verbatim from the watcher, tmux stubbed).
SESSION_NAME=s
eval "$(sed -n '/^worker_pane_trust_dialog() {/,/^}/p' "$REPO/scripts/coordinator-watch.sh")"
PANE=""
tmux() { printf '%s\n' "$PANE"; }
PANE=$' Quick safety check: Is this a project you created or one you trust?\n\n ❯ 1. Yes, I trust this folder\n   2. No, exit'
worker_pane_trust_dialog iss-9 || red "trust dialog not detected"
PANE=$'\x1b[1mQuick safety\x1b[0m check: ...'
PANE=$'\x1b[1mQuick safety check\x1b[0m: Is this a project'
worker_pane_trust_dialog iss-9 || red "ANSI-wrapped dialog not detected"
PANE=$'❯ fix the bug\n  ctx: 12k/200k (6%)'
! worker_pane_trust_dialog iss-9 || red "normal session misread as trust dialog"
green "pane detection: dialog yes (plain + ANSI), normal session no"
