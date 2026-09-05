# uniagent

多 AI CLI 一体化开发容器（Debian 12）。

> **unraid 移植版（2026-08-28）**：由 oracle 版移植，构建于 x86_64。容器名 `uniagent`，
> Teleport 节点名 **`uniagent-unraid`**（`ssh user@uniagent-unraid` 直达，bot-hermes 角色
> 已放行 `env=dev`）。数据目录 `/mnt/cache/appdata/uniagent/`，Compose Manager 托管
> （`autostart=true`，indirect 指向本目录）。
> **与原版差异：不映射直连 sshd 端口**（家里内网走堡垒机 1ms，无性能收益）。要直连时在
> `docker-compose.yml` 加 `ports: ["192.168.0.185:22022:22"]`，并把公钥放进
> `home/.ssh/authorized_keys`（容器内 user 家目录）。其余使用方式（helper 脚本、CLI
> 登录）与原版一致。原版 README 里关于 Oracle VCN 网络 / EasyTier 的段落不适用于本机。


## 预装

| 组件 | 位置 | 说明 |
|---|---|---|
| Node.js 24 + npm | `/usr/bin/node` | NodeSource 官方源 |
| opencode | `opencode` | npm `opencode-ai` |
| Claude Code | `claude` | npm `@anthropic-ai/claude-code` |
| Codex CLI | `codex` | npm `@openai/codex` |
| Antigravity CLI | `agy` | 官方安装脚本，装在 `/usr/local/bin`，属主 `user`（便于自更新） |
| agyacct | `agyacct` | agy 的多 Google 账号切换器（本仓库 `bin/agyacct`）。见「agy 多账号切换」一节 |
| Go | `/usr/local/go/bin/go` | 官方 tarball（`GO_VERSION` ARG，当前 1.27.0），`go`/`gofmt` 已软链进 `/usr/local/bin` |
| uv / uvx | `/usr/local/bin/uv` | Astral 官方脚本 |
| Teleport agent | `teleport` | apt 源 `stable/v18`，**钉 18.10.0**（不能比集群 auth 新），默认不启动 |
| agent-anywhere | `agent-anywhere` | IM 网关（Telegram ↔ claude/opencode/…）。版本由 Dockerfile 的 `AGENT_ANYWHERE_VERSION` 钉死（当前 0.4.0），装的是 GitHub Release 的 tarball 并校验 SHA256。见「IM 网关」一节 |
| 其他 | git、python3、build-essential、jq、ripgrep、fd、tmux、htop… | |

> 所有工具都装在 `/usr/local` 或 `/usr` 下，**不在 `$HOME`**，因此不会被 `/home/user` 的
> bind mount 遮蔽。

## 目录映射

| 容器内 | 宿主机 |
|---|---|
| `/home/user` | `~/apps/uniagent/home` （持久化，登录态/配置/代码都在这里） |
| `/etc/teleport` | `~/apps/uniagent/teleport/config` |
| `/var/lib/teleport` | `~/apps/uniagent/teleport/data` |

容器内用户 `user` 的 uid:gid = **1001:1001**，与宿主机 `ubuntu` 一致，挂载目录读写不串权限。
`user` 可免密 sudo。

## 使用

```bash
cd ~/apps/uniagent
docker compose pull && docker compose up -d   # 拉 CI 编译好的镜像并启动
docker compose logs -f                        # 看 entrypoint 输出
docker compose down                           # 停止
```

### 进容器：`uniagent`

```bash
uniagent                    # 交互式登录 shell（不依赖 cwd，容器停着会自动拉起）
uniagent claude             # 直接跑容器内的 CLI
uniagent bash -c "a; b"     # 复合命令（参数是逐个转义传给 docker exec 的，不是拼字符串）
uniagent --status           # 只看容器状态
uniagent --root             # 以 root 进入
uniagent --workspace        # 落到 ~/workspace
```

脚本在仓库里（`./uniagent`），已装到 `/usr/local/bin/uniagent`；宿主机重装后从这里重新
`sudo install` 即可。

