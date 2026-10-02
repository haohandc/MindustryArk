#!/bin/bash
# 在设备上安装 STORE-CONFIGURATION 包，并收集它输出的信息。
#
# 为什么这不是 deploy.sh
#   deploy.sh 拒绝安装任何未通过 verify_hap.py 的产物，而这道门禁
#   在本包上是故意失败的：verify_hap.py 校验 DEBUG buildMode 的
#   原生字节，而商店配置会把它剥掉。见
#   RELEASE-MAINTENANCE.md 2.2 -- 这个 FAIL 说明门禁在正常工作，不是过期的校验值，
#   也正是此前从没人跑过这套配置的原因。
#
#   所以本脚本做安装和日志收集，跳过门禁。
#   其他一概不跳：它会检查安装和启动确实
#   报告了成功，因为 "日志是空的" 会被读成 "它崩了"，
#   正是 deploy.sh 当初要避免的同一个错误。
#
# 用途
#   复现应用市场评论里的"游戏闪退"，评论者在
#   Mate 60 上用商店包遇到的。为此构建的包是
#   product=default + buildMode=release：变量完全相同（release buildMode、
#   剥离的原生库），但用 debug 证书签名，因此可以
#   侧载。用以下命令构建：
#
#     bash build.sh assembleHap --mode module -p product=default -p buildMode=release
#
# 用法：
#   bash scripts/install_repro.sh                  # 单个设备，或 ARK_HDC_TARGET
#   ARK_HDC_TARGET=<id> bash scripts/install_repro.sh
#
# ⚠️ 它会先跑 `uninstall`，这会清空应用沙箱（存档，以及
#    Download 目录的授权）。运行前请先导出存档。

set -o pipefail
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1

BUNDLE="com.haohandc.arklauncher"
ABILITY="EntryAbility"
STUDIO="${ARK_DEVECO_STUDIO:-E:/Program Files/DevEco Studio}"
SDK_HOME="${DEVECO_SDK_HOME:-$STUDIO/sdk}"
HDC=("$SDK_HOME/default/openharmony/toolchains/hdc.exe")
PY=("${ARK_PYTHON:-python}")

[ -f "${HDC[0]}" ] || { echo "!! hdc not found: ${HDC[0]}" >&2; exit 1; }

# ---- 哪个设备（与 deploy.sh 同规则：绝不猜） --------------------
HDC_TARGET="${ARK_HDC_TARGET:-}"
if [ -z "$HDC_TARGET" ]; then
    TARGETS="$("${HDC[@]}" list targets 2>/dev/null | tr -d '\r' \
               | grep -v '^\[Empty\]$' | grep -v '^[[:space:]]*$')"
    TARGET_N="$(printf '%s\n' "$TARGETS" | grep -c .)"
    if [ "$TARGET_N" -eq 0 ]; then
        echo "!! no device attached -- check the cable, then 'hdc list targets'" >&2
        exit 1
    elif [ "$TARGET_N" -gt 1 ]; then
        echo "!! $TARGET_N devices attached, and this script will not guess:" >&2
        printf '     %s\n' $TARGETS >&2
        echo "!! choose one:   ARK_HDC_TARGET=<id> bash scripts/install_repro.sh" >&2
        exit 1
    fi
    HDC_TARGET="$TARGETS"
fi
hdc() { "${HDC[@]}" -t "$HDC_TARGET" "$@"; }
echo "device: $HDC_TARGET"

