#!/bin/bash
set -e

echo "🚀 Starting SSH server for Coding Harness Gateway..."
# 1. 创建权限分离目录
mkdir -p /run/sshd
chmod 0755 /run/sshd

# 2. 生成 SSH 主机密钥
ssh-keygen -A

# 3. 创建 用户coder
./create_ssh_user.sh \
    --server-user "coder" \
    --public-key "${CODER_PUB_KEY:-}"

# 4. 启动 sshd
exec /usr/sbin/sshd -D -e
