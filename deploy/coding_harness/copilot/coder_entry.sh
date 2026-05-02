#!/bin/bash
set -e

echo "🚀 Starting Copilot ACP server on 0.0.0.0:8765..."

copilot --acp --host 0.0.0.0 --port 8765 \
        --allow-all-tools --allow-all-paths --allow-all-urls
