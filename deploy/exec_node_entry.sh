#!/bin/sh
# Exec Node 启动包装脚本

set -e

TLS_FINGERPRINT="${OPENCLAW_GATEWAY_TLS_FINGERPRINT:-}"
STOP_REQUESTED=0

on_shutdown() {
  STOP_REQUESTED=1
  echo "[exec-node] 收到停止信号，准备退出 ..."
}

trap 'on_shutdown' INT TERM

wait_for_gateway() {
    echo "[exec-node] 等待 gateway https://openclaw-gateway:18789/healthz 可用 ..."
    while :; do
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            return 1
        fi
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

run_node_once() {
    if [ -n "$TLS_FINGERPRINT" ]; then
        if openclaw node run --host openclaw-gateway --port 18789 \
            --tls --tls-fingerprint "$TLS_FINGERPRINT" --display-name "exec_node"; then
            EXIT_CODE=0
        else
            EXIT_CODE=$?
        fi
    else
        if openclaw node run --host openclaw-gateway --port 18789 \
            --tls --display-name "exec_node"; then
            EXIT_CODE=0
        else
            EXIT_CODE=$?
        fi
    fi

    echo "[exec-node] node 进程已退出 (退出码=$EXIT_CODE)。"
    return "$EXIT_CODE"
}

while :; do
    if [ "$STOP_REQUESTED" -eq 1 ]; then
        break
    fi

    if ! wait_for_gateway; then
        break
    fi

    echo "[exec-node] 启动 node，与 gateway 建立连接 ..."
    if run_node_once; then
        EXIT_CODE=0
    else
        EXIT_CODE=$?
    fi

    if [ "$STOP_REQUESTED" -eq 1 ]; then
        break
    fi

    echo "[exec-node] 连接中断（退出码: $EXIT_CODE），2 秒后自动重连 ..."
    sleep 2
done

echo "[exec-node] 已停止。"
