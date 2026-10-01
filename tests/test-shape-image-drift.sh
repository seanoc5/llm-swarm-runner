#!/usr/bin/env bash
# test-shape-image-drift.sh — build-image.sh stamps the Dockerfile hash and
# sandbox.sh compares it (#517). Pure text checks; no docker needed.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -q -- '--label "dockerfile_sha=' "$ROOT/scripts/build-image.sh" || red "build-image.sh does not stamp dockerfile_sha"
green "build-image.sh stamps dockerfile_sha"
grep -q 'Labels "dockerfile_sha"' "$ROOT/sandbox.sh" || red "sandbox.sh does not read the dockerfile_sha label"
grep -q 'scripts/build-image.sh' "$ROOT/sandbox.sh" || red "sandbox.sh build-if-missing no longer uses build-image.sh"
green "sandbox.sh compares the label and builds via build-image.sh"
