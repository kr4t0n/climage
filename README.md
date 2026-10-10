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
| Runtimes | `node`, `npm`, `npx`, `pnpm`, `python3` (Debian), uv-managed CPython |
| Python toolchain | `uv`, `uvx`, `ruff` |
| Go toolchain | `go`, `gofmt` — off by default, in the [`full` and `full-argus`](#image-variants) variants |
| Rust toolchain | `rustc`, `cargo`, `rustup`, `clippy`, `rustfmt` — off by default, in the [`full` and `full-argus`](#image-variants) variants |
| Search & text | `rg` (ripgrep), `fd`, `bat`, `jq`, `tree`, `file`, `less`, `diff`, `patch`, `moreutils` |
| Media & documents | `ffmpeg`, `ffprobe`, `convert` (ImageMagick), `pdftotext` (poppler) |
| VCS & network | `git`, `git-lfs`, `gh`, `ssh`, `curl`, `wget`, `rsync`, `dig`, `ping`, `nc`, `socat` |
| Secrets & hooks | `gitleaks`, `pre-commit` |
| Data | `sqlite3` |
| Build | `build-essential` (`gcc`, `make`), `pkg-config` |
| Shell & process | `bash`, `tmux`, `vim.tiny`, `htop`, `procps`, `shellcheck`, `tini` |
| Archives | `unzip`, `zip`, `xz`, `bzip2`, `tar`, `gzip` |
| Agent CLIs | `claude` (Claude Code), `codex` (OpenAI Codex), `skills` (open agent-skills manager) — all optional, on by default |
| First-party | `argus-sidecar` — off by default, only in the [`full-argus`](#image-variants) variant |

`python` and `python3` resolve to the uv-managed CPython (3.12 by default), not
Debian's system interpreter — the pinned version is what runs, whichever name an
agent types.

Runs as the unprivileged `climage` user (uid 1000, in the stock `users` group,
gid 100 — there is no per-user group) with `/workspace` as the
working directory. `tini` is PID 1 so long-lived agent sessions reap their children. The
image is designed to be extended at runtime without root: `uv tool install`,
`npm install -g` and `pnpm add -g` all work as the `climage` user, in interactive
and login shells, and all write under `$HOME` — so a volume mounted at
`/home/climage` carries whatever an agent installs across restarts.

`pnpm` is pinned like everything else, but a project whose `package.json` names
a version in its `packageManager` field gets that version: pnpm fetches it on
first use and runs it for that project only.

The default command adapts to how the container was started: a terminal gets an
interactive shell, piped stdin is run as a script, and a container with neither
(a Kubernetes pod, a detached container) parks so you can exec into it. Passing
your own command bypasses it entirely.

## Prerequisites

- Docker 24+ with BuildKit (Docker 29 tested)
- `docker buildx` for multi-architecture builds (bundled with Docker Desktop and
  recent Docker Engine)
- Optional, for local linting: `hadolint`, `shellcheck`, `gitleaks`

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
make lint         # hadolint + shellcheck + gitleaks
make size         # report the image size
make push         # multi-arch build + push to Docker Hub (CI normally does this)
make help         # list all targets
```

Every target takes `VARIANT`, which mirrors the CI matrix and defaults to
`base`. Each variant builds to its own tag (`climage:dev`, `climage:dev-slim`,
`climage:dev-full`, `climage:dev-full-argus`), so one does not overwrite another:

```bash
make test VARIANT=full    # build the full variant and smoke-test it
make size VARIANT=slim
make test-all             # build and smoke-test all four, as CI does
```

Version pins come from the `Dockerfile` unless you override one explicitly:
`make build GO_VERSION=1.26`.

### Image variants

Four variants are published. `latest` is the one to use unless you need
something it does not have.

| Tag | Contents | Uncompressed | Compressed (registry) |
| --- | --- | --- | --- |
| `latest` | everything in the table above except the Go and Rust toolchains | 2.1 GB | 780 MB |
| `slim` | no media or build-tool packages | 1.5 GB | 545 MB |
| `full` | `latest` plus the Go and Rust toolchains and the headless-browser libraries | 2.9 GB | 1064 MB |
| `full-argus` | `full` plus first-party tooling (`argus-sidecar`) | 2.9 GB | 1069 MB |

Both columns are amd64: uncompressed as the CI size step measures it, compressed
as Docker Hub reports the pushed image. arm64 runs slightly smaller in both.
The Go and Rust toolchains account for nearly all of the 0.8 GB (284 MB
compressed) separating `full` from `latest`, so pull `latest` unless you need
them.

```bash
docker pull kr4t0n/climage:full
```

`latest`, `slim`, `full` and `full-argus` follow `main` and move with every
push. A release also publishes version tags — `0.4.0` and `0.4`, plus the
`-slim`, `-full` and `-full-argus` suffixed equivalents — and every build is
addressable by a short-SHA tag. Pin a version tag when you need the base image
to stay put.

Build any of them locally with `make build VARIANT=slim|full|full-argus`, or
with the matching build args directly:

```bash
docker build --build-arg INSTALL_BROWSER=true \
    --build-arg INSTALL_GO=true --build-arg INSTALL_RUST=true -t climage:full .
docker build --build-arg INSTALL_MEDIA=false --build-arg INSTALL_BUILD_TOOLS=false -t climage:slim .
```

`full-argus` is the `full` command plus `--build-arg INSTALL_ARGUS=true`.

### Headless browsers

Both `full` variants ship the system libraries Chromium needs, so Playwright and
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
| `USERNAME` | `climage` | Runtime account name; the base image's `node` user is renamed to it, keeping uid 1000 |
| `USERGROUP` | `users` | Primary group (gid 100). A shared group, not a per-user one, so an arbitrary-uid run (`--user 5000:100`) keeps group access |
| `DEBIAN_SUITE` | `bookworm` | Debian suite of the base image |
| `PYTHON_VERSION` | `3.12` | CPython version installed via `uv python install` |
| `UV_VERSION` | `0.12.13` | `uv`/`uvx` release copied from Astral's image |
| `RUFF_VERSION` | `0.16.7` | `ruff` release copied from Astral's image |
| `INSTALL_CLAUDE_CODE` | `true` | Set `false` to omit the Claude Code CLI |
| `CLAUDE_CODE_VERSION` | `2.1.295` | Exact Claude Code version (npm `latest`) |
| `INSTALL_CODEX` | `true` | Set `false` to omit the Codex CLI |
| `CODEX_VERSION` | `0.162.0` | Exact Codex CLI version (npm `latest`) |
| `INSTALL_SKILLS` | `true` | Set `false` to omit the `skills` CLI |
| `INSTALL_MEDIA` | `true` | ffmpeg, ImageMagick, poppler — ~409 MB with dependencies |
| `INSTALL_BUILD_TOOLS` | `true` | `build-essential`, `pkg-config` — ~231 MB |
| `INSTALL_GO` | `false` | Go toolchain, copied from the official `golang` image; on in both `full` variants. Must be exactly `true` or `false` |
| `GO_VERSION` | `1.27` | Go minor version (official image tag) |
| `INSTALL_RUST` | `false` | Rust toolchain, copied from the official `rust` image; on in both `full` variants. Requires `INSTALL_BUILD_TOOLS=true` for a working linker. Must be exactly `true` or `false` |
| `RUST_VERSION` | `1.98` | Rust version (official image tag) |
| `INSTALL_ARGUS` | `false` | Bundle `argus-sidecar`; on only in the `full-argus` variant |
| `INSTALL_BROWSER` | `false` | Headless-Chromium system libraries; on in both `full` variants — ~18 MB, since the media group already provides most of the chain |
| `ARGUS_VERSION` | `0.3.6` | Exact [argus](https://github.com/kr4t0n/argus) release, without the `argus-sidecar-v` tag prefix |
| `SKILLS_VERSION` | `1.7.0` | Exact [skills](https://github.com/vercel-labs/skills) version |
| `PNPM_VERSION` | `12.10.1` | Exact [pnpm](https://pnpm.io) version (npm `latest`); a project's `packageManager` field still selects its own |
| `PRE_COMMIT_VERSION` | `4.6.2` | Exact [pre-commit](https://pre-commit.com) version, installed as a uv tool under `/opt/uv` |
| `GITLEAKS_VERSION` | `8.30.1` | Exact [gitleaks](https://github.com/gitleaks/gitleaks) release, verified against its checksum list; the same version CI scans with |
| `VERSION`, `REVISION`, `CREATED` | `dev`/`unknown` | OCI labels, populated by CI |

### Runtime environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLIMAGE_INIT` | unset | Path to a script the entrypoint sources before the command — use it for per-container bootstrap |
| `UV_CACHE_DIR` | `/home/climage/.cache/uv` | Mount a volume here to persist Python downloads |
| `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` | `/home/climage/.uv/tools`, `/home/climage/.uv/bin` | Where `uv tool install` puts tools and their entry points — under `$HOME`, so a home volume persists them |
| `NPM_CONFIG_PREFIX` | `/home/climage/.npm-global` | Lets the unprivileged user `npm install -g` at runtime |
| `PNPM_HOME` | `/home/climage/.local/share/pnpm` | Where `pnpm add -g` installs; its `bin/` subdirectory is on `PATH`, which pnpm 11 and later require. The store (`~/.local/share/pnpm/store`) sits alongside, so a home volume keeps both |
| `GOPATH` / `GOBIN` | `/home/climage/.go`, `/home/climage/.go/bin` | Where `go install` puts binaries, and the root of all Go state — under `$HOME`, so a home volume persists it |
| `GOCACHE` / `GOENV` | `/home/climage/.go/cache`, `/home/climage/.go/env` | Moved off their `~/.cache` and `~/.config` defaults so everything Go writes lives in `~/.go`. `GOMODCACHE` follows `GOPATH` to `~/.go/pkg/mod` |
| `CARGO_INSTALL_ROOT` | `/home/climage/.cargo` | Where `cargo install` puts binaries, for the same reason. The toolchain itself stays in `/opt/rust` |
| `LANG` | `en_US.UTF-8` | Locale is generated in the image |
| `SHELL` | `/bin/bash` | Shell that agents and tools spawn; without it they fall back to `/bin/sh` (dash) |
| `DISABLE_AUTOUPDATER` | `1` | Stops Claude Code from updating itself, so the image's pinned version is the one that runs. Set `0` to re-enable; updates then land in `~/.npm-global` and take precedence over the image's copy |

Codex's equivalent is a config file rather than a variable. The image ships
`/etc/codex/config.toml` with `daemon_auto_start = false`, which stops
interactive `codex` from starting its background server — a copy of Codex on
the home volume that updates itself hourly. Turn it back on per user with
`[features]` / `daemon_auto_start = true` in `~/.codex/config.toml`, which takes
precedence; `codex features list` shows the effective value.

### Publishing credentials

| Name | Where | Purpose |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | GitHub secret / `.env` | Docker Hub namespace and login |
| `DOCKERHUB_TOKEN` | GitHub secret / `.env` | Docker Hub access token, Read & Write scope |
| `IMAGE_NAME` | GitHub repo variable / `.env` (optional) | Image name; defaults to `climage` |
| `IMAGE_TAG` | `.env` (optional) | Tag for images the `Makefile` builds and pushes; defaults to `dev` |

## CI and publishing

`.github/workflows/ci.yml` runs on every pull request to `main`, every push to
`main`, and every `v*` tag:

1. **Lint and secret scan** — hadolint and shellcheck, and gitleaks over the
   full git history.
2. **Build and smoke test** — all four variants, each on a native amd64 and a
   native arm64 runner, with the image size reported.
3. **Publish** — pushes to `main` and `v*` tags only. Each build is pushed to
   Docker Hub by digest, then assembled into the multi-arch tags described under
   [Image variants](#image-variants).

A pull request builds and tests exactly what merging it would publish.

## Project structure

```
.
├── Dockerfile                 # the image definition (single source of truth)
├── AGENTS.md                  # design decisions, conventions and gotchas
├── CLAUDE.md                  # points Claude Code at AGENTS.md
├── .dockerignore              # keeps the build context to scripts/ only
├── .hadolint.yaml             # Dockerfile lint rules
├── Makefile                   # build / test / run / push helpers
├── .env.example               # template for local publishing credentials
├── .pre-commit-config.yaml    # gitleaks + hadolint + shellcheck + hygiene hooks
├── scripts/
│   ├── entrypoint.sh          # workspace checks, optional init hook, exec
│   └── climage-idle.sh        # the default CMD: shell, script, or park
├── tests/
│   └── smoke.sh               # tool inventory assertions, run inside the image
└── .github/
    ├── dependabot.yml         # weekly base-image and action bumps
    └── workflows/ci.yml       # lint & secret scan -> build & test -> publish
```

## Contributing

```bash
uv tool install pre-commit   # or: pipx install pre-commit
pre-commit install
```

The hooks scan staged changes for secrets with gitleaks, lint the Dockerfile
with hadolint (through Docker) and the scripts with shellcheck. CI repeats the
secret scan over the whole history. A finding that is not a secret is
allowlisted in `.gitleaks.toml` or `.gitleaksignore` and reviewed like any
other change.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).
Adding a tool means updating three places: the `Dockerfile` package list, the
`REQUIRED` array in `tests/smoke.sh`, and the table in this README.
