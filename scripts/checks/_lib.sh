# _lib.sh — shared by scripts/checks/*/ adapters (sourced, not run).
# emit <check> <severity warn|error> <line> <match> <message>
# prints one JSON line in the stable format documented in docs/checks.md.
emit() {
    jq -nc --arg c "$1" --arg s "$2" --argjson l "${3:-0}" --arg m "$4" --arg msg "$5" \
        '{check:$c, severity:$s, line:$l, match:$m, message:$msg}'
}
# find_line <file> <text>: 1-based line of the first line equal to <text>, else 0.
find_line() {
    local n
    n="$(grep -nFx -- "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1)"
    echo "${n:-0}"
}
