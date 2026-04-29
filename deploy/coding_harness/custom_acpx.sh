#!/bin/sh
exec ssh -o StrictHostKeyChecking=no coder-copilot acpx "$@"