> ⚠ **别用 `ua`**：`/usr/bin/ua` 是 ubuntu-advantage(Ubuntu Pro) 的软链，仓库里那个
> `./ua` 只因带 `./` 前缀才生效，去掉前缀会跑到 Ubuntu Pro 客户端去。`uniagent` 就是
> 为避开这个重名而起的。`./ua` 保留未动。

**本地（笔记本）直达**：`~/.local/bin/uniagent` 是同名包装脚本，参数完全一致，内部走
`ssh -t oracle uniagent`。不用 ssh config 里那个 `Host uniagent` 直连，是因为容器停着时
`ssh uniagent` 会**静默挂死**（Teleport 找不到 node 也不报错）；且容器刚启动后 agent 要
~13s 才重新注册。包装脚本走 docker exec，冷容器到拿到 shell 实测 1.2s。
热连两条路差 170ms（直连 690ms / 包装 861ms），确定容器在跑时可以直接 `ssh uniagent`。

各 CLI 首次使用需自行登录（`claude`、`codex login`、`opencode auth login`、`agy`），
凭据写在 `/home/user` 下，已持久化。SSH 会话里 `agy` 会打印授权 URL，在本地浏览器打开即可。

### agy 多账号切换：`agyacct`

`agy` 自己只认一份凭据，换 Google 号得重新走一遍登录。`agyacct` 把凭据文件
（`~/.gemini/antigravity-cli/antigravity-oauth-token`）快照成具名 profile，切换即原子替换该文件：

```bash
agyacct save main          # 把当前登录的号存下来（顺带就是份凭据备份）
agyacct login personal     # 走一遍 agy 登录流程，登完自动存为 personal
agyacct list               # 列表，* 标当前；邮箱是自动识别的，不用手工贴标签
agyacct use main           # 切回去（或 agyacct next 循环切）
agyacct doctor             # 环境体检
```

profile 存在 `~/.config/agy-accounts/`（持久卷，重建镜像不丢）。完整命令见 `agyacct help`。

三个需要知道的点：

- **切换前请退出 agy。** 切换对已启动的会话无效，且 agy 刷新 token 时会把旧凭据写回文件、
  覆盖掉这次切换。`agyacct` 默认拒绝在 agy 运行时切换，`-f` 可强制（带告警）。
- **账号身份按 `refresh_token` 认，不是比对文件。** agy 会就地刷新 `access_token` 并写回，
  文件内容一直在变；`refresh_token` 刷新后不变，才是稳定指纹。切换前脚本会先把线上文件
  回灌给它所属的 profile，避免丢掉 agy 刚刷新的 token。
- **依赖"文件是唯一凭据来源"这个前提。** agy 其实优先读 OS keyring（条目
  `service=gemini` / `username=antigravity`），文件只是兜底；本镜像没装 secret-tool 也没有
  D-Bus session，所以这条路走不通，改文件必定生效。若将来镜像里加了 gnome-keyring，
  `agyacct doctor` 会检测到并给出排查/清除命令。

邮箱识别是拿 `refresh_token` 换 `id_token` 解出来的，用的 OAuth 客户端**在运行时从 `agy` 二进制里
提取**（不硬编码：仓库里不放凭据字面量，且 agy 换客户端时能自动跟上）。二进制里的候选不止一组，
脚本逐个真打一次接口，认证通过的那对才缓存进 `~/.config/agy-accounts/.oauth-client.json`；
agy 自更新后二进制指纹变了会自动重新探测。这一步需要能访问 `oauth2.googleapis.com`；
不通时 profile 照样能存能切，只是显示 `<未知>`，之后补跑 `agyacct refresh <名字>` 即可。

## 网络：怎么够到家里的堡垒机

集群入口 `teleport.lan.noharanas.eu.org` 只在家庭局域网解析（openwrt 上 dnsmasq 泛解析），
`ssh_tunnel_public_addr` 是内网 `192.168.0.10:3024`，家宽 NAT 无公网入站 —— 云上的容器
本来拨不进去。现在靠两件事打通：

