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
# 注意 locale：sshd 不继承上面的 ENV，SSH 会话的 LANG 由客户端经 AcceptEnv 送入
# （本地多为 en_US.UTF-8）。镜像里不生成该 locale 的话 glibc 会静默回落 C locale，
# 中文文件名就会被 ls 转义成 \344\270\211 这种八进制。故此处显式 locale-gen。
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
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; \
    locale-gen; \
    echo 'LANG=C.UTF-8' >> /etc/environment; \
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
#
# codex 这一对必须同命令、同版本地装，否则镜像里会有两份 codex。
# @agentclientprotocol/codex-acp 是 agent-anywhere 的 harness=codex 启动的 ACP 适配器
# （替代已废弃的 @zed-industries/codex-acp），它把 @openai/codex 声明成普通依赖，
# 而 npm 对 0.x 版本的 caret 是锁次版本号的：^0.154.0 等价于 >=0.154.0 <0.155.0。
# 所以顶层若是 0.155.x，codex-acp 会在自己的 node_modules 里再嵌一份 0.154 的
# @openai/codex —— 连同它 ~284 MB 的平台二进制。实测：钉 0.154.0 去重后
# /usr/lib/node_modules 是 301 MB，不钉是 613 MB。
#
# 因此 CODEX_VERSION 不是"想用哪个版本"，而是"codex-acp 依赖哪个版本"。升级
# codex-acp 时必须回来同步它，下面的断言会在版本漂移时让构建当场失败，而不是
# 悄悄把镜像撑大 300 MB。
ARG CODEX_VERSION=0.154.0
# 安装命令已拆到 agents/node-agents.sh，见下面"agents 组合层"（按 AGENTS 按需安装）。

# ---------- 6. 用户 user（可 sudo）----------
RUN set -eux; \
    groupadd -g ${GID} ${USERNAME}; \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME}; \
    usermod -aG sudo ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${USERNAME}; \
    chmod 0440 /etc/sudoers.d/90-${USERNAME}; \
    install -d -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.local/bin /home/${USERNAME}/workspace

# ---------- 7. Antigravity CLI (agy) ----------
# 安装命令已拆到 agents/agy.sh，见下面"agents 组合层"（按 AGENTS 按需安装）。

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

# ---------- 10. GitHub CLI (gh) ----------
# 单独最后一层：升级/重装 gh 只重建这一层，前面全部走缓存。
# 认证数据落在 /home/user/.config/gh/（bind mount），重建不丢。
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version

# ---------- 11. agents 组合层（按 AGENTS 按需安装）----------
#   全量：  --build-arg AGENTS="node-agents,agy,agent-anywhere,dsh"
#   精简：  --build-arg AGENTS="node-agents"          # 不要 dsh 省 ~294MB
# 每个 agent 独立一层：升级 dsh 只重建 dsh 层，前面全走缓存。
# 版本 ARG 留在 Dockerfile（供 bump-agent-anywhere.yml sed 改写），以环境变量透给脚本。
ARG AGENTS="node-agents,agy,agent-anywhere,dsh"
ARG AGENT_ANYWHERE_VERSION=1.22.0
ARG AGENT_ANYWHERE_SHA256=64ab191a9a1abf99a25e4c4ff094c322b7d59dfa102c4adeafe3434da6cb6125
ARG DSH_VERSION=0.1.2-rc.1
COPY agents/ /opt/agents/
COPY dsh/settings.yaml dsh/cordis.patch.yml /opt/dsh-config/
COPY codex/config.toml /opt/codex-config/config.toml
RUN set -eux; \
    rest="${AGENTS},"; \
    while [ -n "${rest}" ]; do \
        a="${rest%%,*}"; rest="${rest#*,}"; \
        case ",node-agents,agy,agent-anywhere,dsh," in \
            *,"${a}",*) ;; \
            *) echo "unknown agent in AGENTS: $a (want: node-agents,agy,agent-anywhere,dsh)" >&2; exit 1 ;; \
        esac; \
    done
RUN set -eux; \
    case ",${AGENTS}," in *,node-agents,*) \
        export CODEX_VERSION; bash /opt/agents/node-agents.sh ;; \
    esac; \
    npm cache clean --force
