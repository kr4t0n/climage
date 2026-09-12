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
# produce different images. Both CLIs track their npm `latest`; Claude Code also
# publishes a slower `stable` tag, which this image deliberately does not use.
ARG INSTALL_CLAUDE_CODE=true
ARG CLAUDE_CODE_VERSION=2.1.263
ARG INSTALL_CODEX=true
ARG CODEX_VERSION=0.153.4
ARG INSTALL_SKILLS=true
ARG SKILLS_VERSION=1.5.23
# Heavyweight package groups, measured: media pulls 172 packages / ~409 MB
# (ffmpeg alone drags in LLVM, mesa GL drivers and a speech synthesiser), build
# tools another ~231 MB. Both default on; turn either off for a slim variant.
ARG INSTALL_MEDIA=true
ARG INSTALL_BUILD_TOOLS=true
# Headless-browser system libraries, off by default — the `full` variant turns
# them on. Deps only, no browser binary: a Playwright/Puppeteer browser build
# has to match the client library version, so baking one in would just be
# re-downloaded by any project on a different version. The libraries are the
# part that needs root, and the part that is version-agnostic.
ARG INSTALL_BROWSER=false
# First-party tooling, off by default — the `full` image variant turns it on.
# Pinned to an exact release for the same reason the agent CLIs are.
ARG INSTALL_ARGUS=false
ARG ARGUS_VERSION=0.3.3

ENV DEBIAN_FRONTEND=noninteractive

