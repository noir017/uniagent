#!/bin/bash
# uniagent entrypoint：修正挂载目录属主 + 首次运行补齐 home 骨架
set -euo pipefail

USERNAME="${USERNAME:-user}"
HOME_DIR="/home/${USERNAME}"
UID_N="$(id -u "${USERNAME}")"
GID_N="$(id -g "${USERNAME}")"

mkdir -p "${HOME_DIR}"

# 宿主机挂进来的目录可能属主不对（例如 root:root），统一修回 user
if [ "$(stat -c %u "${HOME_DIR}")" != "${UID_N}" ]; then
    echo "[entrypoint] chown ${HOME_DIR} -> ${UID_N}:${GID_N}"
    chown "${UID_N}:${GID_N}" "${HOME_DIR}"
fi

# 首次挂载空目录时，把镜像里的 home 骨架（.bashrc / .local/bin / workspace）补进去
if [ -d /opt/home-skel ]; then
    shopt -s dotglob nullglob
    for src in /opt/home-skel/*; do
        dst="${HOME_DIR}/$(basename "${src}")"
        if [ ! -e "${dst}" ]; then
            echo "[entrypoint] seed $(basename "${src}")"
            cp -a "${src}" "${dst}"
            chown -R "${UID_N}:${GID_N}" "${dst}"
        fi
    done
    shopt -u dotglob nullglob
fi

# teleport 状态目录（若已挂载）也归 root 使用，这里只保证存在
mkdir -p /var/lib/teleport

# ---- sshd：给机器直连用的旁路（人类仍走 Teleport）----
# 只在镜像里装了 openssh-server 时才动作，所以旧镜像也能用这份 entrypoint。
# 任何一步失败都只警告、不退出 —— teleport 是主进程，不能被 sshd 拖垮。
if [ -x /usr/sbin/sshd ]; then
    mkdir -p /run/sshd /etc/ssh/keys
    chmod 755 /run/sshd
    # 主机密钥落在宿主机挂进来的目录里，重建镜像不换指纹（否则 runabout 的
    # known_hosts 每次 rebuild 都要重写）。
    if [ ! -f /etc/ssh/keys/ssh_host_ed25519_key ]; then
        echo "[entrypoint] 生成持久化 sshd 主机密钥"
        ssh-keygen -t ed25519 -N '' -C "uniagent-direct" \
            -f /etc/ssh/keys/ssh_host_ed25519_key || true
    fi
    chmod 600 /etc/ssh/keys/ssh_host_ed25519_key 2>/dev/null || true
    if /usr/sbin/sshd -t 2>&1; then
        # 后台化：tini 是 PID 1，会负责收养和回收；teleport 仍是 exec 的主进程。
        # 代价是 sshd 意外退出不会被自动拉起 —— 容器重启即恢复。
        /usr/sbin/sshd
        echo "[entrypoint] sshd 已启动 (pid $(cat /run/sshd.pid 2>/dev/null || echo '?'))"
    else
        echo "[entrypoint] !! sshd 配置校验失败，跳过 sshd（teleport 不受影响）" >&2
    fi
fi

echo "[entrypoint] ready: $(date '+%F %T %Z')  cmd: $*"
exec "$@"