1. **oracle 宿主机加入了已有的 EasyTier 网络** `lqhome2177`，vip `10.192.168.30`，hostname `oracle`。
   openwrt 那个节点已经导出 `proxy_cidrs = 192.168.0.0/22`（subnet proxy），所以宿主机
   直接有 `192.168.0.0/22 dev tun0` 的路由。**没有给堡垒机开任何公网端口。**
   - **所有文件在 `~/apps/easytier`**（二进制/单元/密钥，见那边的 README）；
     `/etc/systemd/system/easytier.service` 只是指向它的软链
   - 服务：`systemctl status easytier`；查看拓扑 `sudo ~/apps/easytier/easytier-cli peer|route`
   - 容器出网靠 docker 自带的 `-s 172.x ! -o br-x -j MASQUERADE`（出 tun0 时源地址自动变成
     10.192.168.30），**不需要额外 iptables 规则**
2. **compose 里 `extra_hosts` 把 FQDN 钉到 `192.168.0.10`**。没用 EasyTier 的魔法 DNS
   （`--accept-dns`）—— 它只给 `<hostname>.et.net`，而 proxy 证书是 LE `*.lan.noharanas.eu.org`，
   用 et.net 名字连会 SAN 不匹配、只能 `--insecure`。也没把容器 DNS 指向 192.168.0.10，
   否则隧道一断容器里所有 AI CLI 的 DNS 全挂。

副作用（已知并接受）：容器能访问 `192.168.0.0/22` 全网段。走 relay 到家里 RTT 约 0.5s。

## Teleport agent（默认不启动）

镜像里只装了二进制，**没有** 任何 join 配置。需要接入时在容器内执行：

token 只能在 openwrt 上签（`docker exec teleport tctl tokens add --type=node --ttl=1h`），
ca-pin 可以从公开的 CA 导出接口自己算（等价于 `tctl status` 里那行）：

```bash
curl -s "https://teleport.lan.noharanas.eu.org/webapi/auth/export?type=tls-host" \
  | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -hex | awk '{print "sha256:"$NF}'
# 当前值：sha256:bb2123da7b76f8d0de1a581e4c11602ecba239ac74817bb7fbf5c21930e7301a
```

拿到 token 后在容器里：

```bash
./ua
sudo teleport node configure --silent \
  --output=file:///etc/teleport/teleport.yaml \
  --proxy=teleport.lan.noharanas.eu.org:443 \
  --token=<join token> \
  --ca-pin=sha256:bb2123da... \
  --labels=env=dev,host=oracle,kind=container,arch=arm64 \
  --node-name=uniagent
```

`--output` 是 `file://` + **绝对**路径，且**不覆盖已存在文件**（重生成先 `mv` 走）；
`--node-name`（不是 `--nodename`）**必须全小写**，
大写会让原生 `ssh` + ProxyCommand 报 `offline or does not exist`。

让它常驻：把 compose 的 `command` 改成
`["teleport","start","-c","/etc/teleport/teleport.yaml"]`（`./ua` 走 docker exec，不受影响）；
临时试跑用 `docker compose exec -d uniagent teleport start -c /etc/teleport/teleport.yaml`。
集群侧不用改角色：`home-ssh-admin` 是 `node_labels '*':'*'`、logins 已含 `user`。

配置与 host UUID 分别落在 `teleport/config`、`teleport/data`，容器重建不会重复注册。
agent 版本需 ≤ 集群 auth 版本；集群是 v18 时保持 `TELEPORT_CHANNEL=stable/v18` 即可。

## 重建

镜像由 CI 编译发布到 GHCR（`.github/workflows/docker.yml`，amd64 + arm64），**部署侧不 build**：

```bash
uniagent update              # 拉新镜像并重建；--dry-run 只拉不换，--force 无视占用
```

`update` 比手敲两条命令多做的事，都是踩过才加的：镜像引用从 compose 里读（不写死，钉版本时
跟着变）；比**镜像 ID** 而不是 tag（`latest` 会动，tag 没变不代表镜像没变），没变就一步不走；
重建前列出容器内除守护会话以外的 tmux 会话并拒绝执行，因为重建会把里面跑着的 coding agent
一起杀掉；重建后报 agent-anywhere 的**真实**版本（读已装包的 package.json，见下）和守护状态。

