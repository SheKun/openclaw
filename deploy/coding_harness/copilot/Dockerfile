# syntax=docker/dockerfile:1.7
# Coding harness image with GitHub Copilot CLI for OpenClaw ACP sessions.
#

ARG BASE_IMAGE=${BASE_IMAGE:-node:22-bookworm-slim}
FROM ${BASE_IMAGE}

USER root

ARG COPILOT_VERSION=latest

# Install OpenSSH server for SSH-transported ACP execution from gateway.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends openssh-server ca-certificates\
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY ./sshd_config /etc/ssh/sshd_config

# Install GitHub Copilot CLI
RUN --mount=type=cache,target=/root/.npm \
    npm install -g "@github/copilot@${COPILOT_VERSION}"

EXPOSE 22
