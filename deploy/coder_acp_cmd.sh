#!/bin/sh
# Gateway connects to coder-copilot as cli_usr and invokes copilot CLI
# through the safe-exec wrapper. cli_usr has no access to the token;
# run-cli.sh (running as root via sudo) sources the env file, loads
# the KeePassXC database, retrieves GH_TOKEN, and injects it into the
# copilot process environment.
exec ssh -Tq -o StrictHostKeyChecking=no coder-kimi \
     'sudo /opt/safe-exec/run-cli.sh \
     /root/.local/bin/kimi acp' "$@"
