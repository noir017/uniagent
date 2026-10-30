#!/bin/bash
# talkcode（IM 网关）：装 GitHub Release tarball，不装 npm 上的同名包。由 ua-tools 装进 $PREFIX。
# 需要环境变量：PREFIX VERSION TALKCODE_SHA256 UA_TMP；可选 WITH_CLAUDE=1
#
# 和 codex 那一对是同一类问题：会有两份 Claude Code。talkcode 的
# claude harness 经由 claude-agent-acp → @anthropic-ai/claude-agent-sdk，而这个 SDK
# 把 Claude Code CLI 的原生二进制当作 optionalDependencies 自带一份
# （@anthropic-ai/claude-agent-sdk-linux-<arch>/claude，~222 MB）。agents/claude.sh 装的
# @anthropic-ai/claude-code 是同一个二进制 —— 2.1.280 时 cmp 逐字节相同。
#
# 所以已经装了 claude 时（WITH_CLAUDE=1，ua-tools 总是先装 claude 再装 talkcode），这里把
# SDK 那份删掉，再由 CLAUDE_CODE_EXECUTABLE 指向 claude 那份（SDK 认这个变量，见
# claude-agent-acp dist/acp-agent.js 的 claudeCliPath；设它的是 talkcode-daemon.sh 和
# /etc/profile.d/20-claude-code.sh）。副作用是 cc harness 跑的 CLI 版本跟着 claude 走，不再是
# SDK 锁的那个 —— 这是刻意的：交互式 claude 和网关里的 cc 永远是同一个版本。
#
# 是装完再删，不是 --omit=optional：npm 12 的 `install -g` 对 --omit=optional /
# --no-optional / npm_config_omit 一概无视（2026-09-23 实测，同一个 tarball 装成本地依赖
# 就会省掉，装成全局就不会）。那 8 个平台包是 SDK 自己的 optionalDependencies，缺了 SDK
# 只是找不到自带二进制、转而读 CLAUDE_CODE_EXECUTABLE，不影响别的。没装 claude 时照常保留，
# cc harness 仍然可用。
set -eux
curl -fsSL -o "${UA_TMP}/talkcode.tgz" \
    "https://github.com/noir017/talkcode/releases/download/v${VERSION}/talkcode-${VERSION}.tgz"
echo "${TALKCODE_SHA256}  ${UA_TMP}/talkcode.tgz" | sha256sum -c -
npm install -g --prefix "${PREFIX}" "${UA_TMP}/talkcode.tgz"
pkg="${PREFIX}/lib/node_modules/talkcode"
installed="$(node -p "require('${pkg}/package.json').version")"
test "${installed}" = "${VERSION}"
if [ "${WITH_CLAUDE:-0}" = 1 ]; then
    find "${pkg}" -type d -path '*/@anthropic-ai/claude-agent-sdk-*' -prune -exec rm -rf {} +
    # 断言：删掉了就真的没有。哪天 SDK 换了包名或打包方式、这份换个地方又装回来，
    # 安装当场失败，而不是悄悄多占 222 MB。
    if find "${pkg}" -type f -name claude -size +10M | grep .; then
        echo "a bundled Claude binary is still inside talkcode" >&2
        exit 1
    fi
fi
echo "talkcode ${installed} installed at ${PREFIX}"
"${PREFIX}/bin/talkcode" --help > /dev/null
