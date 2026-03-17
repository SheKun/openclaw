#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 或 root 权限运行此脚本。"
  exit 1
fi

USERNAME="cdp_tunnel"
TARGET_PORT="9222"

echo "开始创建 CDP 专用隧道账号: $USERNAME ..."

# 1. 创建用户
# 注意：即使我们不希望他有 Shell 权限，但 SSH 建立隧道需要一个合法的 Shell 环境来维持会话。
# 真正的拦截将在 SSH 密钥层进行。
if id "$USERNAME" &>/dev/null; then
    echo "⚠️ 用户 $USERNAME 已存在，将覆盖其 SSH 密钥配置。"
else
    useradd -m -s /bin/bash $USERNAME
    # 锁定密码，使其完全无法通过密码登录
    passwd -l $USERNAME >/dev/null
fi

# 2. 初始化 .ssh 目录
USER_HOME=$(eval echo ~$USERNAME)
SSH_DIR="$USER_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# 3. 生成无密码的专属 ed25519 密钥对（适合容器自动化调用）
KEY_PATH="$SSH_DIR/host_cdp"
if [ -f "$KEY_PATH" ]; then
    rm -f "$KEY_PATH" "$KEY_PATH.pub"
fi
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q

# 4. 核心：在 authorized_keys 中注入“最小化权限”规则
PUB_KEY=$(cat "$KEY_PATH.pub")
# 规则解释：
# restrict: 禁用所有非必要权限（无 PTY，无 X11 等）
# port-forwarding: 允许端口转发
# permitopen: 严格限制只能转发到宿主机的 127.0.0.1:9222
# command: 强行劫持会话，只执行 read 等待，保持隧道开启而不提供任何 Shell 功能
AUTH_OPTIONS="restrict,port-forwarding,permitopen=\"127.0.0.1:$TARGET_PORT\",command=\"echo 'Tunnel Ready. Press Ctrl+C to disconnect.'; read\""

echo "$AUTH_OPTIONS $PUB_KEY" > "$SSH_DIR/authorized_keys"

# 5. 设置严格的文件权限
chmod 600 "$SSH_DIR/authorized_keys"
chown -R $USERNAME:$USERNAME "$SSH_DIR"

# 6. 自动化：将私钥拷贝到宿主机的 OpenClaw 配置目录中，以便容器挂载
# 优先使用 sudo 之前的原始用户目录，否则退回到当前 root 的 home
REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
OPENCLAW_SSH_DIR="$REAL_HOME/.openclaw/.ssh"

echo "正在部署私钥到: $OPENCLAW_SSH_DIR/host_cdp ..."
mkdir -p "$OPENCLAW_SSH_DIR"
cp "$KEY_PATH" "$OPENCLAW_SSH_DIR/host_cdp"
chown "$REAL_USER:$REAL_USER" "$OPENCLAW_SSH_DIR/host_cdp"
chmod 600 "$OPENCLAW_SSH_DIR/host_cdp"

echo "=================================================="
echo "✅ 创建成功！权限控制已生效。"
echo "=================================================="
echo "私钥已自动部署到宿主机: $OPENCLAW_SSH_DIR/host_cdp"
echo "该目录已挂载到容器内的 ~/.ssh/host_cdp"
echo "--------------------------------------------------"
echo "在容器内建立隧道的命令 (gateway 启动脚本已包含此逻辑)："
echo "ssh -i ~/.ssh/host_cdp -N -L 9222:127.0.0.1:9222 $USERNAME@<宿主机内网IP>"
echo "=================================================="
