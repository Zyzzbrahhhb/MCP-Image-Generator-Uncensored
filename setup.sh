#!/usr/bin/env bash
# Image Gen MCP setup: asks where the server runs and which model it uses, saves the answers in config.yaml, then
# builds and starts the server. Run it again to change the settings: your current settings are the defaults.
# The steps are in scripts/lib.sh.
set -euo pipefail
cd "$(dirname "$0")"
LAUNCHER=${LAUNCHER:-$( [ "${IMAGEGEN_LAUNCH:-}" = command ] && echo setup.command || echo ./setup.sh )}
. ./scripts/lib.sh

main() {
  echo "Image Gen MCP setup"
  check_docker
  run_setup
  ext_setup
  start_server restart 0
  ext_start_all
}
# One line, so bash has read all of it before it runs: an update can replace this file while it runs.
main "$@"; exit
