# syntax=docker/dockerfile:1.7
#
# climage — a batteries-included base image for CLI coding agents.
#
# Layout:
#   node (official)  -> JS/TS runtime + npm/npx
#   uv + ruff        -> Python toolchain, copied from Astral's release images
#   apt layer        -> search/media/build tooling agents shell out to
#
# All versions are build args so they can be pinned per build and bumped by
# Dependabot in one place. See README.md for the supported matrix.

ARG NODE_VERSION=24
ARG DEBIAN_SUITE=bookworm
ARG UV_VERSION=0.12.5
ARG RUFF_VERSION=0.16.4

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin
FROM ghcr.io/astral-sh/ruff:${RUFF_VERSION} AS ruff-bin

FROM node:${NODE_VERSION}-${DEBIAN_SUITE}-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG PYTHON_VERSION=3.12
# Agent CLIs are pinned to exact versions rather than a dist-tag: both publish
# several times a week, and a floating tag makes two builds of the same commit
# produce different images. Note that Claude Code's `stable` tag intentionally
# trails `latest`; the pin below tracks `stable`.
ARG INSTALL_CLAUDE_CODE=true
ARG CLAUDE_CODE_VERSION=2.1.231
ARG INSTALL_CODEX=true
ARG CODEX_VERSION=0.149.1

ENV DEBIAN_FRONTEND=noninteractive

# --- Bootstrap: keyring tooling needed to add the GitHub CLI apt repo --------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && rm -rf /var/lib/apt/lists/*

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list

# --- Agent tooling ----------------------------------------------------------
# Grouped by purpose so the list stays reviewable:
#   vcs/net | search & text | media & documents | data | build | shell/process
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        git-lfs \
        gh \
        openssh-client \
        wget \
        rsync \
        dnsutils \
        iputils-ping \
        netcat-openbsd \
        socat \
        ripgrep \
        fd-find \
        bat \
        jq \
        tree \
        file \
        less \
        diffutils \
        patch \
        moreutils \
        ffmpeg \
        imagemagick \
        poppler-utils \
        sqlite3 \
        unzip \
        zip \
        xz-utils \
        bzip2 \
        build-essential \
        pkg-config \
        shellcheck \
        python3 \
        python3-venv \
        python3-dev \
        tmux \
        vim-tiny \
        procps \
        htop \
        tini \
        locales \
        tzdata \
    && rm -rf /var/lib/apt/lists/* \
    # Debian ships these under alternate names to avoid binary clashes.
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -s "$(command -v batcat)" /usr/local/bin/bat \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# --- Python toolchain: uv + ruff --------------------------------------------
COPY --from=uv-bin /uv /uvx /usr/local/bin/
COPY --from=ruff-bin /ruff /usr/local/bin/ruff

# Interpreters and uv-managed tools live outside $HOME so they survive a
# mounted-over home directory and stay shared across users.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/opt/uv/bin \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

RUN uv python install "${PYTHON_VERSION}" \
    # Debian's own python3 stays at /usr/bin for system scripts; /usr/local/bin
    # comes first on PATH, so `python`/`python3` mean the pinned interpreter.
    && ln -sfn "$(uv python find "${PYTHON_VERSION}")" /usr/local/bin/python3 \
    && ln -sfn "$(uv python find "${PYTHON_VERSION}")" /usr/local/bin/python \
    && mkdir -p "${UV_TOOL_DIR}" "${UV_TOOL_BIN_DIR}" \
    && chown -R node:node /opt/uv \
    && chmod -R a+rX /opt/uv

# --- Agent CLIs -------------------------------------------------------------
RUN if [ "${INSTALL_CLAUDE_CODE}" = "true" ]; then \
        npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    fi \
    && if [ "${INSTALL_CODEX}" = "true" ]; then \
        npm install -g "@openai/codex@${CODEX_VERSION}"; \
    fi \
    && npm cache clean --force

# Let the unprivileged user install more tooling at runtime: npm globals land
# in $HOME, uv tools in /opt/uv/bin. Both precede /usr/local/bin on PATH.
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:/opt/uv/bin:${PATH}

# Debian's /etc/profile overwrites PATH wholesale, so a login shell
# (`bash -lc ...`, as agents often spawn) would lose the directories above.
RUN printf '%s\n' 'export PATH="/home/node/.npm-global/bin:/opt/uv/bin:$PATH"' \
        > /etc/profile.d/10-climage-path.sh \
    && chmod 0644 /etc/profile.d/10-climage-path.sh \
    && mkdir -p /home/node/.npm-global /home/node/.cache /workspace \
    && chown -R node:node /home/node /workspace

COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

USER node
WORKDIR /workspace

ENV UV_CACHE_DIR=/home/node/.cache/uv \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NODE_ENV=development

# tini reaps the zombies long-lived agent sessions leave behind.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["bash"]

# Populated by CI from docker/metadata-action; see .github/workflows/ci.yml.
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown
LABEL org.opencontainers.image.title="climage" \
      org.opencontainers.image.description="Base image for CLI coding agents: Node.js, Python (uv/ruff), and common command-line tooling." \
      org.opencontainers.image.source="https://github.com/OWNER/climage" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"
