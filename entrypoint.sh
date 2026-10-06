#!/bin/bash
# Register the host's docker group GID so group-name lookups don't warn.
# DOCKER_GID is injected by sandbox.sh when the socket is present.
if [ -n "${DOCKER_GID:-}" ] && ! getent group "$DOCKER_GID" &>/dev/null; then
    sudo groupadd -f -g "$DOCKER_GID" docker 2>/dev/null || true
fi
if [ "${WORKER_CMD:-}" = "agy" ] && [ -n "${GEMINI_API_KEY:-}" ]; then
    # Worker containers have a fresh writable ~/.gemini tmpfs and no host
    # keyring. A key alone is ignored until Antigravity selects its provider.
    mkdir -p "$HOME/.gemini/antigravity-cli"
    printf '{"modelProvider":"gemini"}\n' > "$HOME/.gemini/antigravity-cli/settings.json"
fi
exec "$@"
