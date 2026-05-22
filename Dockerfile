FROM buildpack-deps:noble

ARG DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# Toolchain version pins
# -----------------------------------------------------------------------------
# All four LLM CLIs and the two non-apt installs (deno, uv) are pinned to
# explicit versions so `docker build` is reproducible. To upgrade any tool,
# bump its ARG below or pass `--build-arg <NAME>=<VERSION>` on the command
# line. Verify upstream's release notes before bumping — npm packages
# occasionally rename flags (claude-code) or change tool-call protocols
# (gemini-cli) in minor releases.
#
# Find the current latest with:
#   npm view @anthropic-ai/claude-code version
#   npm view @google/gemini-cli version
#   npm view @openai/codex version
#   npm view promptfoo version
#   curl -s https://api.github.com/repos/denoland/deno/releases/latest    | jq -r .tag_name
#   curl -s https://api.github.com/repos/astral-sh/uv/releases/latest     | jq -r .tag_name
#
# (Apt-managed tools — Java, ripgrep, gh, docker-cli — are intentionally NOT
# pinned to dpkg version strings; the maintenance overhead outweighs the
# benefit for a personal-dev sandbox. Major versions are still pinned via
# package selection: openjdk-21, NodeSource setup_22.x.)
ARG NODE_MAJOR=22
ARG CLAUDE_CODE_VERSION=2.1.126
ARG GEMINI_CLI_VERSION=0.40.1
ARG OPENAI_CODEX_VERSION=0.128.0
ARG PROMPTFOO_VERSION=0.121.9
ARG DENO_VERSION=2.7.14
ARG UV_VERSION=0.11.8

# buildpack-deps:noble already provides:
#   build-essential, curl, wget, git, ca-certificates, gnupg, and a large set of dev libs.
#
# ubuntu-standard fills in the Linux userland (man pages, common utilities, etc.).
# Intentionally NO --no-install-recommends here — the recommended packages are the point.
RUN apt-get update \
    && apt-get install -y ubuntu-standard \
    && rm -rf /var/lib/apt/lists/*

# Tools not covered by buildpack-deps or ubuntu-standard
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq ripgrep fd-find unzip zip sudo \
    openssh-client \
    postgresql-client \
    less vim tree htop tmux \
    iproute2 net-tools \
    && rm -rf /var/lib/apt/lists/*

# JDK 21
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jdk-headless \
    && rm -rf /var/lib/apt/lists/*

# Node — major pinned via NodeSource setup script; minor/patch tracks
# whatever NodeSource ships for that major (their releases are stable).
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Deno — pinned via `sh -s v<version>` arg the installer accepts.
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s "v${DENO_VERSION}"

# Python 3 + uv (python3 may already be present; uv is not).
# Install uv from the GitHub release tarball directly — astral's install.sh
# hardcodes APP_VERSION to whatever's current at fetch time and ignores any
# UV_VERSION env var, so it can't be used for pinning. The tarball URL IS
# version-pinnable.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=1 \
        uv-x86_64-unknown-linux-gnu/uv \
        uv-x86_64-unknown-linux-gnu/uvx

# LLM CLIs & Tools — each npm package pinned to its exact version. Bump
# the ARG above to upgrade. promptfoo and openai/codex are less impactful
# (we don't currently script against them); claude-code and gemini-cli
# are load-bearing for the swarm.
RUN npm install -g \
    "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    "@google/gemini-cli@${GEMINI_CLI_VERSION}" \
    "@openai/codex@${OPENAI_CODEX_VERSION}" \
    "promptfoo@${PROMPTFOO_VERSION}"

# Fix gemini-cli's missing vendored ripgrep — the npm package omits the
# binary, so symlink the system rg (already installed earlier in this
# Dockerfile) into the path gemini's getRipgrepPath() expects. Without
# this, gemini logs "Ripgrep is not available. Falling back to GrepTool."
# and uses a slower built-in matcher.
# (linux-x64 only; build args would be needed for arm64 multi-arch.)
RUN GEMINI_DIR="$(npm root -g)/@google/gemini-cli" \
    && mkdir -p "${GEMINI_DIR}/bundle/vendor/ripgrep" \
    && ln -sf /usr/bin/rg "${GEMINI_DIR}/bundle/vendor/ripgrep/rg-linux-x64"

# Docker CLI + Compose v2 plugin (for DooD — Testcontainers, `docker compose -f ...`)
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user matching host UID
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupadd -f -g ${HOST_GID} sandbox \
    && useradd -m -u ${HOST_UID} -g ${HOST_GID} -s /bin/bash sandbox 2>/dev/null \
    || usermod -u ${HOST_UID} -g ${HOST_GID} -d /home/sandbox -m -l sandbox ubuntu 2>/dev/null; \
    echo "sandbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sandbox

# Entrypoint: registers host docker group GID at container start
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Configure NPM global for the sandbox user
RUN mkdir -p /home/sandbox/.npm-global \
    && chown -R sandbox:sandbox /home/sandbox/.npm-global
ENV NPM_CONFIG_PREFIX=/home/sandbox/.npm-global
ENV PATH="/home/sandbox/.npm-global/bin:/home/sandbox/.local/bin:${PATH}"

# Pre-create cache directories and set permissions
RUN mkdir -p /home/sandbox/.npm /home/sandbox/.cache/pip /home/sandbox/.cache/uv \
    && chown -R sandbox:sandbox /home/sandbox

# Add aliases for LLM CLIs
RUN echo "alias claude='claude --dangerously-skip-permissions'" >> /home/sandbox/.bashrc \
    && echo "alias gemini='gemini --yolo'" >> /home/sandbox/.bashrc

USER sandbox
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
