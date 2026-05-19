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
COPY --chown=root:root cli-wrapper.ts .
COPY --chown=root:root extract-tokens.ts .
COPY --chown=root:root run-cli.sh .
RUN chmod -R 700 /opt/safe-exec

# Create cli_usr user (no password, cannot log in)
RUN useradd -m -s /bin/bash cli_usr

# Configure sudoers:
# - cli_usr needs no TTY (Docker default has none without -t)
# - cli_usr can run only the wrapper, and only with arguments
RUN printf "Defaults:cli_usr !requiretty\ncli_usr ALL=(ALL) NOPASSWD: /opt/safe-exec/run-cli.sh *, /opt/safe-exec/entry.sh *\n" > /etc/sudoers.d/cli-wrapper \
    && chmod 440 /etc/sudoers.d/cli-wrapper

COPY safexec_entry.sh /safexec_entry.sh
RUN chmod +x /safexec_entry.sh

ENTRYPOINT ["/safexec_entry.sh"]


# volume to mount the vault
# the following files are supposed to be mounted here:
# - vault.kdbx: the keepassxc vault file
# - key.pass: the master key for the vault
# - allowlist.json: the command allowlist
# e.g.
# {
#     "/bin/copilot": {"env": "GH_TOKEN", "slot": "copilot/gh_token"},
#     "/usr/local/bin/aws": {"env": "AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY", "slot": "aws/access_key_id"}
#     "*": {}
# }
VOLUME ["/root/.vault"]

# Switch to cli_usr by default
USER cli_usr

# Default command shows usage; pass real args at runtime
CMD ["sudo", "/opt/safe-exec/run-cli.sh"]
