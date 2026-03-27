#!/usr/bin/env bash
# ABOUTME: Container entrypoint — writes Continue config then launches supervisord.
# ABOUTME: supervisord manages both code-server and the LiteLLM proxy.

set -euo pipefail

CONTINUE_CONFIG_TEMPLATE="/root/config/continue-config.yaml"
CONTINUE_CONFIG_DST="/root/.continue/config.yaml"

# Write Continue config, substituting runtime env vars (e.g. SPLUNK_MCP_TOKEN)
if [[ -f "${CONTINUE_CONFIG_TEMPLATE}" ]]; then
  mkdir -p "$(dirname "${CONTINUE_CONFIG_DST}")"
  envsubst < "${CONTINUE_CONFIG_TEMPLATE}" > "${CONTINUE_CONFIG_DST}"
  echo "Continue config written to ${CONTINUE_CONFIG_DST}"
fi

exec supervisord -c /root/config/supervisord.conf
