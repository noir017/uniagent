# uniagent

多 AI CLI 一体化开发容器（Debian 12）。

## 预装

镜像里只放基础环境；各 coding agent 和 Go 是**可选工具**，由 `ua-tools` 装进持久卷 `/opt/ua`
（宿主机 `./tools`），不进镜像。镜像（arm64）压缩后从 ~1.1 GB 降到 ~0.4 GB（按旧镜像各层估算）。

**镜像内置**

| 组件 | 位置 | 说明 |
|---|---|---|
| Node.js 24 + npm | `/usr/bin/node` | NodeSource 官方源 |
| uv / uvx | `/usr/local/bin/uv` | Astral 官方脚本 |
| Teleport | `tsh`、`teleport` | apt 源 `stable/v18`，**钉 18.10.0**（不能比集群 auth 新）。tsh 连别的节点用；容器本身是 agentless 节点，teleport 默认不跑，留着回滚到 agent 模式。tctl / tbot / teleport-update 构建时删掉（省 259 MB） |
| agyacct | `agyacct` | agy 的多 Google 账号切换器（本仓库 `bin/agyacct`）。见「agy 多账号切换」一节 |
| ua-tools | `ua-tools` | 可选工具的安装器（本仓库 `bin/ua-tools` + `agents/*.sh`），见下 |
| ua-service | `ua-service` | 常驻服务的保活器（本仓库 `bin/ua-service` + `services/*.sh`），见「常驻服务」 |
| 其他 | git、python3、build-essential、jq、ripgrep、fd、tmux、htop、gh、ttyd… | |

**可选工具（`/opt/ua`）**

| 工具 | 命令 | 版本 | 说明 |
|---|---|---|---|
| `opencode` | `opencode` | latest | npm `@opencode/cli`（v2）。v1 的包名是 `opencode-ai`，两者都把 bin 装成 `opencode`，不能同装 |
| `claude` | `claude` | 钉（CI 构建时的 npm latest） | npm `@anthropic-ai/claude-code`。**只有这一份**：fleetherd 的 cc harness 经由 Agent SDK 本来还自带一份同样的 ~222 MB 二进制，`agents/fleetherd.sh` 装完即删，`CLAUDE_CODE_EXECUTABLE` 把 SDK 指到这份。所以 cc harness 跑的 CLI 版本 = 这里的版本 |
| `codex` | `codex`、`codex-acp` | latest | npm `@openai/codex` + `@agentclientprotocol/codex-acp`（fleetherd `harness: codex` 的 ACP 适配器）。codex-acp 把 codex 声明成普通依赖、0.x 的 caret 锁次版本号，顶层 codex 对不上就会再嵌一份 ~284 MB 的。所以 codex 的版本由 ua-tools 按 codex-acp 声明的范围算，不再手钉；有断言兜底。连 newapi 网关的配置在 `~/.codex` 不存在时预置 |
| `agy` | `agy` | 自更新 | 官方安装脚本。agy 在后台自己更新，装在持久卷里以后重建也不丢 |
| `fleetherd` | `fleetherd`、`talkcode`（别名）、`claude-agent-acp` | 钉（`FLEETHERD_VERSION`） | IM 网关，GitHub Release 的 tarball 并校验 SHA256。见「IM 网关」一节 |
| `go` | `go`、`gofmt` | 钉（`GO_VERSION`） | 官方 tarball |
| `runabout` | `runabout` | latest | 网页端 agent 的 MCP 工具服务，GitHub Release 的二进制并按 `SHA256SUMS` 校验。不在默认清单里，要跑的机器手动 `ua-tools install runabout`。见「常驻服务」 |

```bash
ua-tools list                 # 已装版本 / 钉的版本 / 是否在默认清单
ua-tools install go           # 装（不在默认清单里也行）
ua-tools update               # latest 类追到最新（opencode、codex、runabout，本地构建的 claude）
ua-tools remove codex         # 删
```

- **选装**：compose 里设 `UNIAGENT_TOOLS=opencode,agy`，不设就用镜像的默认清单（`latest` 全装，`lite`
  是 `opencode,agy,go`）。entrypoint 每次启动在**后台**跑 `ua-tools sync`：缺的装上、钉死的版本对齐到
  这个镜像（换镜像 = 换 fleetherd / go / claude 版本，和以前一样），日志在 `/opt/ua/sync.log`。
  第一次要下 ~1.8 GB，期间 ssh（含 Teleport）照常可进，agent 命令要等装完。
