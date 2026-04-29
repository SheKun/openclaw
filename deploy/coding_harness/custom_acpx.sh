#!/bin/sh
exec ssh -Tq -o StrictHostKeyChecking=no coder-copilot copilot --acp --stdio
