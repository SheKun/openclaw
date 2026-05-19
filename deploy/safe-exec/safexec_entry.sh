#!/bin/sh
set -e

# If not running as root, re-run with sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Run the token extraction script to populate /root/.vault/env
if [ -f /opt/safe-exec/extract-tokens.ts ]; then
    /usr/local/bin/tsx /opt/safe-exec/extract-tokens.ts \
        || echo "⚠️ Token extraction failed, continuing..."
fi

# Execute the main command
exec "$@"
