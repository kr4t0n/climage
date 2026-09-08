#!/usr/bin/env bash
# Smoke test: assert every tool the image promises is present and executable.
# Run inside the image:  docker run --rm -v "$PWD/tests:/t:ro" IMAGE bash /t/smoke.sh
set -uo pipefail

# "<command> <version-flag>" — the flag is whatever exits 0 cheaply.
REQUIRED=(
    "node --version"
    "npm --version"
    "npx --version"
    "python --version"
    "python3 --version"
    "uv --version"
    "uvx --version"
    "ruff --version"
    "rg --version"
    "fd --version"
    "bat --version"
    "jq --version"
    "tree --version"
    "file --version"
    "git --version"
    "git-lfs --version"
    "gh --version"
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

failed=0
for entry in "${REQUIRED[@]}"; do
    read -r cmd flag <<<"${entry}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        printf 'FAIL  %-14s not found on PATH\n' "${cmd}"
        failed=$((failed + 1))
        continue
    fi
    version=$("${cmd}" "${flag}" 2>&1 | head -n 1)
    printf 'ok    %-14s %s\n' "${cmd}" "${version}"
done

for entry in "${OPTIONAL[@]}"; do
    read -r cmd flag <<<"${entry}"
    if command -v "${cmd}" >/dev/null 2>&1; then
        printf 'ok    %-14s %s\n' "${cmd}" "$("${cmd}" "${flag}" 2>&1 | head -n 1)"
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
tool_bin="${UV_TOOL_BIN_DIR:-/opt/uv/bin}"
if [[ -w "${tool_bin}" && ":${PATH}:" == *":${tool_bin}:"* ]]; then
    printf 'ok    %-14s writable and on PATH\n' "uv tool bin"
else
    printf 'FAIL  %-14s %s must be writable and on PATH\n' "uv tool bin" "${tool_bin}"
    failed=$((failed + 1))
fi

# A login shell must keep the extra tool directories on PATH — /etc/profile
# rewrites PATH from scratch, so this needs an explicit profile drop-in.
if bash -lc 'command -v uv && command -v claude' >/dev/null 2>&1 \
    || bash -lc '[[ ":$PATH:" == *":/opt/uv/bin:"* ]]'; then
    printf 'ok    %-14s tool dirs survive /etc/profile\n' "login PATH"
else
    printf 'FAIL  %-14s login shell drops /opt/uv/bin from PATH\n' "login PATH"
    failed=$((failed + 1))
fi

# The runtime identity is part of the image's contract: uid 1000 keeps
# bind-mounted host files sanely owned, and $HOME must match the account.
whoami_actual=$(id -un)
if [[ "${whoami_actual}" == "climage" && "$(id -u)" == "1000" && "${HOME}" == "/home/climage" ]]; then
    printf 'ok    %-14s %s (uid %s), HOME=%s\n' "identity" "${whoami_actual}" "$(id -u)" "${HOME}"
else
    printf 'FAIL  %-14s got %s (uid %s) HOME=%s, expected climage/1000//home/climage\n' \
        "identity" "${whoami_actual}" "$(id -u)" "${HOME}"
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

if (( failed > 0 )); then
    echo "smoke: ${failed} check(s) failed" >&2
    exit 1
fi
echo "smoke: all checks passed"
