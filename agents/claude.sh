#!/bin/bash
# @anthropic-ai/claude-code（npm 全局，落在 /usr/lib/node_modules）。
set -eux
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code
npm cache clean --force
claude --version
