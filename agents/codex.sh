#!/bin/bash
# codex + codex-acp：必须同命令、同版本安装，否则镜像里会有两份 codex。
# @agentclientprotocol/codex-acp 是 agent-anywhere 的 harness=codex 启动的 ACP 适配器，
# 它把 @openai/codex 声明成普通依赖，而 npm 对 0.x 版本的 caret 是锁次版本号的：
# ^0.156.1 等价于 >=0.156.1 <0.157.0。所以顶层若是别的次版本，codex-acp 会在自己的
# node_modules 里再嵌一份匹配的 @openai/codex —— 连同它 ~284 MB 的平台二进制。
# 实测（0.155.1 那一代）：去重后相关目录是 301 MB，不钉是 613 MB。
#
# 因此 CODEX_VERSION 不是"想用哪个版本"，而是"codex-acp 依赖哪个版本"。升级
# codex-acp 时必须回来同步它，下面的断言会在版本漂移时让构建当场失败，而不是
# 悄悄把镜像撑大 300 MB。
#
# 需要环境变量：CODEX_VERSION
set -eux
npm install -g \
    --allow-scripts=@openai/codex \
    "@openai/codex@${CODEX_VERSION}" \
    @agentclientprotocol/codex-acp
npm cache clean --force
test ! -e /usr/lib/node_modules/@agentclientprotocol/codex-acp/node_modules/@openai \
    || { echo "codex-acp nested its own @openai/codex — bump CODEX_VERSION to match its dependency range" >&2; exit 1; }
codex --version; codex-acp --version
