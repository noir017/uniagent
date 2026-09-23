#!/bin/bash
# agent-anywhere（IM 网关）：装 GitHub Release tarball，不装 npm 上的同名包。
# 需要环境变量：AGENT_ANYWHERE_VERSION AGENT_ANYWHERE_SHA256；可选 AGENTS
#
# 和 codex 那一对是同一类问题：镜像里会有两份 Claude Code。agent-anywhere 的
# claude harness 经由 claude-agent-acp → @anthropic-ai/claude-agent-sdk，而这个 SDK
# 把 Claude Code CLI 的原生二进制当作 optionalDependencies 自带一份
# （@anthropic-ai/claude-agent-sdk-linux-<arch>/claude，~222 MB）。claude.sh 装的
# 全局 @anthropic-ai/claude-code 是同一个二进制 —— 2.1.280 时 cmp 逐字节相同。
#
# 所以镜像里装了全局 claude 时，这里把 SDK 那份删掉，
# 再由 agent-anywhere-daemon.sh 设 CLAUDE_CODE_EXECUTABLE 指向全局那份（SDK 认这个
# 变量，见 claude-agent-acp dist/acp-agent.js 的 claudeCliPath）。副作用是 cc harness
# 跑的 CLI 版本跟着全局 claude 走（CI 取的是 npm latest），不再是 SDK 锁的那个 ——
# 这是刻意的：交互式 claude 和网关里的 cc 永远是同一个版本。
#
# 是装完再删，不是 --omit=optional：npm 12 的 `install -g` 对 --omit=optional /
# --no-optional / npm_config_omit 一概无视（2026-09-23 实测，同一个 tarball 装成本地依赖
# 就会省掉，装成全局就不会）。删除和安装在同一个 RUN 层里，所以这 222 MB 不进镜像。
# 那 8 个平台包是 SDK 自己的 optionalDependencies，缺了 SDK 只是找不到自带二进制、
# 转而读 CLAUDE_CODE_EXECUTABLE，不影响别的。没选 claude 时照常保留，cc harness 仍然可用。
set -eux
curl -fsSL -o /tmp/aa.tgz \
    "https://github.com/noir017/agent-anywhere/releases/download/v${AGENT_ANYWHERE_VERSION}/agent-anywhere-cli-${AGENT_ANYWHERE_VERSION}.tgz"
echo "${AGENT_ANYWHERE_SHA256}  /tmp/aa.tgz" | sha256sum -c -
npm install -g /tmp/aa.tgz
rm -f /tmp/aa.tgz
npm cache clean --force
installed="$(node -p "require('/usr/lib/node_modules/agent-anywhere-cli/package.json').version")"
test "${installed}" = "${AGENT_ANYWHERE_VERSION}"
case ",${AGENTS:-}," in *,claude,*)
    find /usr/lib/node_modules/agent-anywhere-cli -type d -path '*/@anthropic-ai/claude-agent-sdk-*' -prune -exec rm -rf {} +
    # 断言：删掉了就真的没有。哪天 SDK 换了包名或打包方式、这份换个地方又装回来，
    # 构建当场失败，而不是镜像悄悄胖回 222 MB。
    if find /usr/lib/node_modules/agent-anywhere-cli -type f -name claude -size +10M | grep .; then
        echo "a bundled Claude binary is still inside agent-anywhere-cli" >&2
        exit 1
    fi
    ;;
esac
echo "agent-anywhere ${installed} installed at $(command -v agent-anywhere)"
agent-anywhere --help > /dev/null
