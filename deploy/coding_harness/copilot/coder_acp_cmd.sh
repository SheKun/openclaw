#!/bin/sh

set -eu

SOCKET_ID_FILE="${CODER_COPILOT_SOCKET_ID_FILE:-/tmp/coder-copilot-acp.socket-id}"
STATUS_FILE="${CODER_COPILOT_PROXY_STATUS_FILE:-/tmp/coder-copilot-acp.status.json}"
SOCKET_ID="$(cat "$SOCKET_ID_FILE" 2>/dev/null || true)"

if [ -z "$SOCKET_ID" ]; then
     echo "[custom_acpx] 未找到 ACP socket id 文件: $SOCKET_ID_FILE" >&2
     exit 1
fi

if [ ! -f "$STATUS_FILE" ]; then
     echo "[custom_acpx] 未找到 ACP 代理状态文件: $STATUS_FILE" >&2
     exit 1
fi

if ! grep -q '"state":"ready"' "$STATUS_FILE"; then
     STATE_LINE="$(cat "$STATUS_FILE" 2>/dev/null || true)"
     echo "[custom_acpx] ACP upstream 未就绪: ${STATE_LINE:-unknown}" >&2
     exit 1
fi

exec node /usr/local/bin/acp-stdio-to-socket.js "$SOCKET_ID"
