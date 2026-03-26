#!/usr/bin/env bash
# ABOUTME: Container startup script — configures workspace and launches code-server.
# ABOUTME: Handles MCP config template substitution and skill injection at startup.

set -euo pipefail

exec /usr/bin/entrypoint.sh "$@"
