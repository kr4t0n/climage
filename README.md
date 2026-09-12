# climage

A batteries-included container image for **CLI coding agents**.

Agents that work in a terminal spend most of their time shelling out — grepping a
repo, converting a video, running a test suite, formatting Python. `climage`
packages that surface area once: an official Node.js base, a complete Python
toolchain built on `uv` and `ruff`, and the command-line utilities agents reach
for by reflex. Point your agent at this image instead of installing tooling on
first run.

This repository contains the image definition and the CI pipeline that publishes
it to Docker Hub. There is no application code.

## What's inside

| Area | Tools |
| --- | --- |
| Runtimes | `node`, `npm`, `npx`, `python3` (Debian), uv-managed CPython |
| Python toolchain | `uv`, `uvx`, `ruff` |
| Search & text | `rg` (ripgrep), `fd`, `bat`, `jq`, `tree`, `file`, `less`, `diff`, `patch`, `moreutils` |
| Media & documents | `ffmpeg`, `ffprobe`, `convert` (ImageMagick), `pdftotext` (poppler) |
| VCS & network | `git`, `git-lfs`, `gh`, `ssh`, `curl`, `wget`, `rsync`, `dig`, `ping`, `nc`, `socat` |
| Data | `sqlite3` |
| Build | `build-essential` (`gcc`, `make`), `pkg-config` |
| Shell & process | `bash`, `tmux`, `vim.tiny`, `htop`, `procps`, `shellcheck`, `tini` |
| Archives | `unzip`, `zip`, `xz`, `bzip2`, `tar`, `gzip` |
| Agent CLIs | `claude` (Claude Code), `codex` (OpenAI Codex), `skills` (open agent-skills manager) — all optional, on by default |
| First-party | `argus-sidecar`, `argus-bg` — off by default, in the [`full`](#image-variants) variant |

`python` and `python3` resolve to the uv-managed CPython (3.12 by default), not
Debian's system interpreter — the pinned version is what runs, whichever name an
agent types.

Runs as the unprivileged `climage` user (uid/gid 1000) with `/workspace` as the
working directory. `tini` is PID 1 so long-lived agent sessions reap their children. The
image is designed to be extended at runtime without root: `uv tool install` and
`npm install -g` both work as the `climage` user, in interactive and login
shells, and both write under `$HOME` — so a volume mounted at `/home/climage`
carries whatever an agent installs across restarts.

The default command adapts to how the container was started: a terminal gets an
interactive shell, piped stdin is run as a script, and a container with neither
(a Kubernetes pod, a detached container) parks so you can exec into it. Passing
your own command bypasses it entirely.

## Prerequisites

- Docker 24+ with BuildKit (Docker 29 tested)
- `docker buildx` for multi-architecture builds (bundled with Docker Desktop and
  recent Docker Engine)
- Optional, for local linting: `hadolint`, `shellcheck`

## Quick start

Pull the published image and drop into a shell with your project mounted:

```bash
docker run --rm -it -v "$PWD:/workspace" kr4t0n/climage
```

Run a one-off command:

```bash
docker run --rm -v "$PWD:/workspace" kr4t0n/climage rg -n "TODO"
```

If your host uid is not 1000, mounted files will be owned by a different user
inside the container. Run as yourself to keep write access:

```bash
docker run --rm -it --user "$(id -u):$(id -g)" -v "$PWD:/workspace" kr4t0n/climage
```

## Build, test, run

```bash
make build        # build for the host architecture, tagged climage:dev
make test         # build, then run tests/smoke.sh inside the image
make shell        # interactive shell with $PWD mounted at /workspace
make run CMD="uv --version"
make lint         # hadolint + shellcheck
make size         # report the image size
make push         # multi-arch build + push to Docker Hub (CI normally does this)
make help         # list all targets
```

### Image variants

Three variants are published. `latest` is the one to use unless you need
something it does not have.

| Tag | Contents | Uncompressed | Compressed (registry) |
| --- | --- | --- | --- |
| `latest` | everything in the table above | 2.0 GB | 698 MB |
| `slim` | no media or build-tool packages | 1.4 GB | 463 MB |
| `full` | `latest` plus first-party tooling (`argus-sidecar`, `argus-bg`) and the headless-browser libraries | +30 MB | +14 MB |

```bash
docker pull kr4t0n/climage:full
```

Build any of them locally with the matching build args:

```bash
docker build --build-arg INSTALL_ARGUS=true --build-arg INSTALL_BROWSER=true -t climage:full .
docker build --build-arg INSTALL_MEDIA=false --build-arg INSTALL_BUILD_TOOLS=false -t climage:slim .
```

### Headless browsers

The `full` variant ships the system libraries Chromium needs, so Playwright and
Puppeteer work as the unprivileged user with no `apt` and no root:

```bash
docker run --rm kr4t0n/climage:full bash -lc \
    'npm i playwright && npx playwright install chromium && node my-script.js'
```

Only the libraries are baked in, not a browser binary — a Playwright browser
build must match the client library version, so a bundled one would simply be
re-downloaded by any project on a different version. `playwright install`
downloads into `~/.cache/ms-playwright`, which a volume mounted at
`/home/climage` will persist.

On `latest` or `slim` the same script fails when Chromium starts. Installing the
libraries at runtime needs root *and* an `apt-get update` first, because the
image ships no package index:

```bash
docker exec -u 0 <container> bash -lc 'apt-get update && apt-get install -y \
    --no-install-recommends libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
    libxcomposite1 libxdamage1'
```

## Agent skills

The [`skills`](https://github.com/vercel-labs/skills) CLI installs skills from
the open agent-skills ecosystem into whichever agents are present:

```bash
skills add vercel-labs/agent-skills --list                       # browse a source
skills add vercel-labs/agent-skills --skill frontend-design \
    --global --agent claude-code --agent codex --yes             # non-interactive
skills list --global
```

Skills install to a canonical `~/.agents/skills/<name>/` and are symlinked into
each agent's own directory (`~/.claude/skills/`, and Codex's universal location).
Because that all lives under `$HOME`, a volume mounted at `/home/climage`
persists installed skills along with agent credentials. Skills execute with full
agent permissions, so review a source before installing it.

## Configuration

### Build arguments

| Argument | Default | Purpose |
| --- | --- | --- |
| `NODE_VERSION` | `24` | Node.js major version (official image tag) |
| `USERNAME` | `climage` | Runtime account name; the base image's `node` user is renamed to it, keeping uid/gid 1000 |
| `DEBIAN_SUITE` | `bookworm` | Debian suite of the base image |
| `PYTHON_VERSION` | `3.12` | CPython version installed via `uv python install` |
| `UV_VERSION` | `0.12.13` | `uv`/`uvx` release copied from Astral's image |
| `RUFF_VERSION` | `0.16.7` | `ruff` release copied from Astral's image |
| `INSTALL_CLAUDE_CODE` | `true` | Set `false` to omit the Claude Code CLI |
| `CLAUDE_CODE_VERSION` | `2.1.269` | Exact Claude Code version (npm `latest`) |
| `INSTALL_CODEX` | `true` | Set `false` to omit the Codex CLI |
| `CODEX_VERSION` | `0.154.0` | Exact Codex CLI version (npm `latest`) |
| `INSTALL_SKILLS` | `true` | Set `false` to omit the `skills` CLI |
| `INSTALL_MEDIA` | `true` | ffmpeg, ImageMagick, poppler — ~409 MB with dependencies |
| `INSTALL_BUILD_TOOLS` | `true` | `build-essential`, `pkg-config` — ~231 MB |
| `INSTALL_ARGUS` | `false` | Bundle `argus-sidecar` and `argus-bg`; on in the `full` variant |
| `INSTALL_BROWSER` | `false` | Headless-Chromium system libraries; on in the `full` variant — ~18 MB, since the media group already provides most of the chain |
| `ARGUS_VERSION` | `0.3.3` | Exact [argus](https://github.com/kr4t0n/argus) release, without the `argus-sidecar-v` tag prefix |
| `SKILLS_VERSION` | `1.5.26` | Exact [skills](https://github.com/vercel-labs/skills) version |
| `VERSION`, `REVISION`, `CREATED` | `dev`/`unknown` | OCI labels, populated by CI |

### Runtime environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLIMAGE_INIT` | unset | Path to a script the entrypoint sources before the command — use it for per-container bootstrap |
| `UV_CACHE_DIR` | `/home/climage/.cache/uv` | Mount a volume here to persist Python downloads |
| `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` | `/home/climage/.uv/tools`, `/home/climage/.uv/bin` | Where `uv tool install` puts tools and their entry points — under `$HOME`, so a home volume persists them |
| `NPM_CONFIG_PREFIX` | `/home/climage/.npm-global` | Lets the unprivileged user `npm install -g` at runtime |
| `LANG` | `en_US.UTF-8` | Locale is generated in the image |

### Publishing credentials

| Name | Where | Purpose |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | GitHub secret / `.env` | Docker Hub namespace and login |
| `DOCKERHUB_TOKEN` | GitHub secret / `.env` | Docker Hub access token, Read & Write scope |
| `IMAGE_NAME` | GitHub repo variable (optional) | Image name; defaults to `climage` |

## Project structure

```
.
├── Dockerfile                 # the image definition (single source of truth)
├── .dockerignore              # keeps the build context to scripts/ only
├── .hadolint.yaml             # Dockerfile lint rules
├── Makefile                   # build / test / run / push helpers
├── .env.example               # template for local publishing credentials
├── .pre-commit-config.yaml    # hadolint + shellcheck + hygiene hooks
├── scripts/
│   ├── entrypoint.sh          # workspace checks, optional init hook, exec
│   └── climage-idle.sh        # the default CMD: shell, script, or park
├── tests/
│   └── smoke.sh               # tool inventory assertions, run inside the image
└── .github/
    ├── dependabot.yml         # weekly base-image and action bumps
    └── workflows/ci.yml       # lint -> build & test -> publish
```

## Contributing

```bash
uv add --dev pre-commit   # or: pipx install pre-commit
pre-commit install
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).
Adding a tool means updating three places: the `Dockerfile` package list, the
`REQUIRED` array in `tests/smoke.sh`, and the table in this README.
