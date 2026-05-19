#!/bin/sh
set -e

# If not running as root, re-run with sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Run safe-exec entry.sh
sh /safexec_entry.sh

# Create cli_usr user and configure SSH public key for SSH-transported ACP
/create_ssh_user.sh \
    --server-user cli_usr \
    --home /home/cli_usr \
    --public-key "${OPENCLAW_PUB_KEY}"

exec "$@"
