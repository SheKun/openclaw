#!/bin/sh
# Exec Node 启动包装脚本

set -e

TLS_FINGERPRINT="${OPENCLAW_GATEWAY_TLS_FINGERPRINT:-}"

wait_for_gateway() {
    echo "[exec-node] 等待 gateway https://openclaw-gateway:18789/healthz 可用 ..."
    while :; do
        if node -e '
const https = require("node:https");
const hostname = process.argv[1];
const port = Number(process.argv[2]);
const req = https.request(
  { hostname, port, path: "/healthz", method: "GET", rejectUnauthorized: false },
  (res) => {
    res.resume();
    process.exit(typeof res.statusCode === "number" && res.statusCode < 500 ? 0 : 1);
  },
);
req.setTimeout(3000, () => {
  req.destroy();
  process.exit(1);
});
req.once("error", () => process.exit(1));
req.end();
' openclaw-gateway 18789; then
            echo "[exec-node] gateway 已可连接，继续启动 node。"
            return 0
        fi
        sleep 1
    done
}

wait_for_gateway

if [ -n "$TLS_FINGERPRINT" ]; then
    openclaw node run --host openclaw-gateway --port 18789 \
        --tls --tls-fingerprint "$TLS_FINGERPRINT" --display-name "exec_node"
else
    openclaw node run --host openclaw-gateway --port 18789 \
        --tls --display-name "exec_node"
fi
