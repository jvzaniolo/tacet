#!/bin/bash
# Builds Tacet and installs it to /Applications, quitting the running copy
# first (its quit turns hidden apps back on). Same options as build-app.sh,
# e.g. `BETA=1 scripts/install.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."
INSTALL=1 exec ./scripts/build-app.sh "$@"
