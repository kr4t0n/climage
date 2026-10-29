#!/usr/bin/env bash
# Smoke test: assert every tool the image promises is present and executable.
# Run inside the image:  docker run --rm -v "$PWD/tests:/t:ro" IMAGE bash /t/smoke.sh
set -uo pipefail

# "<command> <version args>" — whatever exits 0 cheaply; split on spaces.
REQUIRED=(
    "node --version"
    "npm --version"
    "npx --version"
    "pnpm --version"
    "corepack --version"
    "python --version"
    "python3 --version"
    "uv --version"
    "uvx --version"
    "ruff --version"
    "pre-commit --version"
    "rg --version"
    "fd --version"
    "bat --version"
    "jq --version"
    "tree --version"
    "file --version"
    "git --version"
    "git-lfs --version"
    "gh --version"
    "gitleaks version"
    "hadolint --version"
    "actionlint --version"
    "curl --version"
    "wget --version"
    "rsync --version"
    "ssh -V"
    "sqlite3 --version"
    "unzip -v"
    "zip --version"
    "xz --version"
    "shellcheck --version"
    "tmux -V"
    "htop --version"
)

OPTIONAL=()

# The image records which optional groups it was built with. Require exactly
# those, so a slim build passes and a default build that lost a tool fails.
if [[ -r /etc/climage-build.env ]]; then
    # shellcheck source=/dev/null
    source /etc/climage-build.env
fi

add_group() { # add_group <enabled> <cmd+flag>...
    local enabled=$1; shift
    if [[ "${enabled}" == "true" ]]; then REQUIRED+=("$@"); else OPTIONAL+=("$@"); fi
}
add_group "${INSTALL_MEDIA:-true}" "ffmpeg -version" "ffprobe -version" \
    "convert --version" "pdftotext -v"
add_group "${INSTALL_BUILD_TOOLS:-true}" "make --version" "gcc --version"
add_group "${INSTALL_CLAUDE_CODE:-true}" "claude --version"
add_group "${INSTALL_CODEX:-true}" "codex --version"
add_group "${INSTALL_SKILLS:-true}" "skills --version"
add_group "${INSTALL_ARGUS:-false}" "argus-sidecar version"
add_group "${INSTALL_GO:-false}" "go version" "gofmt -h"
add_group "${INSTALL_RUST:-false}" "rustc --version" "cargo --version" \
    "rustfmt --version" "clippy-driver --version" "cargo-audit --version"
# --client keeps kubectl from looking for a cluster, which no smoke run may reach.
add_group "${INSTALL_KUBECTL:-false}" "kubectl version --client"
# Helm 3's `version` is client-only.
add_group "${INSTALL_HELM:-false}" "helm version --short" "helmfile --version"

# The browser group installs shared libraries, not commands, so it is checked
# against the linker cache rather than PATH. These are the names Chromium fails
# to start without; a missing one surfaces as an opaque exit code from
# Playwright, so asserting them here is what makes that failure legible.
BROWSER_LIBS=(
    libatk-1.0.so.0
    libatk-bridge-2.0.so.0
    libatspi.so.0
    libXcomposite.so.1
    libXdamage.so.1
    libnss3.so
    libgbm.so.1
    libasound.so.2
)

failed=0
for entry in "${REQUIRED[@]}"; do
    read -r -a argv <<<"${entry}"
    cmd=${argv[0]}
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        printf 'FAIL  %-14s not found on PATH\n' "${cmd}"
        failed=$((failed + 1))
        continue
    fi
    version=$("${argv[@]}" 2>&1 | head -n 1)
    printf 'ok    %-14s %s\n' "${cmd}" "${version}"
done

for entry in "${OPTIONAL[@]}"; do
    read -r -a argv <<<"${entry}"
    cmd=${argv[0]}
    if command -v "${cmd}" >/dev/null 2>&1; then
        printf 'ok    %-14s %s\n' "${cmd}" "$("${argv[@]}" 2>&1 | head -n 1)"
    else
        printf 'skip  %-14s not installed (optional)\n' "${cmd}"
    fi
