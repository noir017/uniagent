#!/usr/bin/env bash
# 进入 uniagent 容器（以 user 身份、登录 shell）
# 用法：  ua              -> 交互 shell
#         ua claude       -> 直接跑命令（无 TTY 时自动降级，可用于脚本/管道）
set -euo pipefail

FLAGS=(-i)
[ -t 0 ] && [ -t 1 ] && FLAGS=(-i -t)

if [ "$#" -eq 0 ]; then
    exec docker exec "${FLAGS[@]}" -u user -w /home/user uniagent bash -l
else
    exec docker exec "${FLAGS[@]}" -u user -w /home/user uniagent bash -lc "$(printf '%q ' "$@")"
fi
