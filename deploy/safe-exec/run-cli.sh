#!/bin/bash
set -e

if [ -r /root/.vault/env ]; then
    set -a
    source /root/.vault/env
    set +a
fi
exec /usr/local/bin/tsx /opt/safe-exec/cli-wrapper.ts "$@"
