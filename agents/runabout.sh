#!/bin/bash
# runabout（给 Gemini / ChatGPT / Claude.ai 网页端用的 MCP 工具服务，github.com/noir017/runabout）：
# 装 GitHub Release 的预编译二进制（纯 Go，单文件）。由 ua-tools 装进 $PREFIX/bin。
# 怎么跑起来见 /usr/local/lib/ua-service/runabout.sh（ua-service 保活）。
# 需要环境变量：PREFIX VERSION UA_TMP
set -eux
arch="$(dpkg --print-architecture)"
case "${arch}" in
    amd64|arm64) ;;
    *) echo "unsupported arch: ${arch}" >&2; exit 1 ;;
esac
base="https://github.com/noir017/runabout/releases/download/v${VERSION}"
asset="runabout-linux-${arch}"
curl -fsSL -o "${UA_TMP}/${asset}" "${base}/${asset}"
curl -fsSL -o "${UA_TMP}/SHA256SUMS" "${base}/SHA256SUMS"
# 只校验本架构那一行；grep 不到就是 release 里没有这个架构，当场失败。
(cd "${UA_TMP}" && grep -E "  ${asset}\$" SHA256SUMS | sha256sum -c -)
install -D -m 0755 "${UA_TMP}/${asset}" "${PREFIX}/bin/runabout"
"${PREFIX}/bin/runabout" version | grep -F "runabout v${VERSION}"
