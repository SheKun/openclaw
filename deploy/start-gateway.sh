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

# 自动建立 CDP 隧道到宿主机 (用于访问宿主机的浏览器)
# 假设宿主机的 CDP 专用账号为 cdp_tunnel
if [ -f ~/.ssh/host_cdp ]; then
  HOST_IP="172.17.0.1"
  if [ -n "$HOST_IP" ]; then
    echo "[start-gateway] 尝试建立 CDP 隧道至宿主机 ($HOST_IP) ..."
    # 使用 StrictHostKeyChecking=no 避免首次连接时的手动确认
    ssh -i ~/.ssh/host_cdp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -N -L 9222:127.0.0.1:9222 cdp_tunnel@"$HOST_IP" &
    TUNNEL_PID=$!
    echo "[start-gateway] CDP 隧道已在后台运行 (PID: $TUNNEL_PID)。"
    # 当容器退出时，确保清理隧道进程
    trap "kill $TUNNEL_PID 2>/dev/null || true" EXIT
  else
    echo "[start-gateway] 警告: 无法检测到宿主机 IP，跳过 CDP 隧道建立。"
  fi
fi

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
