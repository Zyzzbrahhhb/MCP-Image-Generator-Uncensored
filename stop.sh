#!/usr/bin/env bash
# Stop Image Gen MCP (either profile).
cd "$(dirname "$0")"
if docker compose --profile gpu --profile cpu down; then
  if [ "${IMAGEGEN_LAUNCH:-}" = command ]; then start=start.command; else start=./start.sh; fi
  echo "The server is stopped. Run $start to start it again."
else
  echo "The server could not be stopped. Is Docker running?" >&2
  exit 1
fi
