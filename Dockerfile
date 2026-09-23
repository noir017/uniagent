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
# 安装命令已拆到 agents/opencode.sh、agents/claude.sh、agents/codex.sh，
# 见下面"agents 组合层"（按 AGENTS 按需安装）。

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

# ---------- 9b. ttyd：agent-anywhere webui 终端面板的后端 ----------
#
# 网页里那个终端不是 agent-anywhere 自己实现的 —— 它只做一层过 session cookie 的反向代理，
# 真正的 PTY 在这里。这么分是为了让 agent-anywhere 一个原生依赖都不用加：自己实现要引
# node-pty（**它的 tarball 里只有 darwin 和 win32 的 prebuild，Linux 一个都没有**，等于
# 所有 Linux 安装都要现场编译）、xterm.js、WebSocket 服务端，外加 scrollback / resize /
# 重连 / 手机软键盘。ttyd 是 1.3MB 静态二进制，这些连同 CJK 与 IME 支持全都现成。
#
# Debian bookworm 源里没有 ttyd（只在 sid），所以走 release 静态二进制，和上面 Go、
# teleport 同一个路子。校验和逐架构写死：改版本必须同时改这两行，否则构建当场失败，而不是
# 悄悄装上一个没人核对过的二进制。
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256_AMD64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
ARG TTYD_SHA256_ARM64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) asset=ttyd.x86_64;  sum="${TTYD_SHA256_AMD64}" ;; \
        arm64) asset=ttyd.aarch64; sum="${TTYD_SHA256_ARM64}" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${asset}" \
        -o /usr/local/bin/ttyd; \
    echo "${sum}  /usr/local/bin/ttyd" | sha256sum -c -; \
    chmod +x /usr/local/bin/ttyd; \
    ttyd --version
COPY bin/aa-terminal.sh /usr/local/bin/aa-terminal.sh
COPY aa-terminal.tmux.conf /usr/local/etc/aa-terminal.tmux.conf
RUN chmod +x /usr/local/bin/aa-terminal.sh

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
#   全量：  --build-arg AGENTS="opencode,claude,codex,agy,agent-anywhere"
#   精简：  --build-arg AGENTS="opencode,claude"
# 每个 agent 独立一层：升级 opencode 只重建 opencode 层，前面全走缓存。
# 只有 codex 例外：codex 与 codex-acp 必须同装（见 agents/codex.sh），故合并为一个 token。
# 版本 ARG 留在 Dockerfile（供 bump-agent-anywhere.yml sed 改写），以环境变量透给脚本。
ARG AGENTS="opencode,claude,codex,agy,agent-anywhere"
ARG CLAUDE_CODE_VERSION=latest
ARG AGENT_ANYWHERE_VERSION=1.28.0
ARG AGENT_ANYWHERE_SHA256=69affc864021ed794153dfeac61592f1ff96589345c83817d7dc001fe5e9e3a2
COPY agents/ /opt/agents/
COPY codex/config.toml /opt/codex-config/config.toml
RUN set -eux; \
    rest="${AGENTS},"; \
    while [ -n "${rest}" ]; do \
        a="${rest%%,*}"; rest="${rest#*,}"; \
        case ",opencode,claude,codex,agy,agent-anywhere," in \
            *,"${a}",*) ;; \
            *) echo "unknown agent in AGENTS: $a (want: opencode,claude,codex,agy,agent-anywhere)" >&2; exit 1 ;; \
        esac; \
    done
RUN set -eux; \
    case ",${AGENTS}," in *,opencode,*) \
        bash /opt/agents/opencode.sh ;; \
    esac; \
    npm cache clean --force
RUN set -eux; \
    case ",${AGENTS}," in *,claude,*) \
        export CLAUDE_CODE_VERSION; bash /opt/agents/claude.sh ;; \
    esac; \
    npm cache clean --force
RUN set -eux; \
    case ",${AGENTS}," in *,codex,*) \
        export CODEX_VERSION; bash /opt/agents/codex.sh ;; \
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
    npm cache clean --force; \
    rm -rf /opt/agents
# 预置配置跟随 agent 走：没选 codex 就不播种 ~/.codex。
RUN set -eux; \
    case ",${AGENTS}," in *,codex,*) \
        install -d -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.codex /opt/home-skel/.codex; \
        cp /opt/codex-config/config.toml /home/${USERNAME}/.codex/config.toml; \
        cp /opt/codex-config/config.toml /opt/home-skel/.codex/config.toml; \
        chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.codex /opt/home-skel/.codex ;; \
    esac; \
    rm -rf /opt/codex-config

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
