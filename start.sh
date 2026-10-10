#!/usr/bin/env bash
# Start Image Gen MCP. Until the first install has finished, it runs the setup first (see setup.sh); without a terminal
# it uses config.example.yaml instead. Then it builds the image if needed, starts the server and waits until the
# model is loaded. The steps are in scripts/lib.sh.
#   --build    build (or, with IMAGE_REPO set, pull) the image again even if it exists
#   --restart  restart a running server without asking
set -euo pipefail
cd "$(dirname "$0")"
LAUNCHER=${LAUNCHER:-$( [ "${IMAGEGEN_LAUNCH:-}" = command ] && echo start.command || echo ./start.sh )}
. ./scripts/lib.sh

main() {
  local build=0 mode=ask
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --build) build=1 ;;
      --restart) mode=restart ;;
      *) echo "Unknown option: $1 (use --build or --restart)" >&2; exit 2 ;;
    esac
    shift
  done
  echo "Image Gen MCP"
  check_docker
  if [ -f config.yaml ] && interactive && ! installed; then
    # The first install did not finish (no image yet): the steps again, with the saved answers as defaults.
    echo
    echo "==> The first install did not finish, so the setup runs again."
    run_setup
    mode=restart
  elif [ -f config.yaml ]; then
    detect
    show_settings
  elif interactive; then
    run_setup
    mode=restart
  else
    cp config.example.yaml config.yaml
    echo "==> created config.yaml from config.example.yaml (run $(launcher setup) to choose the GPU and the model)"
  fi
  start_server "$mode" "$build"
}
# One line, so bash has read all of it before it runs: an update can replace this file while it runs.
main "$@"; exit
