# syntax=docker/dockerfile:1.7
# Coding harness image with GitHub Copilot CLI for OpenClaw ACP sessions.
#

ARG BASE_IMAGE=${BASE_IMAGE:-node:22-bookworm-slim}
FROM ${BASE_IMAGE}

USER root

ARG COPILOT_VERSION=latest

# Install GitHub Copilot CLI
RUN --mount=type=cache,target=/root/.npm \
    npm install -g "@github/copilot@${COPILOT_VERSION}"

EXPOSE 8765
