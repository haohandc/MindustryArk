#!/bin/bash
# 从 git-bash 跑 hvigor 构建。
#
# 为什么要这个脚本：hvigorw.bat 的路径含空格，git-bash 里直接调会被引号问题坑
# （这项目里已经因为"路径含空格"栽过好几次）。这里改成直接调 node + hvigorw.js，
# 并用【数组】传参 —— 数组是 bash 处理含空格路径唯一可靠的方式。
#
# 用法:
#   bash build.sh assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
set -o pipefail

cd "$(dirname "$0")" || exit 1

export DEVECO_SDK_HOME="E:/Program Files/DevEco Studio/sdk"

NODE=("E:/Program Files/DevEco Studio/tools/node/node.exe")
HVI=("E:/Program Files/DevEco Studio/tools/hvigor/bin/hvigorw.js")

if [ ! -f "${NODE[0]}" ]; then echo "找不到 node: ${NODE[0]}" >&2; exit 1; fi
if [ ! -f "${HVI[0]}" ]; then echo "找不到 hvigorw.js: ${HVI[0]}" >&2; exit 1; fi

exec "${NODE[@]}" "${HVI[@]}" "$@"
