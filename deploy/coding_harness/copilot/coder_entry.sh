#!/bin/bash
set -e

echo "🚀 Starting SSH server for Coding Harness Gateway..."


# Configure SSH public key for cli_usr (safe-exec unprivileged user)
/create_ssh_user.sh \
    --server-user cli_usr \
    --public-key "${OPENCLAW_PUB_KEY:-}"


# Prepare the env file for safe-exec
if [ -f "${KEEPASSXC_DB}" ] && [ -f "${KEEPASSXC_KEY_FILE}" ]; then
    KEEPASSXC_KEY_VALUE=$(cat "${KEEPASSXC_KEY_FILE}")
    cat << EOF > /root/.safe-exec/env
KEEPASSXC_DB='${KEEPASSXC_DB}'
KEEPASSXC_KEY='${KEEPASSXC_KEY_VALUE}'
TOKEN_SLOT_PATH='${TOKEN_SLOT_PATH}'
TOKEN_ENV_VARS='GH_TOKEN'
ALLOWED_CLIS='/usr/local/bin/copilot'
EOF
    chmod 700 /root/.safe-exec/env
    echo "✅ safe-exec env file configured."
else
    echo "⚠️ KeePassXC secrets not found at ${KEEPASSXC_DB}/${KEEPASSXC_KEY_FILE}; copilot token injection will fail."
fi

exec "$@"