RUN set -eux; \
    case ",${AGENTS}," in *,agy,*) \
        export USERNAME; bash /opt/agents/agy.sh ;; \
    esac
RUN set -eux; \
    case ",${AGENTS}," in *,agent-anywhere,*) \
        export AGENT_ANYWHERE_VERSION AGENT_ANYWHERE_SHA256; bash /opt/agents/agent-anywhere.sh ;; \
    esac; \
    npm cache clean --force
RUN set -eux; \
    case ",${AGENTS}," in *,dsh,*) \
        export DSH_VERSION; bash /opt/agents/dsh.sh ;; \
    esac; \
    npm cache clean --force; \
    rm -rf /opt/agents
# 预置配置跟随 agent 走：没选 dsh 就不播种 ~/.dsh，没选 node-agents 就不播种 ~/.codex。
RUN set -eux; \
    case ",${AGENTS}," in *,dsh,*) \
        install -d -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.dsh /opt/home-skel/.dsh; \
        cp /opt/dsh-config/settings.yaml /opt/dsh-config/cordis.patch.yml /home/${USERNAME}/.dsh/; \
        cp /opt/dsh-config/settings.yaml /opt/dsh-config/cordis.patch.yml /opt/home-skel/.dsh/; \
        chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.dsh /opt/home-skel/.dsh ;; \
    esac; \
    case ",${AGENTS}," in *,node-agents,*) \
        install -d -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.codex /opt/home-skel/.codex; \
        cp /opt/codex-config/config.toml /home/${USERNAME}/.codex/config.toml; \
        cp /opt/codex-config/config.toml /opt/home-skel/.codex/config.toml; \
        chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.codex /opt/home-skel/.codex ;; \
    esac; \
    rm -rf /opt/dsh-config /opt/codex-config

# 守护脚本放最后：改脚本不触发上面的下载层。
COPY bin/agent-anywhere-daemon.sh /usr/local/bin/agent-anywhere-daemon.sh
RUN chmod +x /usr/local/bin/agent-anywhere-daemon.sh

# recall MCP 服务（见 mcp/README.md）。放进镜像而不是 /home/user，是因为它是代码不是配置：
# 镜像更新就一起更新，不会在某台机器上悄悄留个旧版本。指向它的注册项仍在 /home/user 下
# 各 agent 自己的配置里——那是持久卷，重建镜像不受影响。
# 无依赖（node ≥ 18 自带 fetch），所以只是拷一个文件，不新增任何安装层。
COPY mcp/hindsight-recall.mjs /usr/local/lib/hindsight-recall/hindsight-recall.mjs
RUN node --check /usr/local/lib/hindsight-recall/hindsight-recall.mjs

# agy 多 Google 账号切换器。agy 自己只认一份凭据，换号得重登；这个脚本把
# ~/.gemini/antigravity-cli/antigravity-oauth-token 快照成具名 profile，切换即原子替换该文件。
# 和 agy 一样放 /usr/local/bin：它是代码不是配置，留在 $HOME 会被 bind mount 的持久卷盖住，
# 镜像更新推不下去。profile 数据本身仍在 ~/.config/agy-accounts/（持久卷，重建不丢）。
#
# 之所以敢改文件就生效：agy 优先读 OS keyring、文件只是兜底，而本镜像没装 secret-tool
# 也没有 D-Bus session，keyring 那条路根本走不通 —— 文件就是唯一来源。
# 哪天镜像里加了 gnome-keyring/kwallet，这个前提就没了，`agyacct doctor` 会检测并告警。
#
# 运行时依赖 jq / curl / python3 / procps(pgrep) 都在第 1 段的 apt 里；flock(util-linux)
# 和 tar 是 Debian 必装包。同样放最后，改脚本不触发上面的下载层。
COPY bin/agyacct /usr/local/bin/agyacct
RUN chmod +x /usr/local/bin/agyacct; \
    bash -n /usr/local/bin/agyacct

WORKDIR /home/user
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/sbin/entrypoint.sh"]
CMD ["sleep","infinity"]
