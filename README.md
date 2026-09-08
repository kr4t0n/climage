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

`python` and `python3` resolve to the uv-managed CPython (3.12 by default), not
Debian's system interpreter — the pinned version is what runs, whichever name an
agent types.

Runs as the unprivileged `climage` user (uid/gid 1000) with `/workspace` as the
working directory. `tini` is PID 1 so long-lived agent sessions reap their children. The
image is designed to be extended at runtime without root: `uv tool install` and
`npm install -g` both work as the `climage` user, in interactive and login shells.

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

The smoke test asserts that every tool in the table above resolves on `PATH`,
that `uv` finds its managed interpreter without network access, and that
`/workspace` is writable by the runtime user.

### Slim variants

The two heaviest package groups are build args. Turning both off cuts the image
by roughly a third:

| Variant | Uncompressed | Compressed (registry) |
| --- | --- | --- |
| default | 2.0 GB | 698 MB |
| `INSTALL_MEDIA=false INSTALL_BUILD_TOOLS=false` | 1.4 GB | 463 MB |

Both variants are published, so building one yourself is optional:

```bash
docker pull kr4t0n/climage:slim      # published slim variant
# or build it locally:
docker build --build-arg INSTALL_MEDIA=false --build-arg INSTALL_BUILD_TOOLS=false -t climage:slim .
```

Media is the single biggest group: ffmpeg alone pulls 153 packages, including
LLVM, mesa GL drivers and a speech synthesiser, none of which a headless agent
uses — but ffmpeg itself does not work without them. Drop the group entirely or
keep it; there is no lighter middle ground in Debian.

Each image records what it was built with, so a pulled image is
self-describing:

```bash
docker run --rm kr4t0n/climage cat /etc/climage-build.env
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
persists installed skills along with agent credentials — see the note in
[Configuration](#configuration). Skills execute with full agent permissions, so
review a source before installing it.

## Configuration

### Build arguments

Every version is a build argument, so a variant image is a one-line change:

| Argument | Default | Purpose |
| --- | --- | --- |
| `NODE_VERSION` | `24` | Node.js major version (official image tag) |
| `USERNAME` | `climage` | Runtime account name; the base image's `node` user is renamed to it, keeping uid/gid 1000 |
| `DEBIAN_SUITE` | `bookworm` | Debian suite of the base image |
| `PYTHON_VERSION` | `3.12` | CPython version installed via `uv python install` |
| `UV_VERSION` | `0.12.5` | `uv`/`uvx` release copied from Astral's image |
| `RUFF_VERSION` | `0.16.4` | `ruff` release copied from Astral's image |
| `INSTALL_CLAUDE_CODE` | `true` | Set `false` to omit the Claude Code CLI |
| `CLAUDE_CODE_VERSION` | `2.1.263` | Exact Claude Code version (npm `latest`) |
| `INSTALL_CODEX` | `true` | Set `false` to omit the Codex CLI |
| `CODEX_VERSION` | `0.153.4` | Exact Codex CLI version (npm `latest`) |
| `INSTALL_SKILLS` | `true` | Set `false` to omit the `skills` CLI |
| `INSTALL_MEDIA` | `true` | ffmpeg, ImageMagick, poppler — ~409 MB with dependencies |
| `INSTALL_BUILD_TOOLS` | `true` | `build-essential`, `pkg-config` — ~231 MB |
| `SKILLS_VERSION` | `1.5.23` | Exact [skills](https://github.com/vercel-labs/skills) version |
| `VERSION`, `REVISION`, `CREATED` | `dev`/`unknown` | OCI labels, populated by CI |

```bash
docker build --build-arg NODE_VERSION=22 --build-arg INSTALL_CLAUDE_CODE=false -t climage:node22 .
```

The agent CLIs are pinned to exact versions so a rebuild of a given commit
reproduces the same image. Bumping one is a build-arg override or a one-line
edit:

```bash
docker build --build-arg CODEX_VERSION=0.150.0 -t climage:codex-next .
```
```

### Runtime environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLIMAGE_INIT` | unset | Path to a script the entrypoint sources before the command — use it for per-container bootstrap |
| `UV_CACHE_DIR` | `/home/climage/.cache/uv` | Mount a volume here to persist Python downloads |
| `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` | `/opt/uv/tools`, `/opt/uv/bin` | Where `uv tool install` puts tools and their entry points (writable by `node`, on `PATH`) |
| `NPM_CONFIG_PREFIX` | `/home/climage/.npm-global` | Lets the unprivileged user `npm install -g` at runtime |
| `LANG` | `en_US.UTF-8` | Locale is generated in the image |

### Publishing credentials

Local pushes read `.env` (git-ignored); copy `.env.example` and fill it in. CI
reads the same values from repository secrets — never commit a token.

| Name | Where | Purpose |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | GitHub secret / `.env` | Docker Hub namespace and login |
| `DOCKERHUB_TOKEN` | GitHub secret / `.env` | Docker Hub access token, Read & Write scope |
| `IMAGE_NAME` | GitHub repo variable (optional) | Image name; defaults to `climage` |

## Deployment

`.github/workflows/ci.yml` runs on pull requests, pushes to `main`, and `v*`
tags:

1. **lint** — `hadolint` on the Dockerfile, `shellcheck` on the scripts.
2. **build-test** — builds and smoke-tests both variants (full and slim) on
   both architectures, each on a runner of its own architecture. Pull requests
   stop here.
3. **publish** — on `main` and `v*` tags only: every variant/architecture pair
   is rebuilt on its native runner and pushed to Docker Hub *by digest*, with
   SBOM and provenance attestations.
4. **manifest** — one job per variant, assembling that variant's
   per-architecture digests into a multi-arch tag set with
   `docker buildx imagetools create`.

Every architecture is built on a runner that natively speaks it — `ubuntu-latest`
for amd64, `ubuntu-24.04-arm` for arm64 — rather than emulating arm64 through
QEMU. Emulating an apt layer this size costs tens of minutes per build; native
arm runners are the same speed as amd64 and free for public repositories.

Tags produced by `docker/metadata-action`:

| Trigger | Full build | Slim build |
| --- | --- | --- |
| Push to `main` | `latest`, `sha-<short>` | `slim`, `sha-<short>-slim` |
| Tag `v1.4.2` | `1.4.2`, `1.4`, `1`, `latest`, `sha-<short>` | `1.4.2-slim`, `1.4-slim`, `1-slim`, `sha-<short>-slim` |

`latest` always means the full build: on a release it moves to the tagged
version, and on a `main` push it tracks the newest commit. `slim` is the same
image without the media and build-tool groups. Only the `sha-*` tags are
immutable — pin those, or a semver tag, for reproducibility.

There is no `edge` tag. It existed to mean "newest `main` build" in the
convention where `latest` tracks releases only, but this pipeline points
`latest` at `main` too, so it was a second name for the same digest.

To cut a release: `git tag v1.4.2 && git push origin v1.4.2`.

### One-time setup

1. Create the Docker Hub repository `kr4t0n/climage`.
2. Add `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` under **Settings → Secrets and
   variables → Actions**.

The published image name is `<DOCKERHUB_USERNAME>/<IMAGE_NAME>`, taken from the
secret at publish time — the `kr4t0n/climage` used throughout this README is the
expected result, not a hardcoded value.

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
│   └── entrypoint.sh          # workspace checks, optional init hook, exec
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
