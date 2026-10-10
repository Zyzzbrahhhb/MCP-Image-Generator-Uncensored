#!/bin/bash
# Image Gen MCP for macOS: double-click this file in Finder to choose the GPU and the model, then start the server.
# In braces, so bash reads all of it before it runs: an update can replace this file while it runs.
{
cd "$(dirname "$0")" || exit 1
# Docker's command-line tools, for when they are not on PATH yet.
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin:/Applications/Docker.app/Contents/Resources/bin"
IMAGEGEN_LAUNCH=command
export PATH IMAGEGEN_LAUNCH
bash ./setup.sh "$@"
status=$?
echo
printf 'Press Enter to close this window. '
read -r _ || true
exit $status
}
