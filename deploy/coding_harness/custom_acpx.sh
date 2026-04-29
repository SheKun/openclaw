#!/bin/sh
exec ssh -T -o StrictHostKeyChecking=no coder-copilot copilot --acp --stdio
