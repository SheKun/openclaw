# syntax=docker/dockerfile:1.7

FROM node:22-bookworm-slim

USER root

# Install required packages with cache mounts and minimal footprint.
# --no-install-recommends avoids pulling in GUI deps we do not need.
RUN --mount=type=cache,id=safe-exec-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=safe-exec-apt-lists,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      sudo \
      keepassxc \
    && rm -rf /var/lib/apt/lists/*

# Install tsx to run TypeScript files
RUN npm install -g tsx

# Set working directory
WORKDIR /opt/safe-exec

# Copy cli-wrapper.ts, owned by root, unreadable by anyone else
COPY --chown=root:root cli-wrapper.ts .

# Create a wrapper script that loads secrets from a root-only env file,
# then executes cli-wrapper.ts. cli_usr cannot read this script.
RUN cat <<'EOF' > /opt/safe-exec/run-cli.sh
#!/bin/bash
set -e
if [ -r /root/.safe-exec/env ]; then
    set -a
    source /root/.safe-exec/env
    set +a
fi
exec /usr/local/bin/tsx /opt/safe-exec/cli-wrapper.ts "$@"
EOF
RUN chmod -R 700 /opt/safe-exec && chown -R root:root /opt/safe-exec

# Create cli_usr user (no password, cannot log in)
RUN useradd -m -s /bin/bash cli_usr

# Configure sudoers:
# - cli_usr needs no TTY (Docker default has none without -t)
# - cli_usr can run only the wrapper, and only with arguments
RUN printf "Defaults:cli_usr !requiretty\ncli_usr ALL=(ALL) NOPASSWD: /opt/safe-exec/run-cli.sh *\n" > /etc/sudoers.d/cli-wrapper \
    && chmod 440 /etc/sudoers.d/cli-wrapper

# Switch to cli_usr by default
USER cli_usr

# Default command shows usage; pass real args at runtime
CMD ["sudo", "/opt/safe-exec/run-cli.sh"]
