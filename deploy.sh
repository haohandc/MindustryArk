#!/bin/bash
# 构建 -> 校验 -> 安装 -> 启动 -> 收集日志
#
# 为什么这是一个脚本，而不是三条手敲的命令
#   这里每一步都有存在的理由：曾经跳过其中一步，得到的错误结果
#   看着像代码问题。串成一条链，就不会被漏掉。
#
# 这里安装的是 *你自己* 的构建，用 *你自己的* 证书签名
#   安装的 HAP 由 DevEco 用自动生成的调试配置文件签名。
#   调试配置文件会列出它适用的设备 UDID（最多 100 个，
#   注册于 AppGallery Connect）。所以这个构建只在 UDID
#   在该配置文件中的机器上生效，别的机器都不行 —— 这没问题，
#   因为这里是本地开发循环，也正是因此，签名后的 HAP
#   不是能交给别人的东西。
#   该分发什么，见 RELEASE.md。
#
# 不再做 ACL 重签名
#   以前会用 AGC 的特殊配置文件给 HAP 重签名，因为
#   module.json5 申请了受限权限
#   ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY，而普通
#   配置文件给不了 —— 安装会失败并报
#   "install failed due to grant request permissions failed"。
#
#   该权限后来已被移除，并验证过确实不必要 —— 仅限
#   本地开发循环。没有它游戏也能跑到主菜单。JDK 放在
#   HAP 自己的 lib 目录里，那里本来就是可执行的，而沙箱只
#   存放数据（模块镜像由 java.base 当普通文件打开）。
#
#   ⚠️ "运行时的可执行内存来自匿名映射，本平台无论如何都允许"
#   这句话在本机上是成立的，并且是实测出来的。
#   但它并非普遍成立。2026-09-22 在一台 HarmonyOS 6.1.1
#   （API 24）设备上实测，运行的是 AppGallery 包：
#
#       !! mmap(RWX) FAILED: errno=22 (Invalid argument)
#
#   没有匿名可执行内存，JVM 的 JIT 就无法启动，
#   进程会死在 JNI_CreateJavaVM 里面。这就是商店审核员
#   反馈的 "启动即闪退"。我们在这里移除的那个权限，
#   ALLOW_WRITABLE_CODE_MEMORY，正是为此存在 —— 我们自己的
#   launcher.c 里写着 "the permission covers anonymous executable memory only"。
#
#   本地构建之所以不同，是因为它是 DEBUG 签名的，而这台
#   机器是 HarmonyOS 7。决定因素到底是签名还是
#   平台版本，目前还没有分离开 —— 见 RELEASE-MAINTENANCE.md 2.11。
#   对商店版构建来说上面的顾虑不成立（ACL 签名的商店
#   包本来就不是用来侧载的），所以申请它是候选方案。
#
#   ⚠️ 上面说的只是一个权限。本应用声明的另一个权限，
#   ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY，确实必须走
#   ACL 流程 —— 但仅限 AppGallery 上传，而本脚本不做这件事。
#   调试配置文件不走那种检查，所以这里没有任何变化。
#   见 docs/BUILDING.md 的 'ACL (restricted permissions)'。
#
#   所以 build-profile.json5 里的普通签名配置就够了，本脚本
#   安装的就是 hvigor 签出来的东西。配置只需设置一次：
#   DevEco: File -> Project Structure -> Signing Configs -> Automatically
#   generate signature.
#
# 路径
#   ARK_DEVECO_STUDIO、DEVECO_SDK_HOME、ARK_PYTHON —— 见 build.sh 和
#   scripts/config.py。这里不再固定绑定到某一台机器。
#
# 用法：
#   bash deploy.sh              # 构建 + 校验 + 安装 + 启动 + 日志
#   bash deploy.sh --no-build   # 复用已有的 HAP

set -o pipefail
cd "$(dirname "$0")" || exit 1

export MSYS_NO_PATHCONV=1

# Bundle 名也在 scripts/config.py 里；两处要保持一致。
BUNDLE="com.haohandc.arklauncher"
ABILITY="EntryAbility"

