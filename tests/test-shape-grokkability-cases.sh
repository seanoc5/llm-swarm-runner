#!/usr/bin/env bash
# Checks fixture integrity, NOT whether a model's prose is grokkable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq -e '
  length == 12
  and (map(.id) | unique | length) == length
  and (map(select(.split == "development")) | length) == 8
  and (map(select(.split == "held-out")) | length) == 4
  and (map(.surface) | unique | sort) == ["chat","epic","issue","pr","runtime"]
  and all(.[];
    (.id | type == "string" and length > 0)
    and (.facts | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    and (.expected | keys | sort) == ["action","context","status"]
    and (.expected | all(.[]; type == "string" and length > 0))
    and (.material_errors | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  )
' "$SCRIPT_DIR/fixtures/grokkability/cases.json" >/dev/null
echo "PASS: grokkability fixtures have facts, comprehension keys and held-out coverage"
