#!/bin/sh
set -e

# If not running as root, re-run with sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Generate allowlist.json for safe-exec wrapper in coder-copilot
mkdir -p /root/.vault
cat << 'EOF' > /root/.vault/allowlist.json
{
  "/usr/local/bin/copilot": {
    "env": "GH_TOKEN",
    "slot": "copilot/gh_token"
  }
}
EOF
chmod 700 /root/.vault
chmod 600 /root/.vault/allowlist.json

# Run safe-exec entry.sh
sh /safexec_entry.sh

# Create cli_usr user and configure SSH public key for SSH-transported ACP
/create_ssh_user.sh \
    --server-user cli_usr \
    --home /home/cli_usr \
    --public-key "${OPENCLAW_PUB_KEY}"

exec "$@"
