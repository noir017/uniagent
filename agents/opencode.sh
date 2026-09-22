#!/bin/bash
# opencode v2（npm 全局，落在 /usr/lib/node_modules）。
#
# 包名在 v2 换了作用域：v1 是 opencode-ai，v2 是 @opencode/cli。两者都把 bin 装成
# `opencode`，所以绝不能同时装 —— 这里只装 v2，镜像是从零构建、没有升级路径，不存在
# 覆盖问题。postinstall 负责按平台挑原生二进制，故需要 --allow-scripts。
#
# agent-anywhere 的 harness=opencode 启动 `opencode acp`，v2 仍是正式子命令
# （已在 2.0.12 上实测：v1 格式的 ~/.config/opencode/opencode.json 里自定义
# provider、{env:...} 展开、以及 opencode/* 模型目录都照旧生效）。
set -eux
npm install -g --allow-scripts=@opencode/cli @opencode/cli
npm cache clean --force
opencode --version
