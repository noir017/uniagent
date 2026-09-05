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

# ---------- 11. agent-anywhere（IM 网关：Telegram ↔ claude/opencode/…）----------
# 装的是 GitHub Release 里的 tarball，不是 npm 上的包：npm 上的 agent-anywhere-cli
# 归上游所有，本仓库这条线的版本只在 Release 上发。该 tarball 由 agent-anywhere 的
# release.yml 在 Actions 里跑完 typecheck/lint/test/build 后 npm pack 产出，
# 与 npm publish 出来的字节一致。
#
# 单独最后一层：升版本只重建这一层，前面 Node / 各 AI CLI 全走缓存。
# 升级方法：改下面两个 ARG（版本 + 校验和，校验和取 Release 里的 SHA256SUMS），
# 推 main 即可，CI 会重新编译发布。
#
# 装到 /usr（npm prefix 就是 /usr）而不是 /home/user：后者是 bind mount，
# 会被宿主机目录整个遮蔽，程序就又变成"挂载里的临时文件"了 —— 那正是这一层要消灭的状态。
#
# 版本断言看已装包的 package.json。1.1.0 起 `agent-anywhere --version` 也是真的了
# （之前是 cli.ts 里硬编码的 0.2.0，拿它断言会永远"通过"），但读 package.json 仍然更直接：
# 断言的是"装进镜像的那个包"，不经过 CLI 启动路径。
ARG AGENT_ANYWHERE_VERSION=1.1.2
ARG AGENT_ANYWHERE_SHA256=fe70312a57b5fdd87e233abd309d4bdde02c7a5fec557b8ad13ef939e9b22091
RUN set -eux; \
    curl -fsSL -o /tmp/aa.tgz \
        "https://github.com/noir017/agent-anywhere/releases/download/v${AGENT_ANYWHERE_VERSION}/agent-anywhere-cli-${AGENT_ANYWHERE_VERSION}.tgz"; \
    echo "${AGENT_ANYWHERE_SHA256}  /tmp/aa.tgz" | sha256sum -c -; \
    npm install -g /tmp/aa.tgz; \
    rm -f /tmp/aa.tgz; \
    npm cache clean --force; \
    installed="$(node -p "require('/usr/lib/node_modules/agent-anywhere-cli/package.json').version")"; \
    test "${installed}" = "${AGENT_ANYWHERE_VERSION}"; \
    echo "agent-anywhere ${installed} installed at $(command -v agent-anywhere)"; \
    agent-anywhere --help > /dev/null

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
