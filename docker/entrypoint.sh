#!/usr/bin/env bash
# ABOUTME: Container startup script — configures workspace and launches code-server.
# ABOUTME: Copies MCP config to Cline's settings path at startup.

set -euo pipefail

MCP_CONFIG_SRC="/root/config/mcp.json"
MCP_CONFIG_DIR="/root/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev/settings"
MCP_CONFIG_DST="${MCP_CONFIG_DIR}/cline_mcp_settings.json"

# Copy MCP config to Cline's settings path
if [[ -f "${MCP_CONFIG_SRC}" ]]; then
  mkdir -p "${MCP_CONFIG_DIR}"
  cp "${MCP_CONFIG_SRC}" "${MCP_CONFIG_DST}"
  echo "MCP config written to ${MCP_CONFIG_DST}"
fi

exec /usr/bin/entrypoint.sh "$@"
