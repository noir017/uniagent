#!/bin/bash
# Antigravity CLI (agy)：官方安装脚本装进 $PREFIX/bin。
#
# 目录名固定是 auto 而不是版本号：agy 会在后台自更新、原地换掉这个二进制（所以属主必须是
# user —— ua-tools 本来就以 user 跑），装的那一刻是哪个版本没有意义。装在持久卷里以后，
# 自更新的结果重建容器也不丢（以前在 /usr/local/bin，重建一次就退回构建那天的版本）。
#
# HOME 换成临时目录：安装脚本最后会跑 `agy install`，往 $HOME 的 shell rc 里加 PATH，
# 而命令由镜像里的 /usr/local/bin/agy 软链提供，不该去改持久卷里的 ~/.bashrc。
#
# 需要环境变量：PREFIX UA_TMP
set -eux
curl -fsSL https://antigravity.google/cli/install.sh -o "${UA_TMP}/agy-install.sh"
mkdir -p "${UA_TMP}/home"
HOME="${UA_TMP}/home" bash "${UA_TMP}/agy-install.sh" --dir "${PREFIX}/bin"
"${PREFIX}/bin/agy" --version || true
