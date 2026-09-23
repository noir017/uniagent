#!/bin/bash
# @anthropic-ai/claude-code（npm 全局，落在 /usr/lib/node_modules）。
set -eux
npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
npm cache clean --force
claude --version
npm ls -g @anthropic-ai/claude-code --depth=0
