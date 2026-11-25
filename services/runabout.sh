# runabout：给 Gemini / ChatGPT / Claude.ai 网页端用的 MCP 工具服务（github.com/noir017/runabout）。
# 本机直接执行（fleet.local_name 设成这台机器的名字），去其它机器走本容器的 ssh 短名和 Teleport。
#
# 配置 ~/.config/runabout/config.yaml，机密（RB_BASE_URL、上游令牌）放同目录 .env（600）；
# 状态（OAuth 登记、审计日志）在 config.yaml 的 server.data_dir。没有 config.yaml 就不启动。
# 二进制由 `ua-tools install runabout` 装；升级：ua-tools update runabout && ua-service restart runabout
SVC_CMD=(/opt/ua/runabout/current/bin/runabout serve -c "${HOME}/.config/runabout/config.yaml")
SVC_REQUIRE=("${HOME}/.config/runabout/config.yaml" /opt/ua/runabout/current/bin/runabout)
SVC_ENV_FILE="${HOME}/.config/runabout/.env"
SVC_WORKDIR="${HOME}/workspace"
