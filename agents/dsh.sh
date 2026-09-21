#!/bin/bash
# DeepSeek Harness (dsh)：npm 包 @deepseek-ai/dsh。
# 需要环境变量：DSH_VERSION
set -eux
npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"
npm cache clean --force
installed="$(node -p "require('/usr/lib/node_modules/@deepseek-ai/dsh/package.json').version")"
test "${installed}" = "${DSH_VERSION}"
echo "dsh ${installed} installed at $(command -v dsh)"
dsh --version > /dev/null
