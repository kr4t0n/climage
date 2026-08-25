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
  npm, and a pre-existing unprivileged `node` user at uid/gid 1000.
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
| `.github/workflows/ci.yml` | lint → build & test → publish. |

## Key design decisions

**Slim base, explicit package list.** `node:22-bookworm-slim` plus a curated apt
list, rather than the full `node:22` image. The full image bundles tooling we
would have to audit anyway, and the explicit list doubles as documentation of
what the image promises.

**Versions as build args, not literals.** Every upstream version is an `ARG` with
a default. Variant builds (`--build-arg NODE_VERSION=20`) require no Dockerfile
edit, and there is exactly one place to bump.

**Binary copy over installer scripts.** `COPY --from` on a pinned image tag is
reproducible and auditable; piping a remote script into a shell is neither.

**Interpreters and uv tools live in `/opt/uv`, not `$HOME`.** Home directories
get mounted over in real deployments. `/opt/uv` is `chown`ed to `node` so the
unprivileged user can still run `uv tool install` at runtime.

**Runtime-writable global npm prefix.** `NPM_CONFIG_PREFIX=/home/node/.npm-global`
is on `PATH` ahead of `/usr/local/bin`, so an agent can `npm install -g` more
tooling without root.

**`tini` as PID 1.** Agent sessions spawn long chains of subprocesses. Without an
init, orphaned children accumulate as zombies and signals do not propagate.

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

**Host uid mismatch on bind mounts.** The image runs as uid 1000. On a host
where the user is not 1000, files written into a mounted `/workspace` land with
the wrong owner. The entrypoint warns rather than `chown`ing — silently
rewriting ownership of someone's source tree is worse than the warning.

**PR builds are amd64-only.** Multi-arch happens only in the publish job, where
arm64 is emulated through QEMU and is several times slower. An arm64-specific
break therefore surfaces at publish time, not on the PR.

**Image size is a real constraint.** `build-essential`, `ffmpeg`, and
`imagemagick` dominate the footprint. The CI build reports the size on every
run; treat a step change as a regression to explain.

## Technical debt / planned improvements

- No vulnerability scanning. A Trivy or Grype job on the built image is the
  obvious next CI step.
- No published multi-arch smoke test — arm64 is built but never executed.
- The `org.opencontainers.image.source` label still carries an `OWNER`
  placeholder; it must be set once the GitHub remote exists.
- Docker Hub's repository description is not synced from `README.md`.
- A `-slim` variant without `build-essential`/media tooling would suit agents
  that only need search and VCS.
