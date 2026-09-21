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

# ---- agent-anywhere：IM 网关（Telegram ↔ claude/opencode/…）----
# 与上面的 sshd 段同样的姿态：只在镜像里装了才动作（旧镜像也能用这份 entrypoint），
# 失败只警告、不退出 —— teleport 是主进程，不能被网关拖垮。
#
# 以 config.yaml 存在为前提：镜像里不含任何配置与 token，没配过的新机器直接跳过，
# 不会 crash-loop。配置只住在 ~/.config/agent-anywhere/（bind mount）。
#
# runuser 而不是直接跑：网关必须是 user（uid 1001），它复用的是 /home/user 下的
# claude/opencode 登录态。**HOME 必须显式传** —— runuser -u 不模拟登录、不改 HOME，
# 不传的话脚本会去 /root/.config 找配置，然后判定"缺配置"退出。
if [ -x /usr/bin/agent-anywhere ] && [ -f "${HOME_DIR}/.config/agent-anywhere/config.yaml" ]; then
    if /usr/sbin/runuser -u "${USERNAME}" -- env HOME="${HOME_DIR}" \
        /usr/local/bin/agent-anywhere-daemon.sh start; then
        :
    else
        echo "[entrypoint] !! agent-anywhere 启动失败（teleport 不受影响）" >&2
    fi
fi

# ---- ttyd：agent-anywhere webui 终端面板的后端 ----
# 同样的姿态：没装就跳过，失败只警告不退出，不做 crash-loop 重启（容器重启即恢复）。
#
# **默认关闭，要显式设 UNIAGENT_WEB_TERMINAL=1（在 docker-compose 里）。**
# 这不是谨慎，是它和别的东西不在一个量级上：webui 的那个 token 原本守的是「和智能体说
# 话」，打开它之后守的是「一个 shell」。权限上限没变（智能体本来就是全工具权限），但从
# token 泄漏到任意命令的距离短得多。
#
# 两个开关而不是一个，是因为它们回答两个不同的问题：config.yaml 里的 terminal.enabled 说
# 「页面上要不要有那个按钮」，这里的环境变量说「容器里要不要真的跑一个 shell 服务」。两边
# 不一致也不会静默 —— 按钮在、后端没起，代理会明确回 502「terminal backend is not running」。
#
# -i 是 unix socket 不是端口：网络上根本够不着，所以 agent-anywhere 那道 session 检查是
# 唯一入口，而不是两个入口之一。socket 落在 bind mount 的配置目录里，两边都以 user 跑。
# -b /term 必须和 agent-anywhere 的前缀路由一致；-a 允许 URL 传参，这是「每个 topic 一个
# 终端」的实现方式，传进来的东西两边各校验一次（代理比对 topic 表，wrapper 再比对正则）。
WEB_TERM_SOCK="${HOME_DIR}/.config/agent-anywhere/webui-term.sock"
if [ "${UNIAGENT_WEB_TERMINAL:-0}" = "1" ] && [ -x /usr/local/bin/ttyd ]; then
    # 上次容器退出留下的 socket 文件会让 bind 直接失败，而它并不代表有进程在听。
    rm -f "${WEB_TERM_SOCK}"
    mkdir -p "${HOME_DIR}/.config/agent-anywhere"
    chown "${UID_N}:${GID_N}" "${HOME_DIR}/.config/agent-anywhere" 2>/dev/null || true
    /usr/sbin/runuser -u "${USERNAME}" -- env HOME="${HOME_DIR}" \
        /usr/local/bin/ttyd \
            -i "${WEB_TERM_SOCK}" \
            -b /term \
            -W -a -O -P 30 \
            -T xterm-256color \
            -t 'theme={"background":"#131313","foreground":"#dcdcdc","cursor":"#dcdcdc","selectionBackground":"#3a5f86"}' \
            /usr/local/bin/aa-terminal.sh \
            >> "${HOME_DIR}/.config/agent-anywhere/ttyd.log" 2>&1 &
    # ttyd 建的 socket 是 0660。收紧到 0600：同机其他用户否则能直连后端，绕开整道登录。
    # 后台起的进程，bind 需要一点时间，所以是等一下再改而不是立刻改。
    ( sleep 1; chmod 600 "${WEB_TERM_SOCK}" 2>/dev/null || true ) &
    echo "[entrypoint] ttyd 已启动 (socket ${WEB_TERM_SOCK})"
fi

echo "[entrypoint] ready: $(date '+%F %T %Z')  cmd: $*"
exec "$@"