HAP_BASE="$("${PY[@]}" -c 'import sys; sys.path.insert(0,"scripts"); import config; sys.stdout.write(config.ARTIFACT_NAME)')" || exit 1
SIGNED="entry/build/default/outputs/default/$HAP_BASE.hap"
[ -f "$SIGNED" ] || { echo "!! no signed HAP at $SIGNED" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 拒绝过期产物
#
# 本脚本安装的是预构建 HAP -- 它不构建。这是
# 刻意的（这是安装商店配置包的唯一方式，而
# verify_hap.py 按设计会拒绝它），但这意味着最后一次构建之后的改动
# 会被静默地不测试：应用照常安装、启动，行为与
# 旧代码完全一样，读起来就是 "我的改动没起作用"。
#
# 实测过，代价是一轮返工：Index.ets 改于 11:56，而磁盘上的 HAP
# 是 11:51 的，所以被测的 "新" 构建已经旧了五分钟，
# 那条本可证明新代码跑过的日志行根本不存在。
# 于是 "没有证据" 被误当成了关于代码的证据。
#
# 与本项目已有的规则同形：一个不会因产物过期而
# 报错的部署步骤，会把上一次的构建当成这一次交给你。
# ---------------------------------------------------------------------------
STALE=""
for src in entry/src/main/ets/pages/Index.ets entry/src/main/cpp/launcher.c \
           entry/src/main/module.json5 entry/src/main/ets/entryability/EntryAbility.ets; do
    [ -f "$src" ] || continue
    if [ "$src" -nt "$SIGNED" ]; then STALE="$STALE
       $src"; fi
done
if [ -n "$STALE" ]; then
    echo "!! this script does not build, and the package is OLDER than:" >&2
    printf '%s\n' "$STALE" >&2
    echo "!!" >&2
    echo "!! build first, or you will be testing the previous package:" >&2
    echo "!!   bash build.sh assembleHap --mode module -p product=default -p buildMode=release" >&2
    exit 1
fi

echo
echo "===== packaged as ====="
"${PY[@]}" - "$SIGNED" <<'EOF'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
v = json.loads(z.read("pack.info").decode())["summary"]["app"]["version"]
j = z.read("libs/arm64-v8a/jdk21/lib/server/libjvm_real.so")
print("  versionName %s  versionCode %s" % (v["name"], v["code"]))
print("  libjvm_real %d B   .symtab=%s   <- stripped means store configuration"
      % (len(j), b".symtab" in j))
EOF

echo
echo "===== install ====="
hdc uninstall "$BUNDLE" >/dev/null 2>&1
INSTALL_OUT="$(hdc install -r "$SIGNED" 2>&1)"
printf '%s\n' "$INSTALL_OUT" | tail -3
printf '%s' "$INSTALL_OUT" | grep -q "install bundle successfully" || {
    echo "!! install did not report success -- refusing to launch" >&2; exit 1; }

echo
echo "===== launch + wait 30 s ====="
hdc shell hilog -r >/dev/null 2>&1
hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1
sleep 2
START_OUT="$(hdc shell "aa start -a $ABILITY -b $BUNDLE" 2>&1)"
printf '%s\n' "$START_OUT" | tail -2
LAUNCHED=1
if ! printf '%s' "$START_OUT" | grep -q "start ability successfully"; then
    LAUNCHED=0
    echo "!! launch did not report success -- logs below will be empty" >&2
    # 设备点明了原因时就写出来。锁屏会产生
    # 10106102，且完全没有崩溃日志，否则会被读成 "它在
    # 启动时崩了" -- 一个完全不同的问题，会被
    # 翻遍应用代码去追查，直到有人注意到平板
    # 是在休眠。
    if printf '%s' "$START_OUT" | grep -q "10106102"; then
        echo "!! the screen is locked (10106102). Unlock the device and run again --" >&2
        echo "!! nothing was tested. 'power-shell wakeup' can wake it but not unlock it." >&2
    fi
fi
sleep 30

echo
echo "===== is it still running? ====="
PID="$(hdc shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r')"
if [ "$LAUNCHED" -eq 0 ]; then
    echo "  N/A  the app never started, so this says nothing about the app"
elif [ -n "$PID" ]; then
    echo "  YES  pid=$PID   <- it did NOT crash on launch"
else
    echo "  NO   process is gone  <- it crashed, or exited"
fi

echo
echo "===== the launcher's own stderr.log ====="
hdc shell "cat /data/app/el2/100/base/$BUNDLE/files/stderr.log 2>/dev/null" || true
echo
echo "===== the launcher's own crash.txt ====="
hdc shell "cat /data/app/el2/100/base/$BUNDLE/files/crash.txt 2>/dev/null" || true

# faultlog 是那些从未到达我们处理器的故障的归宿。
# 即使同一目录上的 `ls` 被拒绝，`hdc file recv` 仍能读到它。
echo
echo "===== faultlog (pulled, not printed) ====="
OUT_DIR="_faultlog_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
for d in /data/log/faultlog/faultlogger /data/log/faultlog/temp; do
    hdc file recv "$d" "$OUT_DIR" 2>&1 | tail -2
done
echo "  -> $OUT_DIR"
ls -la "$OUT_DIR" 2>/dev/null | tail -12
echo
echo "give the whole $OUT_DIR directory back, plus the two logs above."
