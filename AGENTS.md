# AGENTS.md

Context for AI agents contributing to this repository. Read this before changing
the `Dockerfile` or the CI pipeline.

## What this project is

A single-artifact repository: it produces one container image, `climage`, that
serves as a base environment for CLI coding agents. There is no application
code, no runtime service, and no test framework beyond a shell smoke test. The
`Dockerfile` is the source of truth; everything else exists to lint it, test it,
document it, or ship it.

## Architecture

```
ghcr.io/astral-sh/uv:${UV_VERSION}      ─┐  (binary-only stages)
ghcr.io/astral-sh/ruff:${RUFF_VERSION}  ─┤
                                         ├─> node:${NODE_VERSION}-${DEBIAN_SUITE}-slim
apt layer (agent tooling)               ─┘        └─> USER node, WORKDIR /workspace
```

Three inputs converge on one final stage:

- **Base image** — the official Node.js slim image. It provides the JS runtime,
  npm, and a pre-existing unprivileged `node` user at uid/gid 1000, which the
  build renames to `climage`.
- **Astral binary stages** — `uv` and `ruff` are copied out of Astral's
  distribution images rather than installed with a `curl | sh` script. The
  binaries are static, the version is pinned by tag, and the layers cache
  independently of the apt layer.
- **apt layer** — Debian packages for search, media, documents, VCS, build, and
  shell tooling, plus the GitHub CLI from its own apt repository.

### Module responsibilities

| Path | Responsibility |
| --- | --- |
| `Dockerfile` | Image definition. All version pins live here as build args. |
| `scripts/entrypoint.sh` | Baked into the image. Warns on an unwritable workspace, sources an optional `CLIMAGE_INIT` hook, then `exec "$@"`. |
| `tests/smoke.sh` | **Not** baked in — bind-mounted at test time so the image stays free of test assets. Asserts the tool inventory. |
| `Makefile` | The local equivalent of the CI jobs. Keep the two in sync. |
| `.github/workflows/ci.yml` | lint → build & test → publish by digest → manifest. |

## Key design decisions

**Slim base, explicit package list.** `node:24-bookworm-slim` plus a curated apt
list, rather than the full `node:24` image. The full image bundles tooling we
would have to audit anyway, and the explicit list doubles as documentation of
what the image promises.

**Versions as build args, not literals.** Every upstream version is an `ARG` with
a default. Variant builds (`--build-arg NODE_VERSION=22`) require no Dockerfile
edit, and there is exactly one place to bump.

**Binary copy over installer scripts.** `COPY --from` on a pinned image tag is
reproducible and auditable; piping a remote script into a shell is neither.

**Interpreters and uv tools live in `/opt/uv`, not `$HOME`.** Home directories
get mounted over in real deployments. `/opt/uv` is `chown`ed to `node` so the
unprivileged user can still run `uv tool install` at runtime.

**Runtime-writable global npm prefix.** `NPM_CONFIG_PREFIX=/home/climage/.npm-global`
is on `PATH` ahead of `/usr/local/bin`, so an agent can `npm install -g` more
tooling without root.

**`tini` as PID 1.** Agent sessions spawn long chains of subprocesses. Without an
init, orphaned children accumulate as zombies and signals do not propagate.

**Optional groups are recorded, not guessed.** `INSTALL_MEDIA` and
`INSTALL_BUILD_TOOLS` (like the agent-CLI flags) are written to
`/etc/climage-build.env` at build time. `tests/smoke.sh` sources that file and
promotes each group to *required* when it was enabled — so a slim build passes
while a default build that silently lost ffmpeg still fails. Marking those tools
merely "optional" in the test would have hidden exactly the regression the test
exists to catch.

**Smoke test as the contract.** The image's promise is "these commands exist and
work". `tests/smoke.sh` encodes exactly that, and CI blocks a push if it breaks.

## Conventions

- **Adding a tool** touches three places: the `Dockerfile` package list, the
  `REQUIRED` array in `tests/smoke.sh`, and the tool table in `README.md`. A
  change that misses the smoke test is not covered by CI.
