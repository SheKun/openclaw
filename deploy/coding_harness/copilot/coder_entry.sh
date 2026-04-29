#!/bin/bash
set -e

echo "🚀 Starting SSH server for Coding Harness Gateway..."
# 1. 创建权限分离目录
mkdir -p /run/sshd
chmod 0755 /run/sshd

# 2. 生成 SSH 主机密钥
ssh-keygen -A

# 3. 创建用户 coder
./create_ssh_user.sh \
    --server-user "coder" \
    --public-key "${CODER_PUB_KEY:-}"

# 4. Inject credentials into SSH session environment so copilot can authenticate.
#    PermitUserEnvironment yes in sshd_config enables ~/.ssh/environment lookup.
SSH_ENV_FILE=/home/coder/.ssh/environment
: > "$SSH_ENV_FILE"
[[ -n "${GH_TOKEN:-}" ]] && echo "GH_TOKEN=${GH_TOKEN}" >> "$SSH_ENV_FILE"
chmod 600 "$SSH_ENV_FILE"
chown coder:coder "$SSH_ENV_FILE"

# 5. 启动 sshd
exec /usr/sbin/sshd -D -e