手动等价物，没有上面这些检查：

```bash
cd ~/apps/uniagent
docker compose pull && docker compose up -d
```

改了 `Dockerfile` / `entrypoint.sh` / `bin/` 就推 main，等 Actions 转绿再执行上面两条。
要钉死某次提交，把 `docker-compose.yml` 里的 `:latest` 换成 `:sha-<短 sha>`。

镜像重建不会影响 `~/apps/uniagent/home` 里的数据。首次启动时 entrypoint 会把镜像里的 home
骨架（`.bashrc`、`.local/bin`、`workspace`）补进空的挂载目录，已存在的文件不会被覆盖。
IM 网关会由 entrypoint 自动拉起，重建后**不需要任何手工补动作**。

## IM 网关（agent-anywhere）

Telegram 消息 → agent-anywhere → claude / opencode（ACP），回复流式写回。程序在镜像里，
配置在挂载里 —— 这条分界是刻意的：镜像可以随便重建，token 与会话历史不跟着走。

| 东西 | 位置 | 进镜像？ |
|---|---|---|
| 程序 | `/usr/bin/agent-anywhere`（`/usr/lib/node_modules/agent-anywhere-cli`） | ✅ 版本钉死 |
| 守护脚本 | `/usr/local/bin/agent-anywhere-daemon.sh` | ✅ |
| 配置 | `~/.config/agent-anywhere/config.yaml` | ❌ 挂载 |
| token | `~/.config/agent-anywhere/.env`（chmod 600） | ❌ 挂载 |
| 会话绑定 | `~/.config/agent-anywhere/conversations.json` | ❌ 挂载 |
| 日志 | `~/.config/agent-anywhere/daemon.log` | ❌ 挂载 |

容器 PID 1 是 teleport，没有 systemd，所以守护由 `agent-anywhere-daemon.sh` 顶上：跑在
独立 tmux 会话里，挂了自动重启，5s→300s 指数退避（跑满 60s 才算健康并重置退避，免得
配置错误时空转刷 Telegram API）。entrypoint 在 `config.yaml` 存在时自动 `start`，
所以**没配过的机器不会 crash-loop**。

```bash
bash /usr/local/bin/agent-anywhere-daemon.sh status   # 状态
bash /usr/local/bin/agent-anywhere-daemon.sh stop     # 改完配置重启用
bash /usr/local/bin/agent-anywhere-daemon.sh start
tail -f ~/.config/agent-anywhere/daemon.log           # 日志
tmux attach -t agent-anywhere-daemon                  # 贴现场
```

**升级**：镜像侧是自动的。agent-anywhere 仓库发出新 Release 之后，
`.github/workflows/bump-agent-anywhere.yml`（每天一次，也可在 Actions 页手动 Run workflow）
会查到它、从 Release 自带的 `SHA256SUMS` 取校验和、改掉 Dockerfile 里
`AGENT_ANYWHERE_VERSION` 与 `AGENT_ANYWHERE_SHA256` 两个 ARG 并提交，然后复用 docker.yml
把镜像推到 GHCR。这一层是 Dockerfile 的最后一层，改它不会让前面的 Node / 各 AI CLI 缓存失效。

**机器侧不自动**：镜像出来之后仍然要自己 `uniagent update`（见「重建」）。重建会杀掉容器里
正在跑的东西，那个时机不该由定时任务替人决定。

要钉某个版本（回退，或抢在定时之前升）：Actions → Bump agent-anywhere → Run workflow，
填版本号。定时那条路**只升不降**（Release 被撤回时不会把线上悄悄退回去）；填了版本号的
手动那条路可以降。直接手改两个 ARG 再推 main 当然也照样有效，自动流程只是省掉抄校验和。

> ⚠️ `agent-anywhere --version` 打印的是 cli.ts 里硬编码的字符串（当前恒为 `0.2.0`），
> **不是**真实版本。要看真实版本：
> `node -p "require('/usr/lib/node_modules/agent-anywhere-cli/package.json').version"`

