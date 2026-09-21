#!/bin/bash
# Antigravity CLI (agy)：装到 /usr/local/bin，免被 /home/user bind mount 遮蔽。
# 需要环境变量：USERNAME
set -eux
curl -fsSL https://antigravity.google/cli/install.sh -o /tmp/agy-install.sh
bash /tmp/agy-install.sh --dir /usr/local/bin
rm -f /tmp/agy-install.sh
chown "${USERNAME}:${USERNAME}" /usr/local/bin/agy
/usr/local/bin/agy --version || true