- **Optional tooling** (anything behind a build arg) goes in the `OPTIONAL`
  array in the smoke test, which reports `skip` instead of failing.
- Group apt packages by purpose and keep the grouping comment accurate.
- Conventional Commits; scope is usually `docker`, `ci`, or `docs`.
- Shell scripts are `bash` with `set -euo pipefail` and must pass `shellcheck`.

## Gotchas

**Debian renames two binaries.** `fd-find` installs as `fdfind` and `bat` as
`batcat`, to avoid clashing with unrelated packages. The Dockerfile symlinks both
into `/usr/local/bin`. Remove the symlinks and the smoke test fails, not the
build.

**`ARG` scope resets at every `FROM`.** Args declared before the first `FROM` are
global but are only visible inside a stage if re-declared there. The
`PYTHON_VERSION` / `INSTALL_CLAUDE_CODE` args are declared after the final
`FROM` for this reason.

**Dependabot does not follow `FROM image:${ARG}`.** The docker ecosystem updater
handles literal tags in `FROM`; it does not reliably rewrite an `ARG` default
consumed by an interpolated `FROM`. Treat the `UV_VERSION` and `RUFF_VERSION`
defaults as manually maintained — check Astral's releases when touching the
Python toolchain. The `node` base tag is likewise interpolated.

**ghcr's manifest API is slow.** `docker manifest inspect ghcr.io/astral-sh/...`
routinely takes 10-15s, so probing candidate tags under a short timeout reports
existing tags as missing and silently pins you to a stale version. Allow at
least 60s per probe, or read the version from PyPI (`pypi.org/pypi/ruff/json`),
which tracks the same releases and answers immediately.

**uv is on Docker Hub, ruff is not.** `astral/uv` is an official image, but the
only ruff images on Docker Hub are third-party rebuilds. Both stages therefore
pull from ghcr, deliberately — do not "fix" the inconsistency by pointing ruff
at an unofficial namespace.

**`.dockerignore` excludes everything by default.** It is an allowlist (`*` then
`!scripts`). A new file that must be `COPY`ed into the image needs an explicit
un-ignore line, or the build fails with "file not found".

**`/etc/profile` overwrites `PATH`.** Debian sets `PATH` from scratch for login
shells, so `bash -lc '...'` — a very common way for agents to run commands —
would lose `/opt/uv/bin` and the npm global prefix that the `ENV PATH` line
adds. `/etc/profile.d/10-climage-path.sh` puts them back. The smoke test asserts
this; do not delete the drop-in as redundant with `ENV PATH`.

**`uv tool` bin dir must be user-writable.** Pointing `UV_TOOL_BIN_DIR` at
`/usr/local/bin` looks tidy but breaks `uv tool install` for the unprivileged
user with `Permission denied`. It lives at `/opt/uv/bin`, chowned to `node` and
on `PATH`.

**`python3` is a symlink, not Debian's interpreter.** `/usr/local/bin/python3`
points into `/opt/uv/python/...` and wins over `/usr/bin/python3` on `PATH`.
System scripts keep working because their shebangs name `/usr/bin/python3`
explicitly. This is done with plain symlinks rather than `uv python install
--default`, which is still flagged experimental upstream.

**Both agent CLIs track npm `latest`, by choice.** `@anthropic-ai/claude-code`
publishes `stable`, `latest`, and `next`, where `latest` equals `next` and runs
ahead of `stable` — often by several weeks (2.1.236 vs 2.1.263 at the time of
writing). `@openai/codex` publishes no `stable` tag at all; its non-`latest`
tags are alpha/beta and platform-specific builds. Rather than have the two CLIs
follow different release trains, both pins follow `latest`. The trade-off is
deliberate: newer features, less soak time. Check `npm view <pkg> dist-tags`
before bumping, and if a Claude Code release ever regresses, `stable` is the
fallback channel to pin to.

