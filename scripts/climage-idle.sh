#!/usr/bin/env bash
# The image's default command (CMD), installed as /usr/local/bin/climage-idle.
#
# climage is an environment, not a service, so "the default thing to do" depends
# entirely on how the container was started:
#
#   docker run -it climage           stdin is a terminal -> interactive shell
#   echo 'ruff check .' | \
#     docker run -i climage          stdin is a pipe     -> run it as a script
#   kubectl / docker run (detached)  stdin is /dev/null  -> park forever
#
# The last case is the reason this script exists. A bare `bash` reads EOF
# immediately and exits 0, which an orchestrator reads as a container that
# refuses to stay up — CrashLoopBackOff on Kubernetes. Parking here keeps the
# keep-alive concern inside the image, so deployment manifests can use the
# image's default command as-is instead of overriding it with `sleep infinity`.
#
# Parking is cheap and signal-clean: `sleep` is exec'd, so it inherits this PID
# and tini (PID 1) can deliver SIGTERM straight to it on shutdown.
set -euo pipefail

# An interactive terminal: hand the user a shell, the historical default.
if [[ -t 0 ]]; then
    exec bash
fi

# A pipe or a redirected file: bash reads it as a script.
if [[ -p /dev/stdin || -s /dev/stdin ]]; then
    exec bash
fi

# Nothing on stdin (an orchestrator started us): stay up to be exec'd into.
exec sleep infinity
