#!/bin/bash
# Go（官方 tarball，Debian 源里的 1.19 太老），由 ua-tools 装进 $PREFIX，GOROOT 就是 $PREFIX。
# go 按 os.Executable() 解出真实路径找 GOROOT，经 /usr/local/bin/go 那层软链调用不影响。
# 需要环境变量：PREFIX VERSION UA_TMP
set -eux
arch="$(dpkg --print-architecture)"
case "${arch}" in
    amd64) goarch=amd64 ;;
    arm64) goarch=arm64 ;;
    *) echo "unsupported arch: ${arch}" >&2; exit 1 ;;
esac
curl -fsSL "https://go.dev/dl/go${VERSION}.linux-${goarch}.tar.gz" -o "${UA_TMP}/go.tgz"
tar -C "${PREFIX}" --strip-components=1 -xzf "${UA_TMP}/go.tgz"
"${PREFIX}/bin/go" version