**The runtime user is renamed, not created.** `groupmod`/`usermod` rename the
base image's `node` account to `climage` in place, so it keeps uid/gid 1000 —
the value that makes bind-mounted host files land with usable ownership for a
typical single-user Linux host. Adding a second account would have left uid 1000
occupied by `node` and pushed `climage` to 1001. Everything after that step
refers to `${USERNAME}`; a hardcoded `node` or `/home/node` is a bug. Note that
anything deriving from this image with `--user node` or a `/home/node` path
breaks — the smoke test asserts the identity so the contract is explicit.

**Agent state spans three top-level `$HOME` entries.** Claude Code uses
`~/.claude/` plus a sibling `~/.claude.json`; Codex uses `~/.codex/`; the
`skills` CLI adds `~/.agents/` (the canonical skill copies) and symlinks from
there into each agent's directory. Anything persisting agent state needs the
whole home, not one subdirectory — and because skills are symlinks into
`~/.agents`, persisting `~/.claude` alone yields dangling links.

**Size levers, measured.** The image is ~2.0 GB unpacked (`docker image
inspect` reports the *compressed* size, roughly a third of that — do not confuse
the two). The breakdown: agent CLIs ~612 MB of native binaries, ffmpeg's
dependency tree 364 MB, the build-essential chain 231 MB, the base image
~230 MB, uv's CPython 123 MB. Only the group flags move the needle; trimming
individual utilities does not. `python3-dev`/`python3-venv` were dropped as
redundant — `python3` resolves to uv's interpreter, so C extensions build
against uv's headers, not Debian's 3.11 ones.

**dpkg exclusions only affect later installs.** `/etc/dpkg/dpkg.cfg.d/01-climage-nodoc`
drops docs and manpages, so it must be written before the first `apt-get
install`; files already in the base image are unaffected. Copyright files are
explicitly re-included for licence compliance. Likewise `/usr/share/i18n` is
removed only *after* `locale-gen`, which compiles what it needs into
`/usr/lib/locale`.

**Host uid mismatch on bind mounts.** The image runs as uid 1000. On a host
where the user is not 1000, files written into a mounted `/workspace` land with
the wrong owner. The entrypoint warns rather than `chown`ing — silently
rewriting ownership of someone's source tree is worse than the warning.

**Never build arm64 under QEMU.** Emulating this image's apt layer costs tens of
minutes and burns runner time for no benefit. Both CI matrices pin each
architecture to a native runner (`ubuntu-latest` for amd64, `ubuntu-24.04-arm`
for arm64), and there is no `setup-qemu-action` in the workflow. If a third
architecture is ever added, give it a native runner or leave it out.

**Per-architecture cache scopes are mandatory.** The two native runners share
one GitHub Actions cache. Without `scope=${{ matrix.arch }}` on `cache-from` /
`cache-to`, each architecture overwrites the other's layers every run and both
lose their cache.

**`latest` is the full build; `slim` is a separate tag, not a suffix.** The
manifest job runs once per variant with its own tag rules. The slim variant sets
`flavor: latest=false` — without it, `latest=auto` would point bare `latest` at
the slim image on any release and clobber the full build. Deleting that line is
a silent, hard-to-notice regression.

**There is no `edge` tag, deliberately.** `edge` distinguishes "newest main
build" from "newest release" only when `latest` tracks releases exclusively.
This pipeline sets `latest` on `main` pushes as well, so `edge` was a duplicate
name for the same digest. Reintroducing it means first deciding whether `latest`
should stop following `main`.

**Publish pushes by digest, not by tag.** Each architecture pushes an untagged
image and uploads its digest as an artifact; the `manifest` job merges those
digests into the real tags. This is what allows two independent runners to
contribute to one multi-arch tag — do not "simplify" it into a single tagged
push, which would leave the last runner's tag overwriting the other's.

**Image size is a real constraint.** `build-essential`, `ffmpeg`, and
`imagemagick` dominate the footprint. The CI build reports the size on every
run; treat a step change as a regression to explain.

## Technical debt / planned improvements

- No vulnerability scanning. A Trivy or Grype job on the built image is the
  obvious next CI step.
- Docker Hub's repository description is not synced from `README.md`.
