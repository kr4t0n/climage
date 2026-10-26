# Configuration

Everything about climage that can be set: build arguments when you build an
image, environment variables when you run one, how the image handles the agent
CLIs' self-updates, and the credentials that publishing reads. Defaults are the
values in the `Dockerfile`; credentials are listed by name only.

## Build arguments

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
| `CLAUDE_CODE_VERSION` | `2.1.296` | Exact Claude Code version (npm `latest`) |
| `INSTALL_CODEX` | `true` | Set `false` to omit the Codex CLI |
| `CODEX_VERSION` | `0.162.1` | Exact Codex CLI version (npm `latest`) |
| `INSTALL_SKILLS` | `true` | Set `false` to omit the `skills` CLI |
| `INSTALL_MEDIA` | `true` | ffmpeg, ImageMagick, poppler — ~409 MB with dependencies |
| `INSTALL_BUILD_TOOLS` | `true` | `build-essential`, `pkg-config` — ~231 MB |
| `INSTALL_GO` | `false` | Go toolchain, copied from the official `golang` image; on in both `full` variants. Must be exactly `true` or `false` |
| `GO_VERSION` | `1.27` | Go minor version (official image tag) |
| `INSTALL_RUST` | `false` | Rust toolchain, copied from the official `rust` image; on in both `full` variants. Requires `INSTALL_BUILD_TOOLS=true` for a working linker. Must be exactly `true` or `false` |
| `RUST_VERSION` | `1.98` | Rust version (official image tag) |
| `CARGO_AUDIT_VERSION` | `0.22.2` | Exact [cargo-audit](https://github.com/rustsec/rustsec/tree/main/cargo-audit) release, installed only with `INSTALL_RUST=true` |
| `CARGO_AUDIT_SHA256_AMD64`, `CARGO_AUDIT_SHA256_ARM64` | release digests | SHA-256 of each architecture's cargo-audit tarball; upstream publishes no checksum list, so the pins live here |
| `INSTALL_KUBECTL` | `false` | `kubectl`, the Kubernetes client, from the Kubernetes release; on in both `full` variants |
| `KUBECTL_VERSION` | `1.35.9` | Exact kubectl release, verified against the SHA-256 published beside it. Follows the minor of the cluster the `full` variants run on, since kubectl supports one minor of skew either way |
| `INSTALL_HELM` | `false` | `helm`, the helm-diff plugin and `helmfile`, from their releases; on in both `full` variants |
| `HELM_VERSION` | `3.21.4` | Exact Helm release, verified against the SHA-256 published beside it. Stays on Helm 3, where `helm diff upgrade` renders on the client by default; see [Helm plugins](#helm-plugins) |
| `HELM_DIFF_VERSION` | `3.15.15` | Exact [helm-diff](https://github.com/databus23/helm-diff) release, verified against its checksum list and unpacked into `HELM_PLUGINS` |
| `HELMFILE_VERSION` | `1.8.2` | Exact [helmfile](https://github.com/helmfile/helmfile) release, verified against its checksum list |
| `INSTALL_ARGUS` | `false` | Bundle `argus-sidecar`; on only in the `full-argus` variant |
| `INSTALL_BROWSER` | `false` | Headless-Chromium system libraries; on in both `full` variants — ~18 MB, since the media group already provides most of the chain |
| `ARGUS_VERSION` | `0.3.6` | Exact [argus](https://github.com/kr4t0n/argus) release, without the `argus-sidecar-v` tag prefix |
| `SKILLS_VERSION` | `1.7.0` | Exact [skills](https://github.com/vercel-labs/skills) version |
| `PNPM_VERSION` | `12.10.1` | Exact [pnpm](https://pnpm.io) version (npm `latest`); a project's `packageManager` field still selects its own |
| `PRE_COMMIT_VERSION` | `4.6.2` | Exact [pre-commit](https://pre-commit.com) version, installed as a uv tool under `/opt/uv` |
| `GITLEAKS_VERSION` | `8.30.1` | Exact [gitleaks](https://github.com/gitleaks/gitleaks) release, verified against its checksum list; the same version CI scans with |
| `HADOLINT_VERSION` | `2.15.1` | Exact [hadolint](https://github.com/hadolint/hadolint) release, verified against its checksum list; the same version CI lints with |
| `ACTIONLINT_VERSION` | `1.7.12` | Exact [actionlint](https://github.com/rhysd/actionlint) release, verified against its checksum list |
| `VERSION`, `REVISION`, `CREATED` | `dev`/`unknown` | OCI labels, populated by CI |

### Variants

Each published variant is a set of `INSTALL_*` arguments; every other argument
keeps its default.

| Variant | Tag | Build arguments |
| --- | --- | --- |
| `base` | `latest` | none |
| `slim` | `slim` | `INSTALL_MEDIA=false`, `INSTALL_BUILD_TOOLS=false` |
| `full` | `full` | `INSTALL_BROWSER=true`, `INSTALL_GO=true`, `INSTALL_RUST=true`, `INSTALL_KUBECTL=true`, `INSTALL_HELM=true` |
| `full-argus` | `full-argus` | `full`'s five, plus `INSTALL_ARGUS=true` |

`make build VARIANT=<variant>` passes them for you. With Docker directly:

```bash
docker build --build-arg INSTALL_BROWSER=true --build-arg INSTALL_GO=true \
    --build-arg INSTALL_RUST=true --build-arg INSTALL_KUBECTL=true \
    --build-arg INSTALL_HELM=true -t climage:full .
docker build --build-arg INSTALL_MEDIA=false --build-arg INSTALL_BUILD_TOOLS=false -t climage:slim .
```

## Runtime environment variables

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
| `HELM_PLUGINS` | `/usr/local/lib/helm/plugins` | Where helm finds plugins: helm-diff in both `full` variants. Root-owned and outside `$HOME`; see [Helm plugins](#helm-plugins) |
| `LANG` | `en_US.UTF-8` | Locale is generated in the image |
| `SHELL` | `/bin/bash` | Shell that agents and tools spawn; without it they fall back to `/bin/sh` (dash) |
| `DISABLE_AUTOUPDATER` | `1` | Turns off Claude Code's self-update; see [Agent CLI updates](#agent-cli-updates) |

### Helm plugins

Both `full` variants unpack helm-diff into `/usr/local/lib/helm/plugins`, the
directory `HELM_PLUGINS` names. It is root-owned, so the pinned plugin is the
one that runs: `helm plugin install` there fails with `permission denied`, and
`helm plugin update diff` fails because the plugin was unpacked from its
release rather than cloned. helm's other state (repositories, the registry
login, the chart cache) stays at its defaults under `$HOME`.

To add a plugin, install it into a directory under `$HOME`, then list both
directories, separated by a colon, for helm to load:

```bash
HELM_PLUGINS="$HOME/.local/share/helm/plugins" helm plugin install <plugin URL>
export HELM_PLUGINS="/usr/local/lib/helm/plugins:$HOME/.local/share/helm/plugins"
```

Helm 3 loads plugins from every directory in the list but installs into
`HELM_PLUGINS` as a single path: with the list set, `helm plugin install` writes
into a directory named after the whole list, where helm never looks. A home
volume keeps the second directory.

Helm stays on the 3.x line on purpose. Under Helm 4, `helm diff upgrade` without
a `--dry-run` flag renders the chart with `--dry-run=server`, so its `lookup`
calls read live objects from the cluster, Secrets included. Under Helm 3 it
renders on the client, where `lookup` returns nothing. Pass
`--three-way-merge-mode client` for a three-way merge that only reads.

## Agent CLI updates

Claude Code and Codex can each replace themselves with a newer release than the
image pins. Run as the `climage` user, an update lands under `$HOME`: on a home
volume it outlives the container, and it keeps shadowing the pinned copy in
every later image. The image turns off every update that starts without being
asked for, and leaves the update commands a person runs by hand.

| | Claude Code | Codex |
| --- | --- | --- |
| **What updates it** | Its background self-update, which runs `npm install -g` into `~/.npm-global`, ahead of `/usr/local/bin` on `PATH` | Its startup prompt: every interactive launch offers *Update now*, pre-selected, which runs `npm install -g @openai/codex` into `~/.npm-global`. And its background daemon: interactive `codex` starts it, running a copy of Codex in `~/.codex/packages/app-server-daemon/` that a companion updater replaces from upstream's `install.sh` within minutes, then hourly, while `codex --version` still reports the pin |
| **How the image turns it off** | `DISABLE_AUTOUPDATER=1`, an `ENV` in the image. Only `1` disables it; `0` or an empty value leaves it on | Two keys in `/etc/codex/config.toml`, Codex's system config layer, written when `INSTALL_CODEX=true`: `check_for_update_on_startup = false` at the top level, and `daemon_auto_start = false` under `[features]` |
| **Still open** | `claude update`, run by hand, installs into `~/.npm-global` the same way. Only `DISABLE_UPDATES=1` blocks it, and the image does not set it | `codex update`, run by hand, installs into `~/.npm-global` the same way. `codex agents`, `codex app-server daemon start` and `codex remote-control` still start the daemon, updater included |
| **Turn it back on** | Per container: `-e DISABLE_AUTOUPDATER=0`. Per command: `DISABLE_AUTOUPDATER=0 claude` | Per user, in `~/.codex/config.toml`, which overrides `/etc/codex/config.toml`: `check_for_update_on_startup = true` at the top, `daemon_auto_start = true` under `[features]`. Per command: `codex -c check_for_update_on_startup=true`, `codex -c features.daemon_auto_start=true` |
| **Check the effective value** | `printenv DISABLE_AUTOUPDATER` prints `1`; `claude doctor` reports whether auto-update is on | `codex doctor` reports the `startup update check` as `false`; `codex features list` reports `daemon_auto_start` as `false` |
| **Remove a copy already on the volume** | `which -a claude` lists it; `npm uninstall -g @anthropic-ai/claude-code` removes it | `which -a codex` lists an npm copy; `npm uninstall -g @openai/codex` removes it. For a daemon copy, kill the updater by the PID in `~/.codex/app-server-daemon/daemon-updater.pid`, then delete `~/.codex/packages/app-server-daemon/` |

The smoke test asserts all three off switches: `DISABLE_AUTOUPDATER` exported
as `1`, and Codex's effective `check_for_update_on_startup` and
`daemon_auto_start`, as `codex doctor` and `codex features list` report them.

## Publishing credentials

| Name | Where | Purpose |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | GitHub secret / `.env` | Docker Hub namespace and login |
| `DOCKERHUB_TOKEN` | GitHub secret / `.env` | Docker Hub access token, Read & Write scope |
| `IMAGE_NAME` | GitHub repo variable / `.env` (optional) | Image name; defaults to `climage` |
| `IMAGE_TAG` | `.env` (optional) | Tag for images the `Makefile` builds and pushes; defaults to `dev` |
