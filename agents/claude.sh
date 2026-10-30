#!/bin/bash
# @anthropic-ai/claude-code（npm 包），由 ua-tools 装进 $PREFIX。
# 需要环境变量：PREFIX VERSION
set -eux
npm install -g --prefix "${PREFIX}" --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${VERSION}"
"${PREFIX}/bin/claude" --version
# talkcode 的 cc harness 不再自带 CLI，靠 CLAUDE_CODE_EXECUTABLE 指到这个文件（经
# /opt/ua/claude/current，见 talkcode-daemon.sh 和 Dockerfile 里的 20-claude-code.sh）。
# 哪天包结构变了、这个文件不在了，在这里失败，而不是等到 cc 第一次回话才报
# "native binary not found"。
test -x "${PREFIX}/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