- **布局**：`/opt/ua/<工具>/<版本>/`，装完才把 `current` 切过去，失败就停在原来的版本；保留上一个版本
  （正在跑的进程可能还在用，回滚也只是把 `current` 指回去）。命令是镜像里 `/usr/local/bin/<命令>` →
  `/opt/ua/<工具>/current/…` 的固定软链，非登录的 ssh 也找得到；没装的软链悬空，报 command not found。
- **没挂 `./tools`** 也能用，只是装进容器层、每次重建都要重下，entrypoint 会告警。

**精简版 `ghcr.io/noir017/uniagent:lite`**（2026-10-29 起）：同一个 Dockerfile 用
`UNIAGENT_TOOLS=opencode,agy,go` 构建，和完整版的差别只剩默认清单。给只当 fleetherd 远程主机、只跑
oc / agy 的机器用。每次和完整版一起构建（`docker.yml` 的 flavor 矩阵），tag 是 `lite` 和
`sha-<短 sha>-lite`。

## 目录映射

| 容器内 | 宿主机 |
|---|---|
| `/home/user` | `~/apps/uniagent/home` （持久化，登录态/配置/代码都在这里） |
| `/opt/ua` | `~/apps/uniagent/tools` （可选工具本体，丢了会自动重装，备份可排除） |
| `/etc/ssh/keys` | `~/apps/uniagent/ssh/keys` （sshd 主机密钥，Teleport 的 CA 和主机证书） |
| `/etc/teleport` | `~/apps/uniagent/teleport/config` （agent 模式的配置，回滚用） |
| `/var/lib/teleport` | `~/apps/uniagent/teleport/data` （agent 的 host UUID，回滚用） |

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

各 CLI 首次使用需自行登录（`claude`、`opencode auth login`、`agy`），
凭据写在 `/home/user` 下，已持久化。SSH 会话里 `agy` 会打印授权 URL，在本地浏览器打开即可。

`codex` 是例外，不需要 `codex login`：预置的 `~/.codex/config.toml` 把它指向容器内的
newapi 网关，key 从 fleetherd 的 `.env` 经 `OPENAI_API_KEY` 注入。
想改回 ChatGPT 订阅登录就删掉那份 config.toml 再 `codex login` —— 但那要交互式浏览器授权，
无头容器里做不了。

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

## Teleport（agentless）

容器里不跑 teleport：它在集群里登记成 agentless（OpenSSH）节点，proxy 直接拨容器的 sshd。
sshd 信任集群的 OpenSSH CA（认用户证书），并出示一张 Teleport 签的主机证书。
不靠反向隧道，所以集群里**每台** proxy 都能直连它（反向隧道只挂在 agent 拨过去的那台 proxy 上，
没有 proxy peering 时别的 proxy 连不到）。

前提：sshd 的发布地址要从每台 proxy 的网络命名空间都连得上，在 proxy 那台机器上看 banner：

```bash
docker run --rm --network container:<proxy 容器> alpine sh -c "timeout 8 nc <内网地址> <端口> </dev/null | head -1"
```

在集群上（能跑 `tctl` 的地方）登记节点、导出 CA、签主机证书：

```bash
UUID=$(cat /proc/sys/kernel/random/uuid)
cat > node.yaml <<EOT
kind: node
version: v2
sub_kind: openssh
metadata:
  name: $UUID
  labels: {env: dev}
spec:
  addr: <内网地址>:<端口>
  hostname: <节点名>
EOT
tctl create -f node.yaml
tctl auth export --type=openssh | sed 's/^cert-authority //' > teleport_openssh_ca.pub
# principals：地址、节点名、UUID。以后可能改名就把新名字也签进去，改名时不用重签
tctl auth sign --host=<内网地址>,<节点名>,$UUID --format=openssh --out=teleport_host_key
```

三个文件放进宿主机的 `ssh/keys/`（`teleport_host_key` 属主 root、600），compose 打开
`20-teleport.conf` 那行挂载，`docker compose up -d`。不想重建容器：把 `20-teleport.conf` 拷进容器的
`/etc/ssh/sshd_config.d/`，`sshd -t` 通过后给 sshd 发 SIGHUP（已建立的连接不断）。

验证：`tsh ssh user@<节点名>`；`tsh ls` 的 Address 列是 `<内网地址>:<端口>`，不再是 `⟵ Tunnel`。
`tctl nodes ls` 里 Version 列为空是正常的（没有 agent）。

