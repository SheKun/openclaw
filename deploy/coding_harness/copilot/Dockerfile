# syntax=docker/dockerfile:1.7
# Coding harness image with GitHub Copilot CLI for OpenClaw ACP sessions.
# Inherits from safe-exec: cli_usr invokes copilot via sudo ->
# run-cli.sh -> cli-wrapper.ts, which retrieves GH_TOKEN from KeePassXC
# and injects it into the copilot process. cli_usr never sees the token.
#

FROM safe-exec:latest

USER root

ARG COPILOT_VERSION=latest

# Install OpenSSH server for SSH-transported ACP execution from gateway.
RUN --mount=type=secret,id=openclaw_debian_sources,required=false,target=/run/secrets/openclaw-debian.sources \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eu; \
    if [ -f /run/secrets/openclaw_debian.sources ]; then \
        rm -f /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; \
        cp /run/secrets/openclaw_debian.sources /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server \
        ca-certificates \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY ./sshd_config /etc/ssh/sshd_config

RUN mkdir -p /run/sshd \
    && chmod 0755 /run/sshd \
    && ssh-keygen -A

# Install GitHub Copilot CLI
RUN --mount=type=secret,id=openclaw_npmrc,required=false,target=/run/secrets/openclaw-npmrc \
    --mount=type=cache,target=/root/.npm \
    set -eu; \
    if [ -f /run/secrets/openclaw-npmrc ]; then \
        export NPM_CONFIG_USERCONFIG=/run/secrets/openclaw-npmrc; \
    fi; \
    npm install -g "@github/copilot@${COPILOT_VERSION}"

CMD ["/usr/sbin/sshd", "-D", "-e"]