STUDIO="${ARK_DEVECO_STUDIO:-E:/Program Files/DevEco Studio}"
SDK_HOME="${DEVECO_SDK_HOME:-$STUDIO/sdk}"

# 用数组，理由见 build.sh 里的说明：这些路径含空格。
HDC=("$SDK_HOME/default/openharmony/toolchains/hdc.exe")
PY=("${ARK_PYTHON:-python}")

# ---------------------------------------------------------------------------
# 选哪台设备
#
# 裸的 `hdc` 调用在连着多台设备时会自己挑一台，而本脚本
# 会执行 `uninstall` —— 所以猜错就会抹掉一台设备上
# 本不该动的存档数据。因此目标设备只在这里解析一次，下面
# 每次调用都经过 hdc()，由它显式声明目标。
#
# 只连一台设备时行为不变。有多台或一台都没有时，脚本会停下，
# 列出它能看到的设备，而不是替你猜。
#
# 可用 ARK_HDC_TARGET=<id from 'hdc list targets'> 覆盖。
# ---------------------------------------------------------------------------
HDC_TARGET="${ARK_HDC_TARGET:-}"
if [ -z "$HDC_TARGET" ]; then
    # 工具必须在被使用之前检查，而不是之后。
    #
    # 下面这行的 `2>/dev/null` 会让 "hdc 跑不起来" 和 "hdc 跑了
    # 但什么都没看到" 都变成空输出 —— 而空输出对应的是
    # 无设备分支，它的提示会让人去查一根根本不是问题所在的
    # 数据线。对这个文件的检查本来就有，但位置更靠后，
    # 所以先出现的是那条误导性提示。把 HDC 指向一个不存在的
    # 路径就能复现。
    [ -f "${HDC[0]}" ] || {
        echo "!! hdc not found: ${HDC[0]}" >&2
        echo "!! set ARK_DEVECO_STUDIO, or DEVECO_SDK_HOME, to the right SDK" >&2
        exit 1
    }
    TARGETS="$("${HDC[@]}" list targets 2>/dev/null | tr -d '\r' \
               | grep -v '^\[Empty\]$' | grep -v '^[[:space:]]*$')"
    TARGET_N="$(printf '%s\n' "$TARGETS" | grep -c .)"
    if [ "$TARGET_N" -eq 0 ]; then
        echo "!! no device attached -- check the cable, then 'hdc list targets'" >&2
        exit 1
    elif [ "$TARGET_N" -gt 1 ]; then
        echo "!! $TARGET_N devices attached, and this script will not guess:" >&2
        printf '     %s\n' $TARGETS >&2
        echo "!! it runs 'uninstall', so picking wrong wipes the wrong device's data." >&2
        echo "!! choose one:   ARK_HDC_TARGET=<id> bash deploy.sh" >&2
        exit 1
    fi
    HDC_TARGET="$TARGETS"
fi
echo "device: $HDC_TARGET"

# 每次设备调用都经过这里，目标设备只声明一次。
hdc() { "${HDC[@]}" -t "$HDC_TARGET" "$@"; }


OUT_DIR="entry/build/default/outputs/default"
# 与 entry/build-profile.json5 里的 targets[].output.artifactName 对应 ——
# 两处要一起改，还要带上 AppScope/app.json5 里的 versionName。
# verify_hap.py 会检查这三者是否一致。
#
# 注意这个不对称，这是 hvigor 的行为，不是这里的笔误：当
# artifactName 为 X 时，它写出签名的 X.hap 和未签名的 X-unsigned.hap。
# 实测 —— 默认的 entry-default-signed.hap 这个名字之所以出现，
# 只是因为默认的 artifactName 里不带版本号。
#
# 签名版只给本机用（见本文件开头），它不是发布产物。
# 实际发布出去的是未签名 HAP，外加 payload
# zip —— 见 RELEASE.md。
for f in "${HDC[0]}"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
command -v "${PY[0]}" >/dev/null 2>&1 || [ -f "${PY[0]}" ] || {
    echo "python not found: ${PY[0]} (set ARK_PYTHON)" >&2; exit 1; }