- **原主机密钥要排在 Teleport 的前面**（10-direct.conf 先于 20-teleport.conf 加载，已满足）。两把都是
  ed25519，sshd 给不要证书的客户端出示第一把，钉原密钥的客户端看到的指纹不变。
- **钉了原主机密钥的 OpenSSH 客户端**要么排除证书算法（`HostKeyAlgorithms -*-cert-v01@openssh.com`，
  fleetherd 网关和 pod 互通已经这样做），要么在 known_hosts 加 Teleport 主机 CA 的 `@cert-authority` 行。
  否则客户端先要证书，拿到的是 Teleport 那把密钥，没有 CA 可验就拿它去比 known_hosts，报 host key changed。
- 改节点名：`tctl get node/<uuid>` 改 `spec.hostname`，再 `tctl create -f`（新名字要已签在证书里）。

### 回滚到 agent 模式

镜像里仍留着 teleport。compose 加回 `command: ["teleport","start","-c","/etc/teleport/teleport.yaml"]`、
`docker compose up -d`，再 `tctl rm node/<uuid>` 删掉 agentless 那条记录。`teleport/config`、`teleport/data`
别删：host UUID 在里面，回滚不用重新 join。这时 entrypoint 会在后台另起 sshd，钥匙直连不受影响。

新机器第一次以 agent 模式接入：token 在集群上签（`tctl tokens add --type=node --ttl=1h`），ca-pin 可以从
公开的 CA 导出接口自己算（等价于 `tctl status` 里那行）：

```bash
curl -s "https://<proxy>/webapi/auth/export?type=tls-host" \
  | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -hex | awk '{print "sha256:"$NF}'
```

然后在容器里：

```bash
./ua
sudo teleport node configure --silent \
  --output=file:///etc/teleport/teleport.yaml \
  --proxy=<proxy>:443 \
  --token=<join token> \
  --ca-pin=<ca-pin> \
  --labels=env=dev \
  --node-name=uniagent
```

`--output` 是 `file://` + **绝对**路径，且**不覆盖已存在文件**（重生成先 `mv` 走）；
`--node-name`（不是 `--nodename`）**必须全小写**，大写会让原生 `ssh` + ProxyCommand 报
`offline or does not exist`。agent 版本需 ≤ 集群 auth 版本；集群是 v18 时保持 `TELEPORT_CHANNEL=stable/v18`。

## 重建

镜像由 CI 编译发布到 GHCR（`.github/workflows/docker.yml`，amd64 + arm64），**部署侧不 build**：

```bash
uniagent update              # 拉新镜像、重建、清旧镜像；--dry-run 只拉不换，--force 无视占用
```

`update` 比手敲两条命令多做的事，都是踩过才加的：镜像引用从 compose 里读（不写死，钉版本时
跟着变）；比**镜像 ID** 而不是 tag（`latest` 会动，tag 没变不代表镜像没变），没变就一步不走；
重建前列出容器内除守护会话以外的 tmux 会话并拒绝执行，因为重建会把里面跑着的 coding agent
一起杀掉；换容器之前先用新镜像跑一遍 `ua-tools sync`，把新版本的工具预装进 `./tools`（不然新容器
起来后才现装，期间 agent 用不了；预装失败只告警，失败的工具停在原来的版本）；重建后报 fleetherd 的**真实**版本（读已装包的 package.json，见下）和守护状态；
最后清掉被顶替下来的旧镜像（每次 pull 都会留下一个 ~4.5GB 的 dangling 镜像，docker 不回收）
——只按 `org.opencontainers.image.source` 标签清本仓库出的，
不碰宿主上别的服务；镜像没变时也清一遍兜底，`--dry-run` 不清。要回滚就把 compose 的 `image:`
钉到 GHCR 上的 `sha-<短sha>` 再 update，不靠本地留旧镜像。

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

## 常驻服务（ua-service）

容器的主进程是 sshd，没有 systemd。要常驻的服务各写一个定义文件放 `services/<名字>.sh`
（进镜像的 `/usr/local/lib/ua-service/`），由 `ua-service` 保活：退出就重启，跑不满 60 秒按 5→300 秒退避；
日志在 `~/.local/state/ua-service/<名字>/log`，超过 20 MB 轮转一份。entrypoint 在 `ua-tools sync` 之后
跑 `ua-service start-all`，前置文件（配置、二进制）不全的服务直接跳过，所以没配置的机器什么也不会起。