done

# `python3` must be the uv-managed interpreter, not Debian's system Python.
resolved=$(readlink -f "$(command -v python3)" 2>/dev/null || true)
if [[ "${resolved}" == /opt/uv/python/* ]]; then
    printf 'ok    %-14s %s\n' "python3 link" "${resolved}"
else
    printf 'FAIL  %-14s resolves to %s, expected /opt/uv/python/*\n' "python3 link" "${resolved:-<none>}"
    failed=$((failed + 1))
fi

# uv must be able to resolve the preinstalled interpreter without a network.
if uv python find >/dev/null 2>&1; then
    printf 'ok    %-14s %s\n' "uv python" "$(uv python find)"
else
    printf 'FAIL  %-14s no managed interpreter found\n' "uv python"
    failed=$((failed + 1))
fi

# `uv tool install` must work unprivileged: its bin dir has to be writable and
# on PATH. (Checked without a network round-trip.)
tool_bin="${UV_TOOL_BIN_DIR:-/home/climage/.uv/bin}"
if [[ -w "${tool_bin}" && ":${PATH}:" == *":${tool_bin}:"* ]]; then
    printf 'ok    %-14s writable and on PATH\n' "uv tool bin"
else
    printf 'FAIL  %-14s %s must be writable and on PATH\n' "uv tool bin" "${tool_bin}"
    failed=$((failed + 1))
fi

# uv tools must land under $HOME, so a volume mounted there carries runtime
# `uv tool install`s across restarts. Moving them back out is a silent
# regression for every long-lived deployment.
if [[ "${UV_TOOL_DIR:-}" == "${HOME}/"* && "${tool_bin}" == "${HOME}/"* ]]; then
    printf 'ok    %-14s under %s, survives a home volume\n' "uv tool dir" "${HOME}"
else
    printf 'FAIL  %-14s %s must live under %s\n' "uv tool dir" "${UV_TOOL_DIR:-<unset>}" "${HOME}"
    failed=$((failed + 1))
fi

# pre-commit is baked into /opt/uv/bin rather than the uv tool dir under $HOME,
# so a volume mounted over the home directory cannot hide it.
precommit_path=$(command -v pre-commit 2>/dev/null || true)
if [[ "${precommit_path}" == /opt/uv/bin/pre-commit ]]; then
    printf 'ok    %-14s %s, outside %s\n' "pre-commit dir" "${precommit_path}" "${HOME}"
else
    printf 'FAIL  %-14s resolves to %s, expected /opt/uv/bin/pre-commit\n' \
        "pre-commit dir" "${precommit_path:-<none>}"
    failed=$((failed + 1))
fi

# The build records the linter pins. Each binary must report exactly its pin:
# hadolint's is the release CI's hadolint-action runs, so a local lint and CI
# judge a Dockerfile by the same rules.
check_pin() { # check_pin <cmd> <pin> <reported version>
    local cmd=$1 pin=$2 reported=$3
    if [[ -n "${pin}" && "${reported}" == "${pin}" ]]; then
        printf 'ok    %-14s %s, as pinned\n' "${cmd} pin" "${reported}"
    else
        printf 'FAIL  %-14s reports %s, expected %s\n' "${cmd} pin" \
            "${reported:-<nothing>}" "${pin:-<unrecorded>}"
        failed=$((failed + 1))
    fi
}
check_pin hadolint "${HADOLINT_VERSION:-}" \
    "$(hadolint --version 2>/dev/null | awk 'NR == 1 { print $NF }')"
check_pin actionlint "${ACTIONLINT_VERSION:-}" \
    "$(actionlint --version 2>/dev/null | awk 'NR == 1')"
# kubectl's pin follows a cluster's minor, so a wrong patch is worth catching
# too. It reports "Client Version: v1.35.9"; the pin has no "v".
if [[ "${INSTALL_KUBECTL:-false}" == "true" ]]; then
    check_pin kubectl "${KUBECTL_VERSION:-}" \
        "$(kubectl version --client 2>/dev/null | awk 'NR == 1 { sub(/^v/, "", $NF); print $NF }')"
fi
# helm reports "v3.21.4" and helmfile "helmfile version 1.8.2". `helm plugin
# list` reads only plugin.yaml, so `helm diff version` is asked as well: it runs
# the plugin's binary, which helm finds through HELM_PLUGINS.
if [[ "${INSTALL_HELM:-false}" == "true" ]]; then
    check_pin helm "${HELM_VERSION:-}" \
        "$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//')"
    check_pin "diff plugin" "${HELM_DIFF_VERSION:-}" \
        "$(helm plugin list 2>/dev/null | awk '$1 == "diff" { print $2 }')"
    check_pin "helm diff" "${HELM_DIFF_VERSION:-}" "$(helm diff version 2>/dev/null)"
    check_pin helmfile "${HELMFILE_VERSION:-}" \
        "$(helmfile --version 2>/dev/null | awk 'NR == 1 { print $NF }')"

    # The plugin directory must stay outside $HOME, where a volume mounted over
    # the home directory would hide helm-diff.
    if [[ -n "${HELM_PLUGINS:-}" && "${HELM_PLUGINS}" != "${HOME}"/* \
        && -r "${HELM_PLUGINS}/diff/plugin.yaml" ]]; then
        printf 'ok    %-14s %s, outside %s\n' "helm plugins" "${HELM_PLUGINS}" "${HOME}"
    else
        printf 'FAIL  %-14s HELM_PLUGINS is %s, expected diff/ in a directory outside %s\n' \
            "helm plugins" "${HELM_PLUGINS:-<unset>}" "${HOME}"
        failed=$((failed + 1))
    fi
fi

# actionlint shellchecks `run:` blocks only when it finds shellcheck on PATH,
# and skips them silently when it does not. An unquoted variable in a step has
# to come back as SC2086. The `$HOME` is for actionlint to find, not this shell.
# shellcheck disable=SC2016
workflow='on: push
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - run: echo $HOME
'
report=$(printf '%s' "${workflow}" | actionlint -no-color - 2>&1 || true)
if [[ "${report}" == *SC2086* ]]; then
    printf 'ok    %-14s shellchecks run: blocks\n' "actionlint"
else
    printf 'FAIL  %-14s did not shellcheck a run: block\n' "actionlint"
    failed=$((failed + 1))
fi

# Yarn Classic arrives with the node base image and the build removes it: a
# stray `yarn` in a pnpm project writes a second lockfile. A base image that
# moves it somewhere the removal does not reach fails here.
if command -v yarn >/dev/null 2>&1 || command -v yarnpkg >/dev/null 2>&1; then
    printf 'FAIL  %-14s %s is on PATH, expected no yarn\n' "yarn" \
        "$(command -v yarn || command -v yarnpkg)"
    failed=$((failed + 1))
else
    printf 'ok    %-14s absent (corepack yarn for projects that need it)\n' "yarn"
fi

# Go and Rust repeat the uv split: the toolchain sits outside $HOME so a mounted
# home cannot hide it, while what `go install` / `cargo install` produce must
# land under $HOME to survive a restart. Assert the second half, so moving
# either directory back out fails here instead of silently discarding an
# agent's installs on the next pod restart.
check_runtime_bindir() { # check_runtime_bindir <label> <dir>
    local label=$1 dir=$2
    if [[ -n "${dir}" && "${dir}" == "${HOME}/"* && -w "${dir}" \
        && ":${PATH}:" == *":${dir}:"* ]]; then
        printf 'ok    %-14s %s, writable and on PATH\n' "${label}" "${dir}"
    else
        printf 'FAIL  %-14s %s must be under %s, writable and on PATH\n' \
            "${label}" "${dir:-<unset>}" "${HOME}"
        failed=$((failed + 1))
    fi
}

check_runtime_bindir "pnpm bin" "${PNPM_HOME:+${PNPM_HOME}/bin}"
# pnpm decides its global bin dir itself — it moved from $PNPM_HOME to
# $PNPM_HOME/bin in pnpm 11 — so ask it, rather than trusting the PATH entry.
pnpm_global_bin=$(pnpm bin -g 2>/dev/null || true)
if [[ -n "${PNPM_HOME:-}" && "${pnpm_global_bin}" == "${PNPM_HOME}/bin" ]]; then
    printf 'ok    %-14s pnpm bin -g matches PATH\n' "pnpm global"
else
    printf 'FAIL  %-14s pnpm bin -g is %s, expected %s\n' "pnpm global" \
        "${pnpm_global_bin:-<none>}" "${PNPM_HOME:-<unset>}/bin"
    failed=$((failed + 1))
fi

if [[ "${INSTALL_GO:-false}" == "true" ]]; then
    check_runtime_bindir "go bin" "${GOBIN:-}"
fi
if [[ "${INSTALL_RUST:-false}" == "true" ]]; then
    check_runtime_bindir "cargo bin" "${CARGO_INSTALL_ROOT:+${CARGO_INSTALL_ROOT}/bin}"
fi

# A login shell must keep the extra tool directories on PATH — /etc/profile
# rewrites PATH from scratch, so this needs an explicit profile drop-in.
if bash -lc 'command -v uv && command -v claude' >/dev/null 2>&1 \
    || bash -lc "[[ \":\$PATH:\" == *\":${tool_bin}:\"* ]]"; then
    printf 'ok    %-14s tool dirs survive /etc/profile\n' "login PATH"
else
    printf 'FAIL  %-14s login shell drops %s from PATH\n' "login PATH" "${tool_bin}"
    failed=$((failed + 1))
fi

# SHELL must be exported, not merely visible: this script runs under bash, which
# assigns SHELL itself when it is unset, so "${SHELL}" here would always pass.
# printenv is a separate process and sees only the exported environment.
shell_env=$(printenv SHELL || true)
if [[ "${shell_env}" == "/bin/bash" ]]; then
    printf 'ok    %-14s exported as %s\n' "SHELL" "${shell_env}"
else
    printf 'FAIL  %-14s exported as %s, expected /bin/bash\n' "SHELL" "${shell_env:-<unset>}"
    failed=$((failed + 1))
fi

# Without this, Claude Code's self-update installs into the home volume and
# shadows the pinned CLI from then on. Only "1" disables it; "0" and "" do not.
autoupdater_env=$(printenv DISABLE_AUTOUPDATER || true)
if [[ "${autoupdater_env}" == "1" ]]; then
    printf 'ok    %-14s exported as %s\n' "autoupdater" "DISABLE_AUTOUPDATER=1"
else
    printf 'FAIL  %-14s DISABLE_AUTOUPDATER is %s, expected 1\n' "autoupdater" "${autoupdater_env:-<unset>}"
    failed=$((failed + 1))
fi

# Asks Codex for the effective value rather than grepping /etc/codex/config.toml,
# so a Codex release that stops reading the system layer fails here.
if [[ "${INSTALL_CODEX:-true}" == "true" ]]; then
    daemon_flag=$(codex features list 2>/dev/null | awk '$1 == "daemon_auto_start" { print $NF }')
    if [[ "${daemon_flag}" == "false" ]]; then
        printf 'ok    %-14s daemon_auto_start=false\n' "codex daemon"
    else
        printf 'FAIL  %-14s daemon_auto_start is %s, expected false\n' "codex daemon" "${daemon_flag:-<missing>}"
        failed=$((failed + 1))
    fi

    # Same reason, for the startup update prompt. `codex doctor` exits non-zero
    # when it finds no login, which a smoke run never has, so only its report is
    # read, in the machine-readable form rather than the terminal layout.
    startup_check=$(codex doctor --json 2>/dev/null \
        | jq -r '.checks["updates.status"].details["check for update on startup"] // empty')
    if [[ "${startup_check}" == "false" ]]; then
        printf 'ok    %-14s check_for_update_on_startup=false\n' "codex prompt"
    else
        printf 'FAIL  %-14s check_for_update_on_startup is %s, expected false\n' "codex prompt" "${startup_check:-<missing>}"
        failed=$((failed + 1))
    fi
fi

# node and Claude Code's Bun runtime each link a static Brotli of their own, so
# Debian's patched libbrotli1 does not cover them. Brotli 1.2.1 fixed
# CVE-2026-111497, a decoder out-of-bounds write on CISA's KEV list, and added
# the error code named here, so a binary without the name has an older decoder:
# node 24.21.0 and Claude Code 2.1.296 (Bun 1.4.3) lack it.
brotli_bins=("node")
if [[ "${INSTALL_CLAUDE_CODE:-true}" == "true" ]]; then brotli_bins+=("claude"); fi
for cmd in "${brotli_bins[@]}"; do
    bin=$(readlink -f "$(command -v "${cmd}")" 2>/dev/null || true)
    if [[ -n "${bin}" ]] && grep -aq '_ERROR_FORMAT_BLOCK_SWITCH' "${bin}"; then
        printf 'ok    %-14s %s has Brotli >= 1.2.1\n' "brotli ${cmd}" "${bin}"
    else
        printf 'FAIL  %-14s %s has a Brotli older than 1.2.1 (CVE-2026-111497)\n' "brotli ${cmd}" "${bin:-<none>}"
        failed=$((failed + 1))
    fi
done

# The runtime identity is part of the image's contract: uid 1000 keeps
# bind-mounted host files sanely owned, and $HOME must match the account.
# the shared `users` gid (100) is what lets an arbitrary-uid run keep group access.
whoami_actual=$(id -un)
if [[ "${whoami_actual}" == "climage" && "$(id -u)" == "1000" \
    && "$(id -g)" == "100" && "$(id -gn)" == "users" && "${HOME}" == "/home/climage" ]]; then
    printf 'ok    %-14s %s (uid %s, gid %s/%s), HOME=%s\n' \
        "identity" "${whoami_actual}" "$(id -u)" "$(id -g)" "$(id -gn)" "${HOME}"
else
    printf 'FAIL  %-14s got %s (uid %s, gid %s/%s) HOME=%s, expected climage/1000/100/users//home/climage\n' \
        "identity" "${whoami_actual}" "$(id -u)" "$(id -g)" "$(id -gn)" "${HOME}"
    failed=$((failed + 1))
fi

# Nothing may be left group-owned by the retired gid 1000: those files would
# carry a group that no longer exists in the image, and would silently match an
# unrelated host group of the same gid through a bind mount.
orphan=$(find /opt/uv "${HOME}" /workspace -gid 1000 -print -quit 2>/dev/null)
if [[ -z "${orphan}" ]]; then
    printf 'ok    %-14s no files left on the retired gid 1000\n' "group cleanup"
else
    printf 'FAIL  %-14s %s (and possibly others) still owned by gid 1000\n' "group cleanup" "${orphan}"
    failed=$((failed + 1))
fi

# The workspace must be writable by the unprivileged runtime user.
if touch /workspace/.climage-smoke 2>/dev/null; then
    rm -f /workspace/.climage-smoke
    printf 'ok    %-14s writable by uid %s\n' "/workspace" "$(id -u)"
else
    printf 'FAIL  %-14s not writable by uid %s\n' "/workspace" "$(id -u)"
    failed=$((failed + 1))
fi

# The default command has to keep a headless container alive: a bare `bash`
# exits on EOF, which an orchestrator reads as a crash loop. It must still run
# whatever is piped in, so scripted `docker run -i` usage keeps working.
if ! command -v climage-idle >/dev/null 2>&1; then
    printf 'FAIL  %-14s not found on PATH\n' "climage-idle"
    failed=$((failed + 1))
else
    rc=0
    timeout 2 climage-idle </dev/null >/dev/null 2>&1 || rc=$?
    if [[ ${rc} -eq 124 ]]; then
        printf 'ok    %-14s parks when stdin is empty\n' "climage-idle"
    else
        printf 'FAIL  %-14s exited (%s) with no stdin; a pod would crash-loop\n' \
            "climage-idle" "${rc}"
        failed=$((failed + 1))
    fi

    rc=0
    printf 'exit 7\n' | timeout 10 climage-idle >/dev/null 2>&1 || rc=$?
    if [[ ${rc} -eq 7 ]]; then
        printf 'ok    %-14s runs piped stdin as a script\n' "climage-idle"
    else
        printf 'FAIL  %-14s piped script returned %s, expected 7\n' "climage-idle" "${rc}"
        failed=$((failed + 1))
    fi
fi

# A version string proves nothing about whether a toolchain can produce a
# binary. Rust in particular shells out to `cc` to link, so an image built with
# INSTALL_RUST=true and INSTALL_BUILD_TOOLS=false compiles nothing at all while
# every --version check above still passes.
if [[ "${INSTALL_GO:-false}" == "true" ]]; then
    tmp=$(mktemp -d)
    printf 'package main\n\nfunc main() { println("ok") }\n' > "${tmp}/main.go"
    if (cd "${tmp}" && go mod init smoke && go build -o smoke .) >/dev/null 2>&1 \
        && "${tmp}/smoke" >/dev/null 2>&1; then
        printf 'ok    %-14s builds and runs a binary\n' "go build"
    else
        printf 'FAIL  %-14s could not build a hello-world binary\n' "go build"
        failed=$((failed + 1))
    fi
    rm -rf "${tmp}"
fi

if [[ "${INSTALL_RUST:-false}" == "true" ]]; then
    tmp=$(mktemp -d)
    printf 'fn main() { println!("ok"); }\n' > "${tmp}/hello.rs"
    if rustc "${tmp}/hello.rs" -o "${tmp}/hello" >/dev/null 2>&1 \
        && "${tmp}/hello" >/dev/null 2>&1; then
        printf 'ok    %-14s compiles and links a binary\n' "rustc"
    else
        printf 'FAIL  %-14s could not link a binary; is a C compiler present?\n' "rustc"
        failed=$((failed + 1))
    fi
    rm -rf "${tmp}"

    # Agents type `cargo audit`, not `cargo-audit`: cargo has to find the
    # binary as an external subcommand, which is what this exercises.
    if cargo audit --version >/dev/null 2>&1; then
        printf 'ok    %-14s runs as a cargo subcommand\n' "cargo audit"
    else
        printf 'FAIL  %-14s cargo cannot dispatch to cargo-audit\n' "cargo audit"
        failed=$((failed + 1))
    fi
fi

# helmfile proves itself by driving helm: it renders the chart `helm create`
# writes, from a local path and with --skip-deps, so nothing reaches a chart
# repository. `helm template` renders on the client and never asks a cluster.
if [[ "${INSTALL_HELM:-false}" == "true" ]]; then
    tmp=$(mktemp -d)
    printf 'releases:\n  - name: smoke\n    chart: ./smoke\n' > "${tmp}/helmfile.yaml"
    if rendered=$(cd "${tmp}" && helm create smoke >/dev/null \
            && helmfile template --skip-deps 2>/dev/null) \
        && [[ "${rendered}" == *"kind: Deployment"* ]]; then
        printf 'ok    %-14s renders a chart through helm\n' "helmfile"
    else
        printf 'FAIL  %-14s could not render a chart through helm\n' "helmfile"
        failed=$((failed + 1))
    fi
    rm -rf "${tmp}"
fi

if [[ "${INSTALL_BROWSER:-false}" == "true" ]]; then
    missing=()
    for lib in "${BROWSER_LIBS[@]}"; do
        ldconfig -p | grep -q "${lib}" || missing+=("${lib}")
    done
    if (( ${#missing[@]} == 0 )); then
        printf 'ok    %-14s %d chromium libs present\n' "browser libs" "${#BROWSER_LIBS[@]}"
    else
        printf 'FAIL  %-14s missing: %s\n' "browser libs" "${missing[*]}"
        failed=$((failed + 1))
    fi
else
    printf 'skip  %-14s not installed (INSTALL_BROWSER=false)\n' "browser libs"
fi

if (( failed > 0 )); then
    echo "smoke: ${failed} check(s) failed" >&2
    exit 1
fi
echo "smoke: all checks passed"