# Documentation is dead weight in an agent image; copyright files stay for
# licence compliance. Must precede every apt install to take effect.
RUN printf '%s\n' \
        'path-exclude /usr/share/doc/*' \
        'path-include /usr/share/doc/*/copyright' \
        'path-exclude /usr/share/man/*' \
        'path-exclude /usr/share/info/*' \
        > /etc/dpkg/dpkg.cfg.d/01-climage-nodoc

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
        sqlite3 \
        unzip \
        zip \
        xz-utils \
        bzip2 \
        shellcheck \
        python3 \
        tmux \
        vim-tiny \
        procps \
        htop \
        tini \
        locales \
        tzdata \
    && if [ "${INSTALL_MEDIA}" = "true" ]; then \
        apt-get install -y --no-install-recommends \
            ffmpeg \
            imagemagick \
            poppler-utils; \
    fi \
    && if [ "${INSTALL_BUILD_TOOLS}" = "true" ]; then \
        apt-get install -y --no-install-recommends \
            build-essential \
            pkg-config; \
    fi \
    # Chromium links the ATK/AT-SPI accessibility stack and several X11
    # extensions unconditionally, headless included, so these are not optional
    # for a browser that starts at all. fonts-liberation keeps screenshots from
    # rendering as boxes. On Debian 13 the three libat* names gain a `t64`
    # suffix (the 64-bit time_t transition) — see AGENTS.md.
    && if [ "${INSTALL_BROWSER}" = "true" ]; then \
        apt-get install -y --no-install-recommends \
            libatk1.0-0 \
            libatk-bridge2.0-0 \
            libatspi2.0-0 \
            libxcomposite1 \
            libxdamage1 \
            libxfixes3 \
            libxrandr2 \
            libxkbcommon0 \
            libxext6 \
            libx11-6 \
            libxcb1 \
            libnss3 \
            libnspr4 \
            libcups2 \
            libdbus-1-3 \
            libdrm2 \
            libgbm1 \
            libasound2 \
            libpango-1.0-0 \
            libcairo2 \
            libglib2.0-0 \
            fonts-liberation; \
    fi \
    && rm -rf /var/lib/apt/lists/* \
    # Debian ships these under alternate names to avoid binary clashes.
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -s "$(command -v batcat)" /usr/local/bin/bat \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    # locale-gen compiles into /usr/lib/locale; the source definitions and
    # charmaps (~17 MB) are not needed at runtime.
    && rm -rf /usr/share/i18n

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# --- Runtime user -----------------------------------------------------------
# Rename the base image's `node` account rather than creating a second user:
# keeping uid/gid 1000 is what makes bind-mounted host files land with sane
# ownership. Everything downstream refers to ${USERNAME}, never `node`.
# DL3064 pattern-matches the name `USERNAME` as a possible credential; this is a
# Unix account name with a literal value, so the rule is silenced here only.
# hadolint ignore=DL3064
ARG USERNAME=climage
RUN groupmod -n "${USERNAME}" node \
    && usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m node \
    && chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

# --- Python toolchain: uv + ruff --------------------------------------------
COPY --from=uv-bin /uv /uvx /usr/local/bin/
COPY --from=ruff-bin /ruff /usr/local/bin/ruff

# Interpreters live outside $HOME: they are large, shared across users, and a
# mounted-over home must not hide the toolchain. uv *tools* go the other way —
# see the runtime-extension block below.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

RUN uv python install "${PYTHON_VERSION}" \
    # Debian's own python3 stays at /usr/bin for system scripts; /usr/local/bin
    # comes first on PATH, so `python`/`python3` mean the pinned interpreter.
    && ln -sfn "$(uv python find "${PYTHON_VERSION}")" /usr/local/bin/python3 \
    && ln -sfn "$(uv python find "${PYTHON_VERSION}")" /usr/local/bin/python \
    # Kept for derived images that point UV_TOOL_DIR/UV_TOOL_BIN_DIR back here to
    # bake tools into a layer; /opt/uv/bin stays on PATH so that is a one-line
    # ENV override with no PATH surgery.
    && mkdir -p /opt/uv/tools /opt/uv/bin \
    && chown -R "${USERNAME}:${USERNAME}" /opt/uv \
    && chmod -R a+rX /opt/uv

# --- Agent CLIs -------------------------------------------------------------
RUN if [ "${INSTALL_CLAUDE_CODE}" = "true" ]; then \
        npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    fi \
    && if [ "${INSTALL_CODEX}" = "true" ]; then \
        npm install -g "@openai/codex@${CODEX_VERSION}"; \
    fi \
    && if [ "${INSTALL_SKILLS}" = "true" ]; then \
        npm install -g "skills@${SKILLS_VERSION}"; \
    fi \
    && npm cache clean --force

# --- First-party tooling ----------------------------------------------------
# argus ships plain release binaries next to a SHASUMS256.txt manifest, so this
# fetches and verifies them directly instead of piping the project's installer
# into a shell. Two reasons, beyond the usual one: the installer resolves the
# newest release at build time — and its scan does not exclude pre-releases, so
# an unpinned build can land on an RC — and the script itself is served from a
# mutable branch. This performs the same SHA-256 check against a pinned tag.
ARG TARGETARCH
RUN if [ "${INSTALL_ARGUS}" = "true" ]; then \
        base="https://github.com/kr4t0n/argus/releases/download/argus-sidecar-v${ARGUS_VERSION}" \
        && tmp="$(mktemp -d)" \
        && curl -fsSL "${base}/SHASUMS256.txt" -o "${tmp}/SHASUMS256.txt" \
        && for bin in argus-sidecar argus-bg; do \
            asset="${bin}-linux-${TARGETARCH}" \
            && curl -fsSL "${base}/${asset}" -o "${tmp}/${asset}" \
            # awk rewrites the manifest's bare filename to the temp path, and
            # emits nothing at all if the asset is not listed — sha256sum then
            # fails on an empty check list, so an unlisted or renamed asset
            # cannot slip through unverified.
            && awk -v a="${asset}" -v d="${tmp}" '$2 == a { print $1 "  " d "/" a }' \
                 "${tmp}/SHASUMS256.txt" | sha256sum -c - \
            && install -m 0755 "${tmp}/${asset}" "/usr/local/bin/${bin}"; \
        done \
        && rm -rf "${tmp}"; \
    fi

# Everything the unprivileged user installs at runtime lands in $HOME, so a
# volume mounted there carries it across container restarts: npm globals in
# .npm-global, uv tools in .uv. All three dirs precede /usr/local/bin on PATH.
ENV NPM_CONFIG_PREFIX=/home/${USERNAME}/.npm-global \
    UV_TOOL_DIR=/home/${USERNAME}/.uv/tools \
    UV_TOOL_BIN_DIR=/home/${USERNAME}/.uv/bin
ENV PATH=/home/${USERNAME}/.npm-global/bin:/home/${USERNAME}/.uv/bin:/opt/uv/bin:${PATH}

# Debian's /etc/profile overwrites PATH wholesale, so a login shell
# (`bash -lc ...`, as agents often spawn) would lose the directories above.
RUN printf 'export PATH="%s/bin:%s:/opt/uv/bin:$PATH"\n' \
        "${NPM_CONFIG_PREFIX}" "${UV_TOOL_BIN_DIR}" \
        > /etc/profile.d/10-climage-path.sh \
    && chmod 0644 /etc/profile.d/10-climage-path.sh \
    && mkdir -p "${NPM_CONFIG_PREFIX}" "${UV_TOOL_DIR}" "${UV_TOOL_BIN_DIR}" \
        "/home/${USERNAME}/.cache" /workspace \
    && chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}" /workspace

# Record which optional groups this image was built with, so the smoke test can
# require exactly what is meant to be present and users can introspect a pull.
RUN printf 'INSTALL_MEDIA=%s\nINSTALL_BUILD_TOOLS=%s\nINSTALL_BROWSER=%s\nINSTALL_CLAUDE_CODE=%s\nINSTALL_CODEX=%s\nINSTALL_SKILLS=%s\nINSTALL_ARGUS=%s\n' \
        "${INSTALL_MEDIA}" "${INSTALL_BUILD_TOOLS}" "${INSTALL_BROWSER}" \
        "${INSTALL_CLAUDE_CODE}" "${INSTALL_CODEX}" "${INSTALL_SKILLS}" \
        "${INSTALL_ARGUS}" \
        > /etc/climage-build.env

COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 scripts/climage-idle.sh /usr/local/bin/climage-idle

USER ${USERNAME}
WORKDIR /workspace

ENV UV_CACHE_DIR=/home/${USERNAME}/.cache/uv \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NODE_ENV=development

# tini reaps the zombies long-lived agent sessions leave behind.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
# Not a plain `bash`: with a terminal climage-idle execs one anyway, but without
# one (a Kubernetes pod, a detached container) bash would read EOF and exit,
# looking like a crash. Parking there instead lets orchestrators run the image
# unmodified — no keep-alive command in the manifest. See scripts/climage-idle.sh.
CMD ["climage-idle"]

# Populated by CI from docker/metadata-action; see .github/workflows/ci.yml.
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown
LABEL org.opencontainers.image.title="climage" \
      org.opencontainers.image.description="Base image for CLI coding agents: Node.js, Python (uv/ruff), and common command-line tooling." \
      org.opencontainers.image.source="https://github.com/kr4t0n/climage" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"