> ⚠️ 别在 `~/.local` 里再装一份：`$HOME/.local/bin` 在 PATH 里排在 `/usr/bin` 前面，
> 手敲 `agent-anywhere` 会命中它，而守护进程走的是绝对路径 `/usr/bin/agent-anywhere`，
> 两边会静默跑成不同版本。真要临时试私有构建，用
> `AGENT_ANYWHERE_BIN=~/.local/bin/agent-anywhere bash /usr/local/bin/agent-anywhere-daemon.sh start`。

## 直连 sshd：给机器用的旁路（2026-08-20 加）

### 为什么有这条

Teleport 没有 P2P 旁路，**数据路径必然经过家里的 proxy**。而 runabout 在 oraclea2 上，
到本容器直线只有 1.8ms —— 走堡垒机却是两次跨洋往返。实测：

| 路径 | 每次新建连接 | ControlMaster 复用 | scp 吞吐 |
|---|---|---|---|
| 经家里堡垒机 (`uniagent-tp`) | 11–16s（实测最高 15.6s） | 1.7–3.4s | ~0.4 Mbps |
| VCN 内网直连 (`uniagent`) | **214ms** | **11ms** | **716 Mbps** |

链路实测：oracle↔oraclea2 走 VCN 内网 = RTT 1.8ms / 0% 丢包 / **997Mbps / MTU 9000**
（EasyTier 隧道只有 383Mbps / MTU 1360，已弃用）；
oracle↔家里 openwrt = RTT 342ms / **25% 丢包** / 19Mbps。**丢包才是 11-16s 的真凶**，
不是带宽 —— 一次 SSH 握手好几个往返，每个往返都可能重传。

那 240ms 里网络只占 12–19ms（TCP+banner 实测），其余是容器内 ssh 客户端进程启动
+ kex 的本地开销，压不下去；agent 实际走的是复用路径（11ms）。

### 组成

- `Dockerfile` 第 9 段装 `openssh-server`。**刻意放在最后一层** —— 加进第 1 段的 apt
  会让后面 7 层（Node / Python / 各 AI CLI）全部缓存失效，重建要几十分钟。
- `ssh/sshd_config.d/10-direct.conf` → 挂到 `/etc/ssh/sshd_config.d/`。
  属主必须 root（sshd 拒绝加载属主不对的 include）。
- `ssh/keys/` → 挂到 `/etc/ssh/keys`，**可写**。主机密钥在这里持久化，
  首次启动由 entrypoint 生成。这样重建镜像不换指纹，否则每次 rebuild 都要
  重写 oraclea2 那边的 known_hosts。已实测：`docker restart` 后指纹不变。
- `entrypoint.sh` 在 `exec "$@"` 之前后台启动 sshd。teleport 仍是 exec 的主进程，
  tini(PID 1) 负责回收。**sshd 的任何一步失败都只警告不退出** —— 不能拖垮 teleport。
  代价：sshd 意外退出不会自动拉起，容器重启即恢复。
- compose 里 `ports: - "10.0.0.38:22022:22"`（VCN 内网地址 + **30000-40000 之外**的端口）。

### 安全边界

这条路**没有** Teleport 的角色门禁、会话录制、证书过期。补偿手段全部落在 sshd 上：

- 监听绑 VCN 内网地址 `10.0.0.38:22022`。**公网由云侧拦掉**：Oracle 的公网 IP 是到
  10.0.0.38 的 1:1 NAT、目的地址区分不了来源，但 OCI 安全列表只对 `0.0.0.0/0` 放通了
  22 / 80 / 443 / 30000-40000，而 **22022 不在其中**。已实测（sshd 确实在监听时）
  公网 IPv4 timeout、IPv6 unreachable，对照组公网 22 正常通。
  → **改这个端口前必须先确认新端口不在安全列表对公网开放的范围内**，否则立刻裸奔。
- 内网侧靠 OCI 的一条 ingress 规则放通：Source `10.0.0.0/24` / **All Protocols**
  （OCI 默认**不给**这条，默认只有 22 + ICMP type 3 —— 所以同网段 ping 不通是正常的）。
