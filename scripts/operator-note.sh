#!/usr/bin/env bash
# operator-note.sh — pass an operator decision to the coordinator work run
# (issue #767, ADR 0006 section 4).
#
# A work run starts with no memory of the conversation, so anything the
# operator said that it must honor goes through a file.
#
# Usage:
#   operator-note.sh [--project DIR] [--standing] "<text>"
#   echo "<text>" | operator-note.sh [--project DIR] [--standing] -
#
#   (default)    one-off note: writes <ts>-operator-<pid>-<rand>.md into
#                <project>/.swarm/coord-inbox/. The inbox classifier treats
#                the unknown kind "operator" as urgent, so a run starts at
#                once; the run acts on it and archives it.
#   --standing   a standing instruction ("hold #123"): also appends
#                "- <UTC ts> <text>" to <project>/.swarm/operator-notes.md,
#                which every run reads first. Remove a line to lift it.
#   --project    swarm project dir (default: $CLAUDE_PROJECT_DIR, else $PWD).
#
# Prints the inbox file path. Exit 2 on bad usage or a dir with no .swarm/.
set -euo pipefail

STANDING=0 proj_dir="" TEXT="" HAVE_TEXT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        --standing) STANDING=1; shift ;;
        --project)  proj_dir="${2:?--project needs a directory}"; shift 2 ;;
        -)          TEXT="$(cat)"; HAVE_TEXT=1; shift ;;
        -*)         echo "operator-note.sh: unknown option $1" >&2; exit 2 ;;
        *)          [ "$HAVE_TEXT" = 0 ] || { echo "operator-note.sh: give the note as one argument" >&2; exit 2; }
                    TEXT="$1"; HAVE_TEXT=1; shift ;;
    esac
done

[ "$HAVE_TEXT" = 1 ] && [ -n "${TEXT//[[:space:]]/}" ] \
    || { echo "operator-note.sh: empty note (usage: operator-note.sh [--standing] \"<text>\")" >&2; exit 2; }

proj_dir="${proj_dir:-${CLAUDE_PROJECT_DIR:-$PWD}}"
SWARM="$proj_dir/.swarm"
[ -d "$SWARM" ] || { echo "operator-note.sh: no .swarm/ in $proj_dir (use --project)" >&2; exit 2; }

INBOX="$SWARM/coord-inbox"
mkdir -p "$INBOX"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$STANDING" = 1 ]; then
    NOTES="$SWARM/operator-notes.md"
    if [ ! -s "$NOTES" ]; then
        printf '# Operator notes\n\nStanding instructions from the operator. Every coordinator work run reads this first and treats each line as binding until it is removed.\n\n' > "$NOTES"
    fi
    # One line per note: fold newlines so a multi-line note stays one entry.
    printf -- '- %s %s\n' "$ISO" "$(printf '%s' "$TEXT" | tr '\n' ' ')" >> "$NOTES"
fi

TMP="$(mktemp "$INBOX/.tmp.operator-note.XXXXXX")"
{
    printf 'Operator note (%s)%s:\n\n%s\n' "$ISO" "$([ "$STANDING" = 1 ] && echo ', also in .swarm/operator-notes.md')" "$TEXT"
} > "$TMP"
FINAL="$INBOX/${TS}-operator-$$-${RANDOM}.md"
mv -f "$TMP" "$FINAL"
printf '%s\n' "$FINAL"
