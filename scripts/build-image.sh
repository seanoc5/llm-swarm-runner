#!/usr/bin/env bash
# build-image.sh — build the sandbox image with a Dockerfile-hash label.
#
# sandbox.sh only builds when the image is missing, so a Dockerfile change
# never reaches workers until someone rebuilds by hand (#517: headless
# Chrome sat unbuilt for 22 days). The label lets sandbox.sh warn when the
# running image no longer matches the checked-in Dockerfile.
#
# Usage: scripts/build-image.sh [extra docker build args]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-llm-swarm-runner:latest}"
SHA="$(git -C "$DIR" hash-object Dockerfile)"
REV="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "build-image: $IMAGE from Dockerfile $SHA (checkout $REV)"
exec docker build --label "dockerfile_sha=$SHA" --label "built_from=$REV" -t "$IMAGE" "$@" "$DIR"