# HAP 的名字是问出来的，不是在这里写死的。
#
# 它以前是版本号的第四份手工维护副本，结果正如预料地过期了：
# 在 v0.1.0-beta1 -> v0.2.0-beta.1 这次升级时，这一行没被改，
# 于是脚本去找一个已经不存在的文件，并停在
# "no unsigned hap"。verify_hap.py 的文档字符串早就把这个文件
# 列为携带版本号的位置之一，但从来没人检查过它。
#
# scripts/config.py 能推导出这个名字（ARTIFACT_NAME），在这里推导
# 等于去掉那份副本，而不用靠记性去更新它。`|| exit` 和空值检查
# 都是关键：HAP_BASE 为空会让脚本去找
# "-unsigned.hap"，那看起来像缺构建，而不是这里的这个失败。
HAP_BASE="$("${PY[@]}" -c 'import sys; sys.path.insert(0, "scripts"); import config; sys.stdout.write(config.ARTIFACT_NAME)')" || exit 1
[ -n "$HAP_BASE" ] || {
    echo "!! could not read ARTIFACT_NAME from scripts/config.py" >&2; exit 1; }
UNSIGNED="$OUT_DIR/$HAP_BASE-unsigned.hap"
SIGNED="$OUT_DIR/$HAP_BASE.hap"

