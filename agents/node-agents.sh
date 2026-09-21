#!/bin/bash
# opencode + claude + codex + codex-acp（一层 npm，共用去重）。
# codex 与 codex-acp 必须同脚本、同版本安装，否则镜像里会有两份 codex
# （见 Dockerfile 注释：0.x caret 锁次版本，漂移即 +300MB）。
# 需要环境变量：CODEX_VERSION
set -eux
npm install -g \
    --allow-scripts=opencode-ai,@anthropic-ai/claude-code,@openai/codex \
    opencode-ai \
    @anthropic-ai/claude-code \
    "@openai/codex@${CODEX_VERSION}" \
    @agentclientprotocol/codex-acp
npm cache clean --force
test ! -e /usr/lib/node_modules/@agentclientprotocol/codex-acp/node_modules/@openai \
    || { echo "codex-acp nested its own @openai/codex — bump CODEX_VERSION to match its dependency range" >&2; exit 1; }
opencode --version; claude --version; codex --version; codex-acp --version
