#!/usr/bin/env bash
# needs-you output is held to the same rules as a coordinator reply, except
# lede-identifier (an item is a title plus background, not a reply lede; same
# exclusion as scripts/needs-you.sh). A deny-list, so rules added later apply.
CHECKS_SKIP_RULES="${CHECKS_SKIP_RULES:+$CHECKS_SKIP_RULES,}lede-identifier" \
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../reply/lint-coordinator-reply.sh" "$@"
