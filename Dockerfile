# uniagent —— 多 AI CLI 一体化开发容器（arm64 / Debian 12）
FROM debian:12-slim

ARG USERNAME=user
ARG UID=1001
ARG GID=1001
ARG NODE_MAJOR=24
# 钉死小版本：不钉的话 CI 的 gha 缓存会一直复用旧的 Node 层，上游出安全修复也进不来。
# 升级就改这里（版本号以 deb.nodesource.com/node_24.x 的 Packages 为准）。
ARG NODE_VERSION=24.22.1-1nodesource1
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
    apt-get install -y --no-install-recommends nodejs=${NODE_VERSION}; \
    rm -rf /var/lib/apt/lists/*; \
    npm install -g npm@latest; \
    node -v; npm -v

# ---------- 3. Teleport agent ----------
# 包里 5 个二进制 704 MB，这里只留 teleport（agent，PID 1）和 tsh（容器里连别的节点要用），
# 连同 tsh 要的 fdpass-teleport。删掉的三个容器里用不上：tctl 是管 auth 的，tbot 该跑在宿主机
# 上（机器身份不进容器），teleport-update 要 systemd。省 259 MB。
# 同一个 RUN 里删，才真的不进镜像。
RUN set -eux; \
    curl -fsSL https://apt.releases.teleport.dev/gpg \
        -o /usr/share/keyrings/teleport-archive-keyring.asc; \
    echo "deb [signed-by=/usr/share/keyrings/teleport-archive-keyring.asc] https://apt.releases.teleport.dev/debian bookworm ${TELEPORT_CHANNEL}" \
        > /etc/apt/sources.list.d/teleport.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends teleport=${TELEPORT_VERSION}; \
    rm -rf /var/lib/apt/lists/*; \
    for b in tctl tbot teleport-update; do \
        rm -f "/opt/teleport/system/bin/${b}" "/usr/local/bin/${b}"; \
    done; \
    teleport version; tsh version

# ---------- 4. uv (装到 /usr/local/bin，不落在 $HOME) ----------
RUN set -eux; \
    curl -fsSL https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh; \
    uv --version; uvx --version

# ---------- 6. 用户 user（可 sudo）----------
RUN set -eux; \
    groupadd -g ${GID} ${USERNAME}; \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME}; \
    usermod -aG sudo ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${USERNAME}; \
    chmod 0440 /etc/sudoers.d/90-${USERNAME}; \
    install -d -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.local/bin /home/${USERNAME}/workspace

# ---------- 8. 环境与骨架 ----------
RUN set -eux; \
    printf '%s\n' \
      'export PATH="$HOME/.local/bin:$PATH"' \
      'export EDITOR=${EDITOR:-vim}' \
      '[ -f /etc/bash_completion ] && . /etc/bash_completion' \
      > /etc/profile.d/10-uniagent.sh; \
    printf '%s\n' \
      'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac' \
      "PS1='\\[\\e[32m\\]\\u@uniagent\\[\\e[0m\\]:\\[\\e[34m\\]\\w\\[\\e[0m\\]\$ '" \
      "alias ll='ls -alF'" \
      >> /home/${USERNAME}/.bashrc; \
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bashrc; \
    mkdir -p /opt/home-skel; \
    cp -a /home/${USERNAME}/. /opt/home-skel/

# ---------- 9. sshd（只给机器直连用，人类仍走 Teleport）----------
# 背景：Teleport 的数据路径要经过 proxy，机器之间频繁新建 ssh 时延迟和丢包会被放大。
# 所以给机器开一条直连：sshd 只绑宿主机的内网地址，公网碰不到；人类访问不变，
# 仍走 Teleport（有角色门禁+录制）。
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

# ---------- 9b. ttyd：talkcode webui 终端面板的后端 ----------
#
# 网页里那个终端不是 talkcode 自己实现的 —— 它只做一层过 session cookie 的反向代理，
# 真正的 PTY 在这里。这么分是为了让 talkcode 一个原生依赖都不用加：自己实现要引
# node-pty（**它的 tarball 里只有 darwin 和 win32 的 prebuild，Linux 一个都没有**，等于
# 所有 Linux 安装都要现场编译）、xterm.js、WebSocket 服务端，外加 scrollback / resize /
# 重连 / 手机软键盘。ttyd 是 1.3MB 静态二进制，这些连同 CJK 与 IME 支持全都现成。
#
# Debian bookworm 源里没有 ttyd（只在 sid），所以走 release 静态二进制，和 agents/go.sh
# 装 Go 同一个路子。校验和逐架构写死：改版本必须同时改这两行，否则构建当场失败，而不是
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

# ---------- 11. 可选工具（装在持久卷 /opt/ua，不进镜像）----------
# opencode / claude / codex / agy / talkcode / Go 压缩后合计 ~650 MB、解压后 ~2 GB，曾占镜像的
# 一大半。现在镜像里只有安装器（bin/ua-tools + agents/*.sh）和版本钉子（pins.env），本体由
# ua-tools 装进 /opt/ua（compose 挂宿主机 ./tools）：换镜像不用重下，各机器用 compose 的
# UNIAGENT_TOOLS 选装。entrypoint 每次启动在后台跑 `ua-tools sync`，补齐缺的、把钉死的版本
# 对齐到这个镜像；uniagent update 换容器之前也先用新镜像预装一遍。细节见 bin/ua-tools 开头。
#
# UNIAGENT_TOOLS 这个 ARG 是 compose 没设时的默认清单（CI 的 lite 传 opencode,agy,go）。
# 版本 ARG 留在 Dockerfile（bump-talkcode.yml 用 sed 改写 TALKCODE_*），写进 pins.env 给 ua-tools。
# CLAUDE_CODE_VERSION 由 CI 解析成 npm latest 的具体版本传进来，所以「镜像里是构建那天的 claude」
# 和以前一样；本地构建不传就是 latest（装上以后只在 `ua-tools update` 时升）。
ARG UNIAGENT_TOOLS="opencode,claude,codex,agy,talkcode,go"
ARG TALKCODE_VERSION=2.16.0
ARG TALKCODE_SHA256=3980c82d027dac42bd6734929c69ce4ea94681359ed31bb74192e39e11433d6b
ARG GO_VERSION=1.27.0
ARG CLAUDE_CODE_VERSION=latest
COPY agents/ /usr/local/lib/ua-tools/
COPY codex/config.toml /usr/local/share/ua-tools/codex-config.toml
COPY bin/ua-tools /usr/local/bin/ua-tools
# /usr/local/bin 下的命令软链（stubs）在这里一次建好，指向 /opt/ua/<工具>/current；没装的悬空。
# /opt/ua 预先建好并归 user：忘了挂卷时照样能装（只是进了容器层，重建就没了）。
# 最后以 user 跑一次 list：默认清单里写错了工具名，构建当场失败。
RUN set -eux; \
    chmod +x /usr/local/bin/ua-tools; \
    bash -n /usr/local/bin/ua-tools; \
    for f in /usr/local/lib/ua-tools/*.sh; do bash -n "$f"; done; \
    printf '%s\n' \
      "UA_DEFAULT_TOOLS=${UNIAGENT_TOOLS}" \
      "TALKCODE_VERSION=${TALKCODE_VERSION}" \
      "TALKCODE_SHA256=${TALKCODE_SHA256}" \
      "GO_VERSION=${GO_VERSION}" \
      "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
      > /usr/local/share/ua-tools/pins.env; \
    install -d -o ${USERNAME} -g ${USERNAME} /opt/ua; \
    ua-tools stubs; \
    runuser -u ${USERNAME} -- ua-tools list
# talkcode 的 cc harness 要靠 CLAUDE_CODE_EXECUTABLE 找 claude（SDK 自带的那份在 agents/talkcode.sh
# 里删了）。也写进登录环境（2026-10-29）：talkcode 搬进自己的容器以后，cc 是网关经 ssh 远程起的，
# 环境取的是这里的**登录环境**（talkcode-remote 跑 `bash -i -l -c`），不经过 talkcode-daemon.sh，
# 也看不到 Dockerfile 的 ENV。不写的话远程 cc 第一句话就报 "Claude native binary not found"。
# 只在 claude 真装了时才设：指向一个不存在的路径，会把清楚的报错变成看不懂的 ENOENT。
RUN printf '%s\n' \
      'CLAUDE_UA_EXE=/opt/ua/claude/current/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe' \
      '[ -n "${CLAUDE_CODE_EXECUTABLE:-}" ] || [ ! -x "$CLAUDE_UA_EXE" ] || export CLAUDE_CODE_EXECUTABLE="$CLAUDE_UA_EXE"' \
      'unset CLAUDE_UA_EXE' \
      > /etc/profile.d/20-claude-code.sh

# ssh 登录会话的语言环境（2026-10-29）。上面 ENV 里的 LC_ALL 只有容器 PID 1 的子孙看得到；
# talkcode 搬进自己的容器以后，这里的 agent 是网关经 ssh 远程起的，环境取的是登录环境
# （talkcode-remote 跑 `bash -i -l -c`），实测里面没有 LC_ALL。缺了它 agent 跑的命令遇到
# 中文按 POSIX 处理。只在未设时补，人经 Teleport 登录带进来的值照旧。单独一层、放这里：
# 写进第 8 段会让后面所有下载层的缓存一起作废。
RUN printf '%s\n' 'export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"' \
      > /etc/profile.d/05-locale.sh

# 守护脚本放最后：改脚本不触发上面的下载层。
COPY bin/talkcode-daemon.sh /usr/local/bin/talkcode-daemon.sh
RUN chmod +x /usr/local/bin/talkcode-daemon.sh

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
