#!/usr/bin/env bash
#
# lint-brief.sh — Lint a task brief for verifiability before dispatch.
#
# Brief/manifest linting is a concept adopted from Nate B. Jones's ringer
# (its manifest lint rejects tasks whose checks cannot fail, whose specs are
# underspecified, or whose specs are mere pointers). Original bash
# implementation against our brief format, no code copied — attribution in
# docs/ringer-adoptions.md #6.
#
# Warn-only by default: provisioning proceeds, but the operator/coordinator
# sees exactly why a brief may produce unverifiable work. Lints:
#
#   no-done-definition   neither a <!-- SWARM_CHECK: --> marker nor an
#                        acceptance-criteria section / checklist — the
#                        executed check can't verify this task
#   check-cannot-fail    SWARM_CHECK is `true`/`:`/`echo …`/`exit 0` —
#                        a check that can't fail verifies nothing
#   no-named-files       no file/path named anywhere in the task — the
#                        worker must guess where to work
#   underspecified       task section under 200 characters — workers can't
#                        ask the issue author questions
#
# Only the `## Task` section onward is linted when present (the brief
# preamble — refs index, guardrails — would trigger false
# positives). Whole file is linted if there is no `## Task` heading.
#
# Usage:
#   lint-brief.sh [--strict] <brief-file>
#
# Exit codes: 0 clean (or findings in warn-only mode), 1 findings with
# --strict, 2 usage/IO error.
set -euo pipefail

STRICT=0
FILE=""
for a in "$@"; do
    case "$a" in
        --strict) STRICT=1 ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "lint-brief: unknown flag '$a'" >&2; exit 2 ;;
        *)  FILE="$a" ;;
    esac
done
[ -n "$FILE" ] && [ -r "$FILE" ] || { echo "Usage: $0 [--strict] <brief-file>" >&2; exit 2; }

# Lint scope: from '## Task' onward if present, else the whole brief.
TASK=$(awk '/^## Task$/{found=1} found{print}' "$FILE")
[ -n "$TASK" ] || TASK=$(cat "$FILE")

FINDINGS=0
warn() { echo "lint-brief: WARN $1: $2"; FINDINGS=$((FINDINGS + 1)); }

# --- no-done-definition ------------------------------------------------------
CHECK_CMD=$(printf '%s\n' "$TASK" \
    | sed -n 's/.*<!-- SWARM_CHECK: \(.*\) -->.*/\1/p' | head -1)
HAS_ACCEPTANCE=0
printf '%s\n' "$TASK" | grep -qiE '(acceptance criteria|acceptance:|definition of done|^- \[ \])' \
    && HAS_ACCEPTANCE=1
if [ -z "$CHECK_CMD" ] && [ "$HAS_ACCEPTANCE" = "0" ]; then
    warn no-done-definition \
        "no SWARM_CHECK marker and no acceptance criteria/checklist — the executed check cannot verify this task"
fi

# --- check-cannot-fail -------------------------------------------------------
if [ -n "$CHECK_CMD" ]; then
    NORM=$(printf '%s' "$CHECK_CMD" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$NORM" in
        true|:|"exit 0"|echo|"echo "*)
            warn check-cannot-fail \
                "SWARM_CHECK '\`$NORM\`' cannot fail, so the task cannot be verified"
            ;;
    esac
fi

# --- no-named-files ----------------------------------------------------------
# Path-like token: contains a '/' or a filename with an extension.
if ! printf '%s\n' "$TASK" | grep -qE '([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+|[A-Za-z0-9_-]+\.[a-z]{1,10}\b)'; then
    warn no-named-files \
        "no file or path named in the task — the worker must guess where to work"
fi

# --- underspecified ----------------------------------------------------------
TASK_CHARS=$(printf '%s' "$TASK" | wc -c)
if [ "$TASK_CHARS" -lt 200 ]; then
    warn underspecified \
        "task section is only ${TASK_CHARS} chars — workers cannot ask the issue author questions; spell the work out"
fi

if [ "$FINDINGS" -eq 0 ]; then
    echo "lint-brief: clean ($FILE)"
    exit 0
fi
echo "lint-brief: $FINDINGS finding(s) in $FILE$([ "$STRICT" = "1" ] && echo ' (--strict: failing)' || echo ' (warn-only; dispatch proceeds)')"
[ "$STRICT" = "1" ] && exit 1
exit 0