- 主机侧第二道防线（`netfilter-persistent save` 已持久化）：
  ```
  -A DOCKER-USER -i enp0s6 -s 10.0.0.0/24 -d 172.16.0.0/12 -p tcp --dport 22 -j RETURN
  -A DOCKER-USER -i enp0s6              -d 172.16.0.0/12 -p tcp --dport 22 -j DROP
  ```
  不引用容器 IP，所以容器/网络重建都不影响。**已验证计数器真的在涨**（3218 包 / 53M）——
  这是上次踩坑后必做的一步，规则"看起来对"但计数器恒 0 就等于没有。
- 只认公钥、只允许 `user`、`PermitRootLogin no`。
- **所有转发能力关闭**（`AllowTcpForwarding` / `AllowAgentForwarding` / `PermitTunnel`
  / `GatewayPorts` / `X11Forwarding` 全 no）—— 对齐原先 chatgpt 角色的
  `port_forwarding: false`，否则这把钥匙等于一条进内网的隧道。
- 授权的公钥只有一把，在 `/home/ubuntu/apps/uniagent/home/.ssh/authorized_keys`
  （= 容器内 `/home/user/.ssh/`，1001:1001 600），对应
  `oraclea2:~/apps/runabout/ssh/id_uniagent`。私钥是在 oraclea2 上生成的，从未离开那台机器。

人类访问路径**完全没动**：uniagent 仍然是堡垒机里的 agent 节点，
`chatgpt` 角色的范围也仍然只有 uniagent（已复验）。

### 坑

- **开机竞态**：tun0 还没起来时 docker 绑不上这个地址，容器起不来，报
  `failed to bind host port 10.192.168.30:30022/tcp: cannot assign requested address`
  （已实测确认）。`restart: unless-stopped` 会重试，easytier.service 就绪后自愈。
  手工恢复：`systemctl status easytier && docker compose up -d`。
- **authorized_keys 别用 `printf '%s\n' "a\nb"` 写** ——`\n` 在 `%s` 里是字面量，
  整个文件会挤成一行，表现是 `Permission denied (publickey)`。用 heredoc。
- **绑 VCN 地址时端口的选择就是安全边界。** Oracle 公网 IP 是到 10.0.0.38 的 **1:1 NAT**，
  地址区分不了来源，所以能不能被公网访问**完全取决于端口是否落在安全列表对
  `0.0.0.0/0` 放通的范围里**。2026-08-20 用 30022（在放通的 30000-40000 内）实测过：
  公网 `129.153.116.132:30022` 直接返回了容器 banner
  `SSH-2.0-OpenSSH_9.2p1 Debian-2+deb12u10`。换到 22022 后公网 timeout。
- **DNAT 在 PREROUTING 完成，filter 表看到的目的端口已经是容器端口。**
  所以按 `--dport 30022` 写的 `DOCKER-USER` 规则**永远匹配不到**（当场踩过：
  规则在那儿，计数器恒为 0，公网照样进得来）。要在 DOCKER-USER 里挡，必须按
  DNAT **之后**的形态匹配（`--dport 22` + 容器网段/网卡）。
  反过来，按 30022 写的 `INPUT` 规则只在**没有 DNAT**命中时才生效。
- **两台机器同在 VCN 的 10.0.0.0/24**（oracle .38 / oraclea2 .108），TCP 直通，
  但 **ICMP 被 OCI 安全列表挡掉** —— ping 不通不代表网络不通，别用 ping 判断。

### 撤销（回到只走 Teleport）

```sh
# 1. 吊销钥匙。sshd 每次认证都重读，不用重启容器
sudo rm /home/ubuntu/apps/uniagent/home/.ssh/authorized_keys
# 2. 彻底不再监听：注释掉 docker-compose.yml 里的 ports 段（10.0.0.38:22022）
cd ~/apps/uniagent && docker compose up -d
# 3. oraclea2 那边把 ssh/config 里的 uniagent-tp 改回 uniagent
```

## License

GNU Affero General Public License v3.0 (AGPL-3.0). See [LICENSE](LICENSE).
