#!/usr/bin/env bash
# needs-you output is held to the same rules as a coordinator reply.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../reply/lint-coordinator-reply.sh" "$@"
