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
| Runtimes | `node`, `npm`, `npx`, `pnpm`, `corepack`, `python3` (Debian), uv-managed CPython |
| Python toolchain | `uv`, `uvx`, `ruff` |
| Go toolchain | `go`, `gofmt` — off by default, in the [`full` and `full-argus`](#image-variants) variants |
| Rust toolchain | `rustc`, `cargo`, `rustup`, `clippy`, `rustfmt`, `cargo audit` — off by default, in the [`full` and `full-argus`](#image-variants) variants |
| Kubernetes | `kubectl`, with `kubectl kustomize` built in — off by default, in the [`full` and `full-argus`](#kubernetes) variants |
| Search & text | `rg` (ripgrep), `fd`, `bat`, `jq`, `tree`, `file`, `less`, `diff`, `patch`, `moreutils` |
| Media & documents | `ffmpeg`, `ffprobe`, `convert` (ImageMagick), `pdftotext` (poppler) |
| VCS & network | `git`, `git-lfs`, `gh`, `ssh`, `curl`, `wget`, `rsync`, `dig`, `ping`, `nc`, `socat` |
| Secrets & hooks | `gitleaks`, `pre-commit` |
| Linters | `hadolint` (Dockerfiles), `actionlint` (GitHub Actions workflows), `shellcheck` |
| Data | `sqlite3` |
| Build | `build-essential` (`gcc`, `make`), `pkg-config` |
| Shell & process | `bash`, `tmux`, `vim.tiny`, `htop`, `procps`, `tini` |
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
another version in its `packageManager` field gets that one: pnpm fetches it on
first use and runs it for that project only. Yarn is not included — the build removes the Yarn
Classic the official Node.js image ships, so a stray `yarn` cannot write a
second lockfile into a pnpm project. `corepack`, which comes with Node.js, is
present but not enabled: `corepack yarn` and `corepack pnpm` run the version a
project's `packageManager` field names, with no shims on `PATH`.

The default command adapts to how the container was started: a terminal gets an
interactive shell, piped stdin is run as a script, and a container with neither
(a Kubernetes pod, a detached container) parks so you can exec into it. Passing
your own command bypasses it entirely.

## Prerequisites

- Docker 24+ with BuildKit (Docker 29 tested)
- `docker buildx` for multi-architecture builds (bundled with Docker Desktop and
  recent Docker Engine)
- Outside the image only, since every climage variant ships them:
  [pre-commit](https://pre-commit.com) 3.2.0 or later and `hadolint` for the
  commit hooks, and `shellcheck` and `gitleaks` for `make lint` (optional). The
  hadolint hook runs whichever release is on `PATH`; CI lints with the one in
  [`HADOLINT_VERSION`](CONFIGURATION.md#build-arguments)

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
`make build GO_VERSION=1.26`. [CONFIGURATION.md](CONFIGURATION.md#build-arguments)
lists every build argument.

### Image variants

Four variants are published. `latest` is the one to use unless you need
something it does not have.

| Tag | Contents | Uncompressed | Compressed (registry) |
| --- | --- | --- | --- |
| `latest` | everything in the table above except the Go and Rust toolchains and `kubectl` | 2.2 GB | 811 MB |
| `slim` | no media or build-tool packages | 1.5 GB | 576 MB |
| `full` | `latest` plus the Go and Rust toolchains, `kubectl` and the headless-browser libraries | 3.1 GB | 1118 MB |
| `full-argus` | `full` plus first-party tooling (`argus-sidecar`) | 3.1 GB | 1123 MB |

Both columns are amd64: uncompressed is the total size of the image's files,
compressed is what Docker Hub reports for the pushed image. arm64 runs slightly
smaller in both.
The Go and Rust toolchains account for most of the difference between `full`
and `latest` (307 MB compressed, of which `kubectl` is 17 MB), so pull `latest`
unless you need them.

```bash
docker pull kr4t0n/climage:full
```

`latest`, `slim`, `full` and `full-argus` follow `main` and move with every
push. A release also publishes version tags — `0.4.0` and `0.4`, plus the
`-slim`, `-full` and `-full-argus` suffixed equivalents — and every build is
addressable by a short-SHA tag. Pin a version tag when you need the base image
to stay put.

Each variant is a set of build arguments, listed under
[Variants](CONFIGURATION.md#variants) with the matching `docker build` commands.

### Headless browsers

Both `full` variants ship the system libraries Chromium needs, so Playwright and
Puppeteer work as the unprivileged user with no `apt` and no root:

```bash
docker run --rm kr4t0n/climage:full bash -lc \
    'npm i playwright && npx playwright install chromium && node my-script.js'
```

Only the libraries are baked in, not a browser binary: `playwright install`
fetches the build that matches your client library into `~/.cache/ms-playwright`,
which a volume mounted at `/home/climage` will persist.

On `latest` or `slim` the same script fails when Chromium starts. Installing the
libraries at runtime needs root *and* an `apt-get update` first, because the
image ships no package index:

```bash
docker exec -u 0 <container> bash -lc 'apt-get update && apt-get install -y \
    --no-install-recommends libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
    libxcomposite1 libxdamage1'
```

### Kubernetes

Both `full` variants ship `kubectl`, with `kubectl kustomize` built in. It is
pinned to one Kubernetes minor (`KUBECTL_VERSION`, 1.35 at present), and kubectl
supports API servers one minor older or newer than itself, so check your
cluster's version before relying on it. The image carries no kubeconfig and no
credentials: kubectl reads `~/.kube/config` or `KUBECONFIG` as usual, and a
volume mounted at `/home/climage` persists both the config and kubectl's cache.

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

[CONFIGURATION.md](CONFIGURATION.md) lists every build argument, runtime
environment variable and publishing credential. The ones most people touch:

- `INSTALL_*` build arguments choose what goes into an image (the variants are
  combinations of them), and the `*_VERSION` arguments pin each tool.
- `CLIMAGE_INIT` names a script the entrypoint sources before your command, for
  per-container bootstrap.
- `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`, in `.env`, let `make push`
  publish; CI reads them from GitHub secrets.

Both agent CLIs can replace themselves with a newer release than the image
pins. The image turns off every update that starts without being asked for:
Claude Code's with `DISABLE_AUTOUPDATER=1`, Codex's startup prompt and
background daemon in `/etc/codex/config.toml`. `claude update` and
`codex update`, run by hand, still work.
[Agent CLI updates](CONFIGURATION.md#agent-cli-updates) sets out both CLIs the
same way: what updates, how it is off, what is still open, how to turn it back
on, and how to check.

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
├── README.md                  # this overview
├── CONFIGURATION.md           # build args, runtime env vars, agent CLI updates
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

Enable the commit hooks once per clone. Every climage variant ships pre-commit;
outside the image it is a [prerequisite](#prerequisites).

```bash
pre-commit install
```

The hooks scan staged changes for secrets with gitleaks, lint the Dockerfile
with the hadolint on `PATH`, and lint the scripts with shellcheck through
Docker. In a container with no Docker daemon, skip shellcheck with
`SKIP=shellcheck`; CI runs both linters on every pull request, and repeats the
secret scan over the whole history. Inside the image the linters need no
Docker: `make lint` runs the image's own copies (`slim` has no `make`, so run
its three commands directly), and the image's hadolint, which the hook runs
too, is the release CI uses.
A finding that is not a secret is allowlisted in `.gitleaks.toml` or
`.gitleaksignore` and reviewed like any other change.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).
Adding a tool means updating three places: the `Dockerfile` package list, the
`REQUIRED` array in `tests/smoke.sh`, and the [What's inside](#whats-inside)
table. A tool that brings a build argument (a version pin or an `INSTALL_*`
flag) also gets a row in [CONFIGURATION.md](CONFIGURATION.md#build-arguments).
[AGENTS.md](AGENTS.md) holds the design decisions and gotchas to read before
changing the `Dockerfile` or CI.
