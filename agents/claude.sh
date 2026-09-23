#!/bin/bash
# @anthropic-ai/claude-code（npm 全局，落在 /usr/lib/node_modules）。
set -eux
npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
npm cache clean --force
claude --version
npm ls -g @anthropic-ai/claude-code --depth=0
# agent-anywhere 的 cc harness 不再自带 CLI，靠 agent-anywhere-daemon.sh 把
# CLAUDE_CODE_EXECUTABLE 指到这个路径（见 agents/agent-anywhere.sh）。哪天包结构变了、
# 这个文件不在了，在这里失败，而不是等到 cc 第一次回话才报 "native binary not found"。
test -x /usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
