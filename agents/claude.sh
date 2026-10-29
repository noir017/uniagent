#!/bin/bash
# @anthropic-ai/claude-code（npm 全局，落在 /usr/lib/node_modules）。
set -eux
npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
npm cache clean --force
claude --version
npm ls -g @anthropic-ai/claude-code --depth=0
# talkcode 的 cc harness 不再自带 CLI，靠 talkcode-daemon.sh 把
# CLAUDE_CODE_EXECUTABLE 指到这个路径（见 agents/talkcode.sh）。哪天包结构变了、
# 这个文件不在了，在这里失败，而不是等到 cc 第一次回话才报 "native binary not found"。
test -x /usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
# 同一个变量也写进登录环境（2026-10-29）：talkcode 搬进自己的容器以后，cc 是网关经 ssh
# 远程起的，环境取的是这里的**登录环境**（talkcode-remote 跑 `bash -i -l -c`），不经过
# talkcode-daemon.sh，也看不到 Dockerfile 的 ENV —— sshd 起的会话不继承容器 PID 1 的环境。
# 不写的话远程 cc 第一句话就报 "Claude native binary not found"（SDK 自带那份已被删掉）。
printf '%s\n' \
    '[ -n "${CLAUDE_CODE_EXECUTABLE:-}" ] || export CLAUDE_CODE_EXECUTABLE=/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe' \
    > /etc/profile.d/20-claude-code.sh
