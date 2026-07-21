#!/usr/bin/env bash
#
# run-all-tests.sh — single entry point for tests/test-*.sh.
#
# Runs every suite under a per-suite timeout (default 300s, override with
# TEST_TIMEOUT), streaming each suite's output live, then prints a
# PASS/FAIL/TIMEOUT summary table and exits non-zero if ANY suite did not
# pass.
#
# A suite that can't even be invoked (missing, unreadable) is reported as
# FAIL with a reason line rather than silently dropped from the table or
# the table's total — loud-skip principle, see #179.
#
# Usage:
#   run-all-tests.sh                        # run every tests/test-*.sh suite
#   run-all-tests.sh --only 'test-shape-*'  # filter by glob against basename
#   run-all-tests.sh --list                 # enumerate suites, run nothing
#   TEST_TIMEOUT=600 run-all-tests.sh       # raise the per-suite timeout
#
# Exit codes: 0 all suites passed, 1 one or more suites failed/timed out,
# 2 usage/setup error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$REPO_ROOT/tests"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"

ONLY=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --only)
            ONLY="${2:?--only requires a glob argument}"
            shift 2
            ;;
        --list)
            LIST_ONLY=1
            shift
            ;;
        *)
            echo "run-all-tests.sh: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

[ -d "$TESTS_DIR" ] || { echo "run-all-tests.sh: tests dir not found: $TESTS_DIR" >&2; exit 2; }

SUITES=()
while IFS= read -r -d '' f; do
    SUITES+=("$f")
done < <(find "$TESTS_DIR" -maxdepth 1 -name 'test-*.sh' -print0 | sort -z)

[ "${#SUITES[@]}" -gt 0 ] || { echo "run-all-tests.sh: no tests/test-*.sh suites found" >&2; exit 2; }

if [ -n "$ONLY" ]; then
    FILTERED=()
    for f in "${SUITES[@]}"; do
        base="$(basename "$f")"
        # Intentional unquoted glob match against $ONLY.
        # shellcheck disable=SC2053
        [[ "$base" == $ONLY ]] && FILTERED+=("$f")
    done
    SUITES=("${FILTERED[@]}")
    [ "${#SUITES[@]}" -gt 0 ] || { echo "run-all-tests.sh: --only '$ONLY' matched no suites" >&2; exit 1; }
fi

if [ "$LIST_ONLY" = "1" ]; then
    for f in "${SUITES[@]}"; do
        basename "$f"
    done
    exit 0
fi

LOG_DIR="$(mktemp -d -t run-all-tests-XXXXXX)"

NAMES=()
STATUSES=()
DURATIONS=()
REASONS=()

for f in "${SUITES[@]}"; do
    name="$(basename "$f")"
    NAMES+=("$name")
    log="$LOG_DIR/$name.log"

    printf '\n\033[1;34m=== %s ===\033[0m\n' "$name"

    if [ ! -r "$f" ]; then
        echo "FAIL: suite not readable: $f" | tee "$log" >&2
        STATUSES+=("FAIL")
        DURATIONS+=("-")
        REASONS+=("not readable: $f")
        continue
    fi

    start=$SECONDS
    set +e
    timeout "$TEST_TIMEOUT" bash "$f" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    set -e
    DURATIONS+=("$((SECONDS - start))s")

    if [ "$rc" -eq 0 ]; then
        STATUSES+=("PASS")
        REASONS+=("")
    elif [ "$rc" -eq 124 ]; then
        STATUSES+=("TIMEOUT")
        REASONS+=("exceeded ${TEST_TIMEOUT}s (TEST_TIMEOUT to raise)")
    else
        STATUSES+=("FAIL")
        reason="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '✗|FAIL|Error|error:' | tail -1)" || true
        [ -n "$reason" ] || reason="exited $rc"
        REASONS+=("$reason")
    fi
done

printf '\n\033[1;34m=== Summary ===\033[0m\n'
printf '%-34s %-8s %-8s %s\n' "SUITE" "STATUS" "TIME" "REASON"
FAIL_COUNT=0
for i in "${!NAMES[@]}"; do
    status="${STATUSES[$i]}"
    case "$status" in
        PASS) color='\033[32m' ;;
        FAIL|TIMEOUT) color='\033[31m'; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        *) color='' ;;
    esac
    printf "${color}%-34s %-8s %-8s %s\033[0m\n" "${NAMES[$i]}" "$status" "${DURATIONS[$i]}" "${REASONS[$i]}"
done

echo
echo "Logs: $LOG_DIR"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "$FAIL_COUNT/${#NAMES[@]} suite(s) failed."
    exit 1
else
    echo "All ${#NAMES[@]} suites passed."
    exit 0
fi
