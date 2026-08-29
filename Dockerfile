# uniagent —— 多 AI CLI 一体化开发容器（arm64 / Debian 12）
FROM debian:12-slim

ARG USERNAME=user
ARG UID=1001
ARG GID=1001
ARG NODE_MAJOR=24
ARG TELEPORT_CHANNEL=stable/v18
# 必须 <= 集群 auth 版本（当前集群 18.10.0），agent 不允许比 auth 新
ARG TELEPORT_VERSION=18.10.0
ARG TZ=Asia/Shanghai

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=${TZ} \
    USERNAME=${USERNAME}

# ---------- 1. 基础系统与常用工具 ----------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg sudo tini locales tzdata \
        git openssh-client rsync \
        bash-completion less vim-tiny nano tmux \
        procps psmisc htop file jq ripgrep fd-find \
        unzip zip xz-utils bzip2 \
        iproute2 iputils-ping dnsutils netcat-openbsd \
        python3 python3-venv build-essential pkg-config; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime; echo ${TZ} > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

# ---------- 2. Node.js + npm (NodeSource) ----------
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    npm install -g npm@latest; \
    node -v; npm -v

# ---------- 3. Teleport agent ----------
RUN set -eux; \
    curl -fsSL https://apt.releases.teleport.dev/gpg \
        -o /usr/share/keyrings/teleport-archive-keyring.asc; \
    echo "deb [signed-by=/usr/share/keyrings/teleport-archive-keyring.asc] https://apt.releases.teleport.dev/debian bookworm ${TELEPORT_CHANNEL}" \
        > /etc/apt/sources.list.d/teleport.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends teleport=${TELEPORT_VERSION}; \
    rm -rf /var/lib/apt/lists/*; \
    teleport version

# ---------- 4. uv (装到 /usr/local/bin，不落在 $HOME) ----------
RUN set -eux; \
    curl -fsSL https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh; \
    uv --version; uvx --version

# ---------- 4b. Go (官方 tarball，Debian 源里的 1.19 太老) ----------
# 装到 /usr/local/go，不落在 $HOME，不会被 /home/user 的 bind mount 遮蔽。
# 升级 Go 只需改 GO_VERSION 并重建：单独一层，只重建这一层。
ARG GO_VERSION=1.27.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) goarch=amd64 ;; \
        arm64) goarch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go; \
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt; \
    go version

# ---------- 5. AI CLI（npm 全局，落在 /usr/lib/node_modules）----------
RUN set -eux; \
    npm install -g \
        --allow-scripts=opencode-ai,@anthropic-ai/claude-code,@openai/codex \
        opencode-ai \
        @anthropic-ai/claude-code \
        @openai/codex; \
    npm cache clean --force; \
    opencode --version; claude --version; codex --version

# ---------- 6. 用户 user（可 sudo）----------
RUN set -eux; \
    groupadd -g ${GID} ${USERNAME}; \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME}; \
    usermod -aG sudo ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${USERNAME}; \
    chmod 0440 /etc/sudoers.d/90-${USERNAME}; \
    install -d -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.local/bin /home/${USERNAME}/workspace

# ---------- 7. Antigravity CLI (agy) ----------
# 装到 /usr/local/bin 以免被 /home/user 的 bind mount 遮蔽；
# 属主给 user，保证 agy 后台自更新可写。
RUN set -eux; \
    curl -fsSL https://antigravity.google/cli/install.sh -o /tmp/agy-install.sh; \
    bash /tmp/agy-install.sh --dir /usr/local/bin; \
    rm -f /tmp/agy-install.sh; \
    chown ${USERNAME}:${USERNAME} /usr/local/bin/agy; \
    /usr/local/bin/agy --version || true

# ---------- 8. 环境与骨架 ----------
RUN set -eux; \
    printf '%s\n' \
      'export PATH="$HOME/.local/bin:$PATH"' \
      'export EDITOR=${EDITOR:-vim}' \
      '[ -f /etc/bash_completion ] && . /etc/bash_completion' \
      > /etc/profile.d/10-uniagent.sh; \
    printf '%s\n' \
      'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac' \
      "PS1='\\[\\e[32m\\]\\u@uniagent-unraid\\[\\e[0m\\]:\\[\\e[34m\\]\\w\\[\\e[0m\\]\$ '" \
      "alias ll='ls -alF'" \
      >> /home/${USERNAME}/.bashrc; \
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bashrc; \
    mkdir -p /opt/home-skel; \
    cp -a /home/${USERNAME}/. /opt/home-skel/

# ---------- 9. sshd（只给机器直连用，人类仍走 Teleport）----------
# 背景：Teleport 没有 P2P 旁路，数据路径必然经过家里的 proxy。runabout(oraclea2)
# 到本容器直线只有 1.8ms，绕家里却是 2 次 342ms/25% 丢包的跨洋往返（实测每次
# 新建 ssh 11-16s）。所以给机器开一条直连：sshd 只绑到宿主机的 EasyTier 地址，
# 公网与 Oracle 公有 IP 都碰不到；人类访问不变，仍走堡垒机（有角色门禁+录制）。
#
# 刻意放在最后一层：加在第 1 段的 apt 里会让后面 7 层（Node/Python/各 AI CLI）
# 全部失效，重建要几十分钟；放这里只重建这一层。
# 装包时自动生成的主机密钥一并删掉：真正使用的是 /etc/ssh/keys 下持久化的那一份
# （见 sshd_config.d/10-direct.conf 的 HostKey），留着只会让人误判指纹来源。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends openssh-server; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd /etc/ssh/keys; \
    rm -f /etc/ssh/ssh_host_*

COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
RUN chmod +x /usr/local/sbin/entrypoint.sh

WORKDIR /home/user
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/sbin/entrypoint.sh"]
CMD ["sleep","infinity"]
