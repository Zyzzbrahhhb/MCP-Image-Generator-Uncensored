#!/usr/bin/env bash
# Image Gen MCP update: installs the latest version with git, then offers to start it. config.yaml, .env, the models
# and the images are kept. The steps are in scripts/lib.sh.
set -euo pipefail
cd "$(dirname "$0")"
LAUNCHER=${LAUNCHER:-$( [ "${IMAGEGEN_LAUNCH:-}" = command ] && echo update.command || echo ./update.sh )}
. ./scripts/lib.sh

main() {
  echo "Image Gen MCP update"
  run_update
}
# One line, so bash has read all of it before it runs: git replaces this file during the update.
main "$@"; exit
