#!/bin/bash
# agent-anywhere（IM 网关）：装 GitHub Release tarball，不装 npm 上的同名包。
# 需要环境变量：AGENT_ANYWHERE_VERSION AGENT_ANYWHERE_SHA256
set -eux
curl -fsSL -o /tmp/aa.tgz \
    "https://github.com/noir017/agent-anywhere/releases/download/v${AGENT_ANYWHERE_VERSION}/agent-anywhere-cli-${AGENT_ANYWHERE_VERSION}.tgz"
echo "${AGENT_ANYWHERE_SHA256}  /tmp/aa.tgz" | sha256sum -c -
npm install -g /tmp/aa.tgz
rm -f /tmp/aa.tgz
npm cache clean --force
installed="$(node -p "require('/usr/lib/node_modules/agent-anywhere-cli/package.json').version")"
test "${installed}" = "${AGENT_ANYWHERE_VERSION}"
echo "agent-anywhere ${installed} installed at $(command -v agent-anywhere)"
agent-anywhere --help > /dev/null
