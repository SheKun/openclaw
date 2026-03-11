#!/bin/sh
# Gateway 启动包装脚本
# 在后台启动 openclaw gateway，等端口就绪后立即在容器内卸载 /tmp/secret_file.json，
# 然后 wait 保持容器与 gateway 进程同生命周期。
# 注：宿主机的 secret_file.json 文件不受影响，容器重启后挂载点会自动恢复。

set -e

echo "[start-gateway] 启动 openclaw gateway ..."
node dist/index.js gateway & GATEWAY_PID=$!

# 等待 gateway 监听端口就绪（最多 30 秒）
echo "[start-gateway] 等待 gateway 端口 18789 就绪 ..."
for i in $(seq 1 30); do
  if nc -z 127.0.0.1 18789 2>/dev/null; then
    echo "[start-gateway] gateway 已就绪（${i}s）"
    break
  fi
  sleep 1
done

# 在容器内卸载 secret_file.json（不影响宿主机文件，容器重启后自动恢复）
if umount /tmp/secret_file.json 2>/dev/null; then
  echo "[start-gateway] /tmp/secret_file.json 已在容器内卸载"
else
  echo "[start-gateway] 警告: umount /tmp/secret_file.json 失败（可能未挂载或权限不足）"
fi

# 删除飞书APP的环境变量
# unset FEISHU_APP_ID_STEWARD
# unset FEISHU_APP_SECRET_STEWARD
# unset FEISHU_APP_ID_CODER
# unset FEISHU_APP_SECRET_CODER
# unset FEISHU_APP_ID_CRAWLER
# unset FEISHU_APP_SECRET_CRAWLER

# 跟随 gateway 进程，保持容器存活
wait $GATEWAY_PID
