#!/bin/sh
exec ssh -Tq -o StrictHostKeyChecking=no coder-copilot \
     copilot --acp --stdio --allow-all-tools --allow-all-paths --allow-all-urls "$@"