```bash
ua-service status                 # 全部服务
ua-service restart runabout       # 换了二进制或改了配置后
ua-service logs runabout -f
```

### runabout

给 Gemini / ChatGPT / Claude.ai 网页端用的 MCP 工具服务（[noir017/runabout](https://github.com/noir017/runabout)）。
装在这里而不是单独的容器，是为了让它对本机的操作**直接执行**：以前经 ssh + Teleport 进来，并发一高就撞
sshd 的 MaxSessions、证书到期断主连接、Teleport 副 proxy 到 auth 的跨境链路卡住（2026-11-25 排查）。

- 二进制：`ua-tools install runabout`；升级 `ua-tools update runabout && ua-service restart runabout`，不用重建容器。
- 配置：`~/.config/runabout/config.yaml`，机密（`RB_BASE_URL`、上游令牌）在同目录 `.env`（600）。
  `fleet.local_name` 设成这台机器的名字（`uniagent`），客户端原来写的 `target` 不用改；去别的机器走本容器的
  ssh 短名和 Teleport（审批由 `tp-grant-active` 发起）。OAuth 登记和审计日志在 `server.data_dir`。
- 入口：runabout 听 `0.0.0.0:8484`，宿主的 cloudflared 经共享网络 `cloudflared`（容器别名 `runabout`）把
  公网域名转进来。compose 里要把容器挂进这个网络；不想重建就先 `docker network connect --alias runabout cloudflared uniagent`。
- 安全：runabout 的 shell 就是 user，和以前经 ssh 进来的权限一样；但它的令牌也在 user 的家目录里，本机所有
  agent 用 shell 都读得到（文件工具已拉黑这个目录，shell 挡不住）。

## IM 网关（fleetherd）

Telegram 消息 → fleetherd → claude / opencode（ACP），回复流式写回。程序在 `/opt/ua`
（版本钉在镜像里），配置在 `~/.config/fleetherd` —— 这条分界是刻意的：镜像可以随便重建，token 与会话历史不跟着走。

名字沿革：2.0.0 之前叫 agent-anywhere（仓库 noir017/agent-anywhere，配置在 `~/.config/agent-anywhere`），
2.0.0–2.x 叫 talkcode，3.0.0 起叫 fleetherd。3.0.0 仍认旧名：`talkcode` 是 `fleetherd` 的别名命令，
`TALKCODE_*` 环境变量在 `FLEETHERD_*` 未设时仍会读；配置目录 `~/.config/fleetherd` 不存在而
`~/.config/talkcode` 存在时沿用后者（daemon 日志里记一条），**不自动搬** —— 容器里它是 bind mount。
agent-anywhere 的配置仍会在第一次起容器时被**复制**到当前配置目录（entrypoint 调
`fleetherd-daemon.sh migrate-from-agent-anywhere`；旧的原样留着，换回旧镜像照样能跑），
新目录已存在就什么都不做。`ua-tools install talkcode` 也照旧可用，按 `fleetherd` 处理。
改名前的 `/opt/ua/talkcode` 不再被 ua-tools 管理，确认没有进程还在用它之后可以删掉。

| 东西 | 位置 | 进镜像？ |
|---|---|---|
| 程序 | `/usr/local/bin/fleetherd` → `/opt/ua/fleetherd/current` | ❌ 持久卷，版本钉在镜像里 |
| 守护脚本 | `/usr/local/bin/fleetherd-daemon.sh` | ✅ |
| 配置 | `~/.config/fleetherd/config.yaml` | ❌ 挂载 |
| token | `~/.config/fleetherd/.env`（chmod 600） | ❌ 挂载 |
| 会话绑定 | `~/.config/fleetherd/conversations.json` | ❌ 挂载 |
| 日志 | `~/.config/fleetherd/daemon.log` | ❌ 挂载 |

容器里没有 systemd（PID 1 是 tini，主进程是 sshd），所以守护由 `fleetherd-daemon.sh` 顶上：跑在
独立 tmux 会话里，挂了自动重启，5s→300s 指数退避（跑满 60s 才算健康并重置退避，免得
配置错误时空转刷 Telegram API）。entrypoint 在 `config.yaml` 存在时自动 `start`，
所以**没配过的机器不会 crash-loop**。

```bash
bash /usr/local/bin/fleetherd-daemon.sh status   # 状态
bash /usr/local/bin/fleetherd-daemon.sh stop     # 改完配置重启用
bash /usr/local/bin/fleetherd-daemon.sh start
tail -f ~/.config/fleetherd/daemon.log           # 日志
tmux attach -t fleetherd-daemon                  # 贴现场
```

**升级**：镜像侧是自动的。fleetherd 仓库发出新 Release 之后，
`.github/workflows/bump-fleetherd.yml`（每天一次，也可在 Actions 页手动 Run workflow）
会查到它、从 Release 自带的 `SHA256SUMS` 取校验和、改掉 Dockerfile 里
`FLEETHERD_VERSION` 与 `FLEETHERD_SHA256` 两个 ARG 并提交，然后复用 docker.yml
把镜像推到 GHCR。镜像里只换了版本钉子，新版本由 `uniagent update` 预装、或容器启动时 `ua-tools sync` 装进持久卷。

**机器侧不自动**：镜像出来之后仍然要自己 `uniagent update`（见「重建」）。重建会杀掉容器里
正在跑的东西，那个时机不该由定时任务替人决定。

要钉某个版本（回退，或抢在定时之前升）：Actions → Bump fleetherd → Run workflow，
填版本号。定时那条路**只升不降**（Release 被撤回时不会把线上悄悄退回去）；填了版本号的
手动那条路可以降。直接手改两个 ARG 再推 main 当然也照样有效，自动流程只是省掉抄校验和。

> `--version` 在 1.1.0 之前（当时还叫 talkcode）打印的是 cli.ts 里硬编码的 `0.2.0`；1.1.0 起
> （2026-09-05）读 package.json，已经可信。验收仍以已装包的 package.json 为准，它不依赖 CLI 能跑起来：
> `node -p "require('/opt/ua/fleetherd/current/lib/node_modules/fleetherd/package.json').version"`

> ⚠️ 别在 `~/.local` 里再装一份：`$HOME/.local/bin` 在 PATH 里排在 `/usr/bin` 前面，
> 手敲 `fleetherd` 会命中它，而守护进程走的是绝对路径 `/usr/local/bin/fleetherd`，
> 两边会静默跑成不同版本。真要临时试私有构建，用
> `FLEETHERD_BIN=~/.local/bin/fleetherd bash /usr/local/bin/fleetherd-daemon.sh start`。

### 网关在另一个容器里时（2.9.0 起）

fleetherd 可以跑在自己的容器（`ghcr.io/noir017/fleetherd`）里，把这台当成[远程主机](https://github.com/noir017/fleetherd/blob/main/docs/remote-hosts.md)：
经 ssh 连进来，自己装一个小服务（`~/.fleetherd/remote/`），由它起 agent。这时内置网关不该再跑——
把 `~/.config/fleetherd/config.yaml` 挪走，entrypoint 就不起它。3.0.0 首次连上一台主机时，网关把
`~/.talkcode` 移成 `~/.fleetherd`，并留一个 `~/.talkcode -> .fleetherd` 软链。为此镜像做了三件事：

- **`claude-agent-acp` 在 PATH 上**（`/usr/local/bin`，链到 fleetherd 自带的那份，版本跟 fleetherd 走）。
  远程 cc 在主机的 PATH 上找它。
- **登录环境补齐**：远程 agent 的环境是 `bash -i -l` 的登录环境，sshd 起的会话看不到 Dockerfile 的
  `ENV`，也不经过 `fleetherd-daemon.sh`。所以 `CLAUDE_CODE_EXECUTABLE` 写进
  `/etc/profile.d/20-claude-code.sh`，`LANG`/`LC_ALL` 写进 `05-locale.sh`。模型 key 本来就在 `~/.bashrc`。
- **终端 socket 可挪位置**：`UNIAGENT_WEB_TERMINAL_SOCK` 把 ttyd 的 socket 放进两个容器都挂了的目录；
  网关容器必须也以 uid 1001 运行（socket 是 0600）。

⚠️ 这种部署下别跑 `fleetherd-daemon.sh stop`：它按名字 `pkill claude-agent-acp`，会把网关远程起的 agent 一起杀掉。

### webui 的终端面板（ttyd，默认不开）

打开之后，webui 顶栏多一个 `>_` 按钮，把聊天记录换成容器里的一个真终端——于是任何 coding
agent 的 CLI，连同它的全屏 TUI，都能在同一个页面里直接跑。每个 topic 一个终端。

**为什么 PTY 在这边而不在 fleetherd 里。** fleetherd 只做一层过 session cookie
的反向代理，一个 npm 依赖都没加。它自己实现的话要引 node-pty（它的 tarball 里只有 darwin
和 win32 的 prebuild，**Linux 一个都没有**，等于所有 Linux 安装都要现场编译）、xterm.js、
WebSocket 服务端，外加 scrollback / resize / 重连 / 手机软键盘。ttyd 是 1.3MB 静态二进制，
这些连同 CJK 与 IME 支持全都现成。

**两个开关，都要打开**，因为它们回答的是两个问题：

```yaml
# ① ~/.config/fleetherd/config.yaml —— 页面上要不要有那个按钮
platforms:
  web:
    type: webui
    terminal:
      enabled: true
      socket: /home/user/.config/fleetherd/webui-term.sock   # 必须和 ② 一致
      # 窗口右上角的「关闭」（1.26.0 起）。不配就只有最小化，没有关闭
      # 按钮 —— daemon 不知道后端是 tmux，也不该知道，所以「怎么结束一个会话」只能由
      # 这边说。必须和 aa-terminal.sh 里的 -L aa-web / aa-<topic> 对上。
      endCommand: ["tmux", "-L", "aa-web", "kill-session", "-t", "aa-{topic}"]
```

```yaml
# ② docker-compose.yml —— 容器里要不要真的跑起那个 shell 服务
environment:
  - UNIAGENT_WEB_TERMINAL=1
```

只开 ① 不会静默失败：按钮在、后端没起，代理明确回 502「terminal backend is not running」。

终端是**每个话题一个窗口**：最小化只收起窗口，iframe 还挂着、连接不断，tmux 里跑的东西
照常跑，话题列表上那个 `>_` 标记也还亮着；关闭才会跑 `endCommand` 真的 kill 掉会话。那个
标记数的是「有页面连着」，不是「tmux 里有东西在跑」—— 关掉所有标签页，标记全灭，会话照跑。

**组成**

| 东西 | 干什么 |
|---|---|
| `/usr/local/bin/ttyd` | 1.7.7 静态二进制，逐架构校验 sha256 装进镜像。听 unix socket，不占端口 |
| `/usr/local/bin/aa-terminal.sh` | ttyd 跑的命令。校验 topic id，然后 `tmux -L aa-web new -A -s aa-<topic>` |
| `/usr/local/etc/aa-terminal.tmux.conf` | 那台 tmux server 的配置：关状态栏、开鼠标、50000 行回滚 |
| `~/.config/fleetherd/webui-term.sock` | 后端入口。entrypoint 起完收紧到 0600 |
| `~/.config/fleetherd/ttyd.log` | ttyd 自己的日志 |

**安全边界**

- socket 不是端口，网络上根本够不着 —— 所以 fleetherd 那道 session 检查是唯一入口，
  不是两个入口之一。entrypoint 会把它 chmod 到 0600，否则同机其他用户能直连、绕开登录。
- 浏览器传进来的 `?arg=<topic>` 最终是要进 exec 的，两边各校验一次：代理比对 topic 表，
  wrapper 再比对 `^[0-9a-f]{8}$`。
- **打开它等于把容器 shell 挂在 webui 的 token 后面。** 权限上限没变（智能体本来就是全工具
  权限），但从 token 泄漏到任意命令的距离短得多。默认关就是这个原因。

**坑**

- **tmux 必须是独立 server（`-L aa-web`）。** fleetherd 守护进程自己就跑在默认 server
  的 `fleetherd-daemon` 会话里，conf 里任何一条 `set -g` 都会串过去。已验证隔离：
  `tmux show -gv status` 仍是 `on`，`tmux -L aa-web show -gv status` 是 `off`。
- **不能不套 tmux。** ttyd 每个 WebSocket 连接 fork 一个新进程，断开就 SIGHUP —— 手机切一下
  后台回来，正在跑的 agent 就没了。套上之后断线只是重绘。
- **面板一片空白但连接是通的，先怀疑渲染器。** ttyd 默认用 xterm 的 WebGL 后端，在没有 GPU 的
  无头 Chromium 下一个像素都不画（本功能验收时就这么误判过一次：内容其实在，`tmux display`
  报的窗口是正常的 46×51，只是没画出来）。加 `-t rendererType=dom` 试。
- **升级 ttyd 要同时改 Dockerfile 里 `TTYD_VERSION` 和两个 `TTYD_SHA256_*`**，否则构建当场
  失败 —— 这是故意的，好过悄悄装上一个没人核对过的二进制。

## sshd：容器唯一的 ssh 入口

Teleport（agentless，见上）和钥匙直连（fleetherd 网关、pod 互通、别的机器）都进这一个 sshd。
钥匙直连不经 proxy，机器之间频繁新建 ssh 时不受跨洋延迟和丢包拖累。

- `Dockerfile` 第 9 段装 `openssh-server`。**刻意放在最后一层** —— 加进第 1 段的 apt
  会让后面几层（Node / Python / 各 AI CLI）全部缓存失效，重建要几十分钟。
- 镜像默认 CMD 是 `sshd -D -e`：sshd 是主进程，挂了容器跟着按 restart 策略重启，日志在 `docker logs`。
  compose 把 command 换成别的（比如回滚到 agent 模式）时，entrypoint 在后台另起 sshd，失败只警告。
- `ssh/sshd_config.d/10-direct.conf` → 挂到 `/etc/ssh/sshd_config.d/`，接 Teleport 时再挂 `20-teleport.conf`。
  属主必须 root（sshd 拒绝加载属主不对的 include）。
- `ssh/keys/` → 挂到 `/etc/ssh/keys`，**可写**。主机密钥在这里持久化，首次启动由
  entrypoint 生成，重建镜像不换指纹；Teleport 的 CA、主机密钥和证书也放这里。
- 默认不发布端口。要用时在 compose 里加 `ports: ["<内网地址>:22022:22"]`，
  公钥放进 `home/.ssh/authorized_keys`（1001:1001，600）。

### 安全边界

钥匙直连**没有** Teleport 的角色门禁、会话录制、证书过期。补偿手段：

- 端口只绑内网地址，并**确认该端口不在云安全组对公网放通的范围里**。云主机的公网 IP 常是到
  内网地址的 1:1 NAT，目的地址区分不了来源，能不能被公网访问完全取决于安全组。
- 只认公钥、只允许 `user`、`PermitRootLogin no`；`AllowAgentForwarding` / `PermitTunnel` /
  `GatewayPorts` / `X11Forwarding` 全 no。`AllowTcpForwarding yes`，但只对没带 `restrict` 的钥匙生效——
  也就是只有 fleetherd pod 互通的钥匙（`~/.fleetherd/ssh/authorized_keys`，限私网来源）；
  `~/.ssh/authorized_keys` 里的每一把都带 `restrict`，新加的也要带，否则这把钥匙等于一条进内网的隧道。

### fleetherd pod 互通（2026-11-03 起）

pod.yaml（`~/.fleetherd/pod.yaml`）里写了 `peer:` 的机器，由 fleetherd 网关在 `~/.fleetherd/ssh/` 写好
其他 pod 的钥匙、主机公钥和 `Host <主机>.pod` 配置，于是 `ssh <主机>.pod`（scp、rsync、git、-L/-R）直接可用。
镜像为此做了两件事：sshd 的 `AuthorizedKeysFile` 同时列出 `.fleetherd/ssh/authorized_keys` 和
`.talkcode/ssh/authorized_keys`（`ssh/sshd_config.d/10-direct.conf`），ssh 客户端经
`/etc/ssh/ssh_config.d/20-fleetherd-pods.conf` 读两份 config（新的在前）。不碰 `~/.ssh`。
说明见 fleetherd 的 [docs/remote-hosts.md](https://github.com/noir017/fleetherd/blob/main/docs/remote-hosts.md#pod-to-pod-ssh-peer)。

### 坑

- **DNAT 在 PREROUTING 完成，filter 表看到的目的端口已经是容器端口。** 按宿主机端口写的
  `DOCKER-USER` 规则**永远匹配不到**，要按 DNAT **之后**的形态匹配（`--dport 22` +
  容器网段/网卡）。写完看一眼计数器，恒为 0 就等于没有。
- **authorized_keys 别用 `printf '%s\n' "a\nb"` 写** ——`\n` 在 `%s` 里是字面量，
  整个文件会挤成一行，表现是 `Permission denied (publickey)`。用 heredoc。

撤销：删掉 `authorized_keys`（sshd 每次认证都重读，不用重启容器），再去掉 compose 里的
`ports` 段 `docker compose up -d`。

## License

GNU Affero General Public License v3.0 (AGPL-3.0). See [LICENSE](LICENSE).
