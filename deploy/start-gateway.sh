#!/bin/sh
# Gateway 启动包装脚本
# 在后台启动 openclaw gateway，等端口就绪后立即在容器内卸载 /tmp/secret_file.json，
# 然后 wait 保持容器与 gateway 进程同生命周期。
# 注：宿主机的 secret_file.json 文件不受影响，容器重启后挂载点会自动恢复。

set -e

#阻止ubuntu清理deb文件缓存，方便后续快速安装
echo "[start-gateway] 尝试配置 apt 缓存 ..."
{
  # 移除 docker-clean 配置文件，因为它包含 Post-Invoke 钩子会强制删除 .deb 缓存
  [ -f /etc/apt/apt.conf.d/docker-clean ] && rm -f /etc/apt/apt.conf.d/docker-clean
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "1";' > /etc/apt/apt.conf.d/01keep-cache \
    && echo 'APT::Keep-Downloaded-Packages "1";' >> /etc/apt/apt.conf.d/01keep-cache
  echo "[start-gateway] apt 缓存配置成功。"
} || echo "[start-gateway] 跳过 apt 缓存配置 (可能由于权限不足)。"


#删除浏览器文件，防止浏览器无法启动
rm -rf /home/node/.openclaw/browser/openclaw > /dev/null 2>&1

# 加载 .env 中的环境变量（如果存在）
[ -f ./.env ] && set -a && . ./.env && set +a

ACP_PROXY_SOCKET="/tmp/coder-copilot-acp.sock"
ACP_PROXY_SOCKET_ID_FILE="/tmp/coder-copilot-acp.socket-id"
ACP_PROXY_STATUS_FILE="/tmp/coder-copilot-acp.status.json"
ACP_PROXY_LOG="/tmp/coder-copilot-acp-proxy.log"
ACP_PROXY_PID=""

# 自动建立 CDP 隧道到宿主机 (用于访问宿主机的浏览器)
echo "[start-gateway] 尝试建立 CDP 隧道至宿主机 ..."
TUNNEL_PID=""
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ExitOnForwardFailure=yes -o ConnectTimeout=8 \
    -N -L 9222:127.0.0.1:9222 cdp_tunnel &
then
  TUNNEL_PID=$!
  # 给 ssh 一点时间暴露连接/转发失败（例如主机不可达、端口不可用）
  sleep 1
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "[start-gateway] CDP 隧道已在后台运行 (PID: $TUNNEL_PID)。"
  else
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    echo "[start-gateway] 警告: CDP 隧道建立失败，将继续启动 gateway（不使用宿主机 CDP）。"
  fi
else
  echo "[start-gateway] 警告: 无法启动 CDP 隧道命令，将继续启动 gateway（不使用宿主机 CDP）。"
fi
echo "[start-gateway] 启动 coder-copilot ACP 长连接代理 ..."
rm -f "$ACP_PROXY_SOCKET" "$ACP_PROXY_SOCKET_ID_FILE" "$ACP_PROXY_STATUS_FILE"
node /usr/local/bin/acp-tcp-proxy.js "$ACP_PROXY_SOCKET" "$ACP_PROXY_SOCKET_ID_FILE" "$ACP_PROXY_STATUS_FILE" > "$ACP_PROXY_LOG" 2>&1 &
ACP_PROXY_PID=$!

for i in $(seq 1 20); do
  if [ -s "$ACP_PROXY_SOCKET_ID_FILE" ] && [ -f "$ACP_PROXY_STATUS_FILE" ] && grep -q '"state":"ready"' "$ACP_PROXY_STATUS_FILE"; then
    echo "[start-gateway] ACP 长连接代理已就绪（${i}s）"
    break
  fi
  if ! kill -0 "$ACP_PROXY_PID" 2>/dev/null; then
    echo "[start-gateway] 错误: ACP 长连接代理启动失败。" >&2
    tail -n 200 "$ACP_PROXY_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ ! -s "$ACP_PROXY_SOCKET_ID_FILE" ] || [ ! -f "$ACP_PROXY_STATUS_FILE" ] || ! grep -q '"state":"ready"' "$ACP_PROXY_STATUS_FILE"; then
  echo "[start-gateway] 错误: ACP 长连接代理未在预期时间内就绪。" >&2
  [ -f "$ACP_PROXY_STATUS_FILE" ] && cat "$ACP_PROXY_STATUS_FILE" >&2 || true
  tail -n 200 "$ACP_PROXY_LOG" >&2 || true
  exit 1
fi

export CODER_COPILOT_SOCKET_ID_FILE="$ACP_PROXY_SOCKET_ID_FILE"
export CODER_COPILOT_PROXY_STATUS_FILE="$ACP_PROXY_STATUS_FILE"

# 当容器退出时，确保清理后台代理与 CDP 隧道
trap '[ -n "$ACP_PROXY_PID" ] && kill "$ACP_PROXY_PID" 2>/dev/null || true; [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true' EXIT

# 自动安装并在配置中启用 /home/node/.openclaw/extensions 下的插件
echo "[start-gateway] 检查并自动安装扩展插件 ..."
EXTENSIONS_ROOT="/home/node/.openclaw/extensions"
if [ -d "$EXTENSIONS_ROOT" ]; then
  for ext_dir in "$EXTENSIONS_ROOT"/*; do
    if [ -d "$ext_dir" ]; then
      if [ ! -f "$ext_dir/package.json" ]; then
        echo "[start-gateway]   -> 跳过目录（未找到 package.json）: $(basename "$ext_dir")"
        continue
      fi

      ext_name=$(basename "$ext_dir")
      echo "[start-gateway]   -> 注册并启用插件: $ext_name ..."
      # 使用 openclaw.mjs 直接执行，确保在网关启动前完成配置
      node openclaw.mjs plugins install "$ext_dir" > /dev/null 2>&1 || true
      node openclaw.mjs plugins enable "$ext_name" > /dev/null 2>&1 || true
    fi
  done
fi

echo "同步所有agent的工作空间..."
for workspace_dir in /home/node/.openclaw/workspace-*; do
  if [ -d "$workspace_dir" ]; then
    if [ -d "$workspace_dir/.git" ]; then
      echo "[start-gateway]   -> 更新工作空间: $(basename "$workspace_dir") ..."
      (cd "$workspace_dir" && git pull) > /dev/null 2>&1 || echo "[start-gateway]   -> 警告: 更新失败: $(basename "$workspace_dir")"
    fi
  fi
done

echo "[start-gateway] 启动 openclaw gateway ..."
node openclaw.mjs gateway --allow-unconfigured & GATEWAY_PID=$!

# 等待 gateway 监听端口就绪（最多 30 秒）
echo "[start-gateway] 等待 gateway 端口 18789 就绪 ..."
for i in $(seq 1 30); do
  if nc -z 127.0.0.1 18789 2>/dev/null; then
    echo "[start-gateway] gateway 已就绪（${i}s）"
    break
  fi
  sleep 1
done

wait $GATEWAY_PID
