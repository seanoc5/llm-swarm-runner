#!/usr/bin/env bash
# update-worker-claude.sh — the one way the Claude Code that workers run gets
# updated (#742).
#
# Workers run ~/.npm-global/bin/claude, which sandbox.sh mounts read-only over
# the container's own copy (the image's /usr/bin/claude is only a fallback for
# a host whose ~/.npm-global is empty). Workers cannot update it and run with
# DISABLE_AUTOUPDATER=1, so this script is the only writer. It installs inside
# the sandbox image (so the host needs no npm) as the host user, then prints
# the before/after versions.
#
# Usage: scripts/update-worker-claude.sh [<version>|latest|stable]   (default: latest)
#
# Already-running workers keep the process they started with; new workers
# (and a restarted worker) pick up the new version. npm should replace the
# binary file rather than overwrite it in place (not tested), so update when few
# workers are mid-run if you can.
#
# This is separate from the host's own `claude` (a native install under
# ~/.local/bin) that the coordinator runs. After a model switch, update both
# (docs/model-switch-recipe.md, Step 2).
set -euo pipefail
IMAGE="llm-swarm-runner:latest"   # same fixed name as sandbox.sh
TARGET="${1:-latest}"
PREFIX_DIR="$HOME/.npm-global"
PKG="@anthropic-ai/claude-code"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { echo "update-worker-claude: image $IMAGE missing; run scripts/build-image.sh first" >&2; exit 1; }
mkdir -p "$PREFIX_DIR"

installed() {
    # Missing package.json (new host, empty prefix) is normal: print nothing, return 0
    # so set -e does not kill the script before the install that fills it.
    sed -n '/^ *"version": *"/{s/^ *"version": *"\([^"]*\)".*/\1/p;q}' "$PREFIX_DIR/lib/node_modules/$PKG/package.json" 2>/dev/null || true
}

before="$(installed)"
[ -n "$before" ] || echo "update-worker-claude: no worker Claude Code installed yet"
docker run --rm --user "$(id -u):$(id -g)" \
    -v "$PREFIX_DIR:/home/sandbox/.npm-global:rw" \
    -e NPM_CONFIG_PREFIX=/home/sandbox/.npm-global \
    -e HOME=/home/sandbox \
    "$IMAGE" npm install -g "$PKG@$TARGET"
after="$(installed)"

echo "update-worker-claude: $before -> $after (target $TARGET)"
echo "New and restarted workers use $after; running workers keep their current process."