if [ "$1" != "--no-build" ]; then
    echo "############ 0/4 check inputs ############"
    # 代价很低，却能把 "构建跑到 25 分钟才发现少了一个输入" 变成
    # 立即抛出的、指名道姓的失败。
    "${PY[@]}" scripts/config.py | sed 's/^/  /'

    echo
    echo "############ 1/4 build ############"

    # 闸门：hvigor 的原生步骤即使判定 CMake 输出是最新的，也照样
    # 报成功，而它确实这么干过：某个源文件比 .o 还新，
    # 于是那次改动悄悄没进二进制，
    # 设备一直跑着上一次的构建。这种故障模式从外面看不出来：
    # 构建显示 SUCCESSFUL，设备上的日志看起来像
    # 一次全新运行。我们自己比较时间戳，过期就强制重建。
    OBJ="entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libmain.so"
    STALE=""
    if [ -f "$OBJ" ]; then
        for src in entry/src/main/cpp/*.c entry/src/main/cpp/*.h; do
            [ -f "$src" ] || continue
            [ "$src" -nt "$OBJ" ] && STALE="$src"
        done
    else
        STALE="(no previous object)"
    fi
    if [ -n "$STALE" ]; then
        echo "!! native object is older than $STALE"
        echo "!! forcing a clean native rebuild"
        rm -rf entry/build/default/intermediates/cmake/default/obj
    fi

    # 先删掉之前的包。否则构建失败会留下旧的
    # HAP，后面每一步都基于它成功，设备就悄悄拿到
    # 了上一次的构建 —— 这正是这里发生过两次的事。
    # "文件在那" 并不能证明它就是这次构建的文件。
    rm -f "$UNSIGNED" "$SIGNED"

    # 不加 "|| true"，也不用 grep 绕掉退出码：构建失败就停。
    # 吞掉状态码，正是 launcher.c 里 3 个编译错误没被发现的
    # 原因 —— 部署还报成功，并安装了过期的 HAP。
    build_log="$(mktemp)"
    if ! ./build.sh assembleHap >"$build_log" 2>&1; then
        echo "!! BUILD FAILED -- showing errors" >&2
        grep -Ei "error|Error Message" "$build_log" | head -20 >&2
        rm -f "$build_log"
        exit 1
    fi
    grep -Ei "BUILD (SUCCESSFUL|FAILED)|tasks in total" "$build_log"
    grep -Ei "\berror\b" "$build_log" | head -20
    rm -f "$build_log"

    [ -f "$UNSIGNED" ] || {
        echo "no unsigned hap at $UNSIGNED" >&2
        echo "if the name changed, check artifactName in entry/build-profile.json5" >&2
        exit 1
    }

    # 同一道闸门的事后检查：证明产物现在确实比源文件新
    if [ -f "$OBJ" ]; then
        for src in entry/src/main/cpp/*.c entry/src/main/cpp/*.h; do
            [ -f "$src" ] || continue
            if [ "$src" -nt "$OBJ" ]; then
                echo "!! STILL STALE after build: $src is newer than $OBJ" >&2
                exit 1
            fi
        done
        echo "native artifact is up to date with sources"
    fi
fi

echo
echo "############ 2/4 verify packaging ############"
PYTHONIOENCODING=utf-8 "${PY[@]}" scripts/verify_hap.py || exit 1
PYTHONIOENCODING=utf-8 "${PY[@]}" scripts/scan_needed.py || exit 1

echo
echo "############ 3/4 install ############"
# 优先用签名的 HAP。只有 build-profile.json5 里配了签名配置，
# hvigor 才会写出签名版 —— 没有它就没有可安装的东西，在这里
# 说明白，远比一个"包无效"的安装错误清楚。
if [ ! -f "$SIGNED" ]; then
    echo "!! no signed HAP at $SIGNED" >&2
    echo "!! set up signing once: DevEco -> File -> Project Structure ->" >&2
    echo "!! Signing Configs -> Automatically generate signature" >&2
    exit 1
fi
hdc uninstall "$BUNDLE" >/dev/null 2>&1
# 安装，并真正检查它确实发生了。
#
# 之前的写法是 `install -r "$SIGNED" 2>&1 | tail -3`，它把失败
# 掩盖了两次：管道的状态码是 tail 的，永远不是 hdc 的；而且只保留
# 最后三行会把只有一行的错误直接丢掉。实测
# 后果：两次运行打印了 `[Fail]ExecuteCommand need connect-key`，然后
# 继续去启动一个根本没装上的应用，而从各方面看都
# 像一次成功的部署。
#
# 这里正向匹配成功字符串，因为反向检查（"没有 [Fail]"）
# 分不清安装失败和 hdc 什么都没打印。这里的
# 措辞就是这个 hdc 实际输出的；换一种措辞会表现为响亮的
# 拒绝，而不是悄悄装了个旧的，这正是我们想要的取舍。
INSTALL_OUT="$(hdc install -r "$SIGNED" 2>&1)"
printf '%s\n' "$INSTALL_OUT" | tail -3
if ! printf '%s' "$INSTALL_OUT" | grep -q "install bundle successfully"; then
    echo "!! install did not report success -- refusing to launch" >&2
    echo "!! (hdc is flaky on this device: rerun, or check 'hdc list targets')" >&2
    exit 1
fi

echo
echo "############ 4/4 launch + collect ############"
# 当失败的探测循环反复输出同一条消息时，hilog 会限流并丢行，
# 而那正是我们最需要完整文本的时候。应用
# 已经把 stdout/stderr 镜像进自己的沙箱（redirect_io），那个
# 目录通过 hdc 是可读的 —— 所以读文件，别读日志缓冲区。
#
# 注意：hdc 无法往沙箱里写，所以这些日志没法从这里
# 清掉。stdout.log 由应用自己在启动时截断；stderr.log 不会，
# 所以之后读它时要当成跨多次运行只追加的文件。
LOG="/data/app/el2/100/base/$BUNDLE/files/stderr.log"
hdc shell hilog -r >/dev/null 2>&1
hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1
sleep 2
START_OUT="$(hdc shell "aa start -a $ABILITY -b $BUNDLE" 2>&1)"
printf '%s\n' "$START_OUT" | tail -2
# 和上面的安装一样的掩盖问题。这里启动失败以前只能靠
# 注意到下面的日志是空的才发现 —— 而那读起来像 "应用
# 启动时崩溃了"，完全是另一个问题，而且是本项目
# 已经追过一次的问题。
if ! printf '%s' "$START_OUT" | grep -q "start ability successfully"; then
    echo "!! launch did not report success -- the logs below will be empty" >&2
fi
echo "waiting 30 s ..."
sleep 30
echo
echo "===== stderr.log ====="
hdc shell "cat $LOG 2>/dev/null" || true
echo
echo "===== crash.txt ====="
hdc shell "cat /data/app/el2/100/base/$BUNDLE/files/crash.txt 2>/dev/null" || true
