#!/bin/bash
set -e

echo "🚀 Starting SSH server for Coding Harness Gateway..."
# 1. 创建权限分离目录
mkdir -p /run/sshd
chmod 0755 /run/sshd

# 2. 生成 SSH 主机密钥
ssh-keygen -A

# 3. 配置 SSH 公钥
./create_ssh_user.sh \
    --server-user "root" \
    --home "/root" \
    --public-key "${OPENCLAW_PUB_KEY:-}"

# 4. 启动 sshd（environment 文件由部署脚本预生成并通过卷挂载提供）
exec /usr/sbin/sshd -D -e
