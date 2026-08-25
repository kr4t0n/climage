#!/usr/bin/env bash
# Container entrypoint: normalise the workspace, then hand control to the command.
set -euo pipefail

# A bind-mounted /workspace arrives with the host's ownership. Only warn — the
# container runs unprivileged and must not attempt to chown someone's source.
if [[ -d /workspace && ! -w /workspace ]]; then
    echo "climage: /workspace is not writable by uid $(id -u)." >&2
    echo "climage: run with --user \"\$(id -u):\$(id -g)\" or chown the host directory." >&2
fi

# Optional per-container bootstrap, e.g. mounted at /workspace/.climage-init.sh.
if [[ -n "${CLIMAGE_INIT:-}" && -r "${CLIMAGE_INIT}" ]]; then
    # shellcheck source=/dev/null
    source "${CLIMAGE_INIT}"
fi

exec "$@"
