#!/bin/bash
# codex + codex-acp：必须同命令、同 prefix 安装，否则会有两份 codex。
# @agentclientprotocol/codex-acp 是 talkcode 的 harness=codex 启动的 ACP 适配器，
# 它把 @openai/codex 声明成普通依赖，而 npm 对 0.x 版本的 caret 是锁次版本号的：
# ^0.160.1 等价于 >=0.160.1 <0.161.0。所以顶层若是别的次版本，codex-acp 会在自己的
# node_modules 里再嵌一份匹配的 @openai/codex —— 连同它 ~284 MB 的平台二进制。
# 实测（0.155.1 那一代）：去重后相关目录是 301 MB，不钉是 613 MB。
#
# 因此 codex 的版本不是"想用哪个版本"，而是"codex-acp 依赖哪个版本"。以前镜像里手钉
# CODEX_VERSION，codex-acp 每改一次依赖范围构建就挂一次（0.156.1 → 0.165.0 之间改过 5 回）；
# 现在由 ua-tools 按 codex-acp 声明的范围取最高版本，传进来的 VERSION 就是这一对。
# 下面的断言保留：哪天算错了，安装当场失败，而不是悄悄多占 300 MB。
#
# 需要环境变量：PREFIX VERSION（<codex 版本>+acp.<codex-acp 版本>）UA_SHARE
set -eux
codex_ver="${VERSION%%+acp.*}"
acp_ver="${VERSION#*+acp.}"
npm install -g --prefix "${PREFIX}" \
    --allow-scripts=@openai/codex \
    "@openai/codex@${codex_ver}" \
    "@agentclientprotocol/codex-acp@${acp_ver}"
test ! -e "${PREFIX}/lib/node_modules/@agentclientprotocol/codex-acp/node_modules/@openai" \
    || { echo "codex-acp nested its own @openai/codex — the version pair is wrong" >&2; exit 1; }
"${PREFIX}/bin/codex" --version; "${PREFIX}/bin/codex-acp" --version

# 预置配置跟着 codex 走（连容器内的 newapi 网关，见仓库 codex/config.toml）：
# 只在 ~/.codex 还不存在时放，用户自己的配置一概不碰。
if [ ! -e "${HOME}/.codex" ]; then
    install -d "${HOME}/.codex"
    cp "${UA_SHARE}/codex-config.toml" "${HOME}/.codex/config.toml"
fi
