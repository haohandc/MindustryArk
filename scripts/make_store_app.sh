#!/bin/bash
# 构建 AppGallery 的 .app。**两种模式，差别是「这个包要不要跑游戏」。**
#
#   tablet  带可执行内存 ACL，面向 tablet + 2in1。JVM 与游戏都在包里。
#   tools   **不带 JDK、不带游戏**的「管理工具」包，面向 phone + tablet + 2in1，
#           **不声明**可执行内存 ACL。它管存档与数据包，不跑游戏。
#
# ⛔⛔ **`tools` 只属于 Ark Launcher（lite 分支），Mindustry Ark 不用它。**
#    用户 2026-10-03 定的范围：「拆分包体仅限于 Ark Launcher 这个版本，
#    Mindustry Ark 不做实际的拆分包体。」
#    ⇒ 本脚本的 `tools` 分支带一道门（见下面 PY= 之后那段），在
#      `config.SHIPS_GAME` 为 True 的树上直接拒绝运行。那条开关就是分支身份。
#
# 为什么需要 tools 模式（2026-10-03）
#   本应用上不了手机，原因**不是体积而是权限**：
#   ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY 是 JVM 的 JIT 所必需的，
#   在某些设备上如此 -- 见 RELEASE-MAINTENANCE.md 2.11。实测：一台 HarmonyOS 6.1.1
#   (API 24) 设备拒绝 mmap(RWX)，errno=22，launcher 完全走不过
#   JNI_CreateJavaVM，应用装得上却起不来。
#   而那条 ACL **只覆盖平板与 PC/2in1**（详见下面 deviceTypes 那段）。
#   ⇒ 「手机形态」只有一条出路：**不要运行时**。不跑 JVM 就不需要那条权限。
#   实测体积：完整包 265.9 MB，tools 包约 8 MB（保留的 6 个库合计 6.95 MB）。
#
# ⚠️⚠️ **tools 与本项目【有意删掉】的那个 phone 模式不是同一个东西，别混。**
#   那个 phone 模式产出的包**还带着 JDK 和游戏**，只是不声明权限，
#   并指望 JVM 以解释模式运行。2026-09-22 实测（RELEASE-MAINTENANCE.md 2.13b）
#   证明那条路不可能工作：
#
#     在设备绑定的 RELEASE profile 且没有可执行内存 ACL 时，launcher
#     探测该能力，拿到 -1，强制 -Xint，然后死在
#     JNI_CreateJavaVM 里，之后再无任何输出。解释器仍然需要
#     可执行内存：HotSpot 在去看字节码要怎么运行之前，
#     就已经建好了启动桩。
#
#   ⇒ 那种包**装得上却永远起不来**，所以被删了。
#   ⭐ tools 模式把**运行时整个拿掉** ⇒ **没有东西会坏**，它是一个自洽的产品。
#   ⇒ 判据：**「带着一个跑不动的东西」与「不带那个东西」是两回事。**
#
#   ⭐ 还顺带解决了一件事：tools 模式**不需要 `entry/libs/` 那棵 JDK 树**
#     （它没有脚本能重建，见 docs/BUILDING.md）⇒ 它是一份**干净克隆**
#     唯一能构建出来的产物，也就能当「工具链是否完好」的验收。
#
# 为什么可执行内存权限不能无条件写进 src/main/module.json5
#   一个普通 (debug) profile 无法授予受限权限：声明它会让
#   本地安装失败，报 "install failed due to grant request permissions
#   failed"，本项目已经踩过一次 -- 见 deploy.sh 开头。
#
#   所以它只由本脚本为 store 产物声明，随后再移除；
#   hvigor 没有按 product 区分的 module.json5：它自己的
#   getJsonProfilePath() 对每个 TARGET 的 source-set 根目录只解析一个文件，所以
#   按 product 的 manifest 意味着整个源码树要再拷一份。
#   ⭐ 也正因为这样，本脚本是「按模式改变包形状」的唯一落点。
#
# ⚠️ 顺序很重要（tablet 模式）
#   在 AppGallery Connect 里 ACL 已获批、且 Release profile 已重新生成
#   带上它之前，不要运行 tablet 模式。一个声明了受限权限、其 profile 却
#   无法授予该权限的包是装不上的 -- 所以
#   提前运行只会让 store 构建更糟，而不是更好。
#
# 它保证什么
#   1. 除非 module.json5 处于已知干净状态，否则拒绝启动，这样
#      上一次在注入中途被杀掉的情况会被检出，而不是在其之上继续构建。
#   2. module.json5 在每一条退出路径上都会恢复，且恢复结果用哈希
#      校验 -- 不是假设。trap 在第一次写入之前就装好。
#   3. **tools 模式下 `entry/libs/arm64-v8a/` 会被挪走、构建完再挪回**。
#      ⛔ 只挪不删：那棵树 172 MB、**没有脚本能重建**。
#      ⚠️ 挪回时用「文件数 + 磁盘占用」复核，不是假设（同第 2 条对 manifest 的做法）。
#      ⚠️ 发现残留 stash 就**拒绝启动**并给出恢复命令（上一次死了）。
#   4. 构建产物会被打开并检查权限的**有无**与 deviceTypes。注入一个
#      文件并指望它进了包，和信任一份构建日志是同一个错误；
#      真正被上传的是那个包。
#
# 用法：
#   bash scripts/make_store_app.sh tablet
#   bash scripts/make_store_app.sh tools
#
# ⚠️ 而且 module.json5 的 deviceTypes 里仍列着 "phone" -- 同样是有意为之。
#    deviceTypes 在安装时就会被强制检查，不只是在列表展示时，所以从
#    manifest 里去掉 "phone" 会让自签名构建在手机上也无法安装，
#    从而毁掉手机唯一的路线。收窄应该放在
#    这里，构建期：这一层才决定 STORE 提供什么。
#
# 可执行内存权限是通过一个受限（ACL）应用授予的，
# 其支持的设备是 "tablet and PC/2in1"。**tablet 模式**声明了它并面向
# tablet + 2in1（用户已与华为确认，一个 Release Profile 就能覆盖它）；
# **tools 模式不声明它**，因此可以把范围放到含 phone 的那一组。
# AppGallery 按 deviceTypes 过滤 -- 这就是
# 为什么 deviceTypes 要在这里重写，而不是沿用工具链模板的
# ["phone","tablet","2in1","tv"]。"tv" 被去掉：本项目从未测过
# TV，而声明一个未测试的平台是一种主张，不是默认值。
#
# MODE 参数仍然必填，不给默认值。它是这个包唯一明说
# 自己声称哪些平台的地方，不应该让一个默认值
# 来回答这个问题。
#
# 输出：dist/store/MindustryArk-<version>-<mode>.app

set -o pipefail
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1

MODE="${1:-}"
case "$MODE" in
    tablet)
        WANT_PERM=yes; WANT_DEVICES='["tablet", "2in1"]'; STASH_LIBS=no
        ;;
    tools)
        # ⭐ 「管理工具」形态：**不要运行时** ⇒ 不需要 ACL ⇒ 手机上成立。
        # ⚠️ `STASH_LIBS=yes` 会把 entry/libs/arm64-v8a/ 整个挪走再挪回 ——
        #    那是本脚本唯一会动到源码树之外的大件，理由与保护方式见文件头第 3 条。
        WANT_PERM=no; WANT_DEVICES='["phone", "tablet", "2in1"]'; STASH_LIBS=yes
        ;;
    phone)
        # 显式写出来，这样回答就是解释而不是用法
        # 报错。输入 "phone" 的人不是打错字 -- 他们要的是
        # 本项目决定不构建的那个包，而单独一句 "usage: tablet"
        # 读起来会像这个参数只是没被识别。
        echo "!! there is no phone mode, and that is a decision rather than an omission." >&2
        echo "!! A phone package that still carries the JVM would install and never" >&2
        echo "!! start: the ACL covers tablet and PC/2in1 only, and the interpreted" >&2
        echo "!! fallback does not rescue a device that was refused executable memory." >&2
        echo "!!" >&2
        echo "!! What you probably want is 'tools': a package with NO runtime in it," >&2
        echo "!! which needs no ACL and therefore does work on a phone." >&2
        echo "!! See the header of this file, and RELEASE-MAINTENANCE.md 2.13b." >&2
        exit 2
        ;;
    *)
        echo "usage: bash scripts/make_store_app.sh tablet|tools" >&2
        echo >&2
        echo "  tablet  tablet + 2in1, WITH the executable-memory ACL (JIT)." >&2
        echo "          The full package: JVM and game included." >&2
        echo "  tools   phone + tablet + 2in1, NO ACL. A management tool with no" >&2
        echo "          JVM and no game (~8 MB instead of ~266 MB)." >&2
        echo "          ⛔ Ark Launcher (the lite branch) only -- refused here otherwise." >&2
        echo >&2
        echo "The mode is required: it is where the package says out loud which" >&2
        echo "platforms it claims, and a default should not be allowed to answer that." >&2
        exit 2
        ;;
esac

# ⭐⭐ **这一行是 tools 构建能通过自己闸门的关键。**
#     hvigor 每次 assembleApp 都会跑 scripts/verify_hap.py，而它按
#     `config.IS_TOOLS` 决定断言「JDK 必须在」还是「必须不在」——
#     两者方向相反。不给这个变量，tools 构建会被自己的闸门打回，
#     而报错指向「libs/ 下有意外条目」、完全不提环境变量。
#     传播链：本脚本 export → build.sh → hvigor（--no-daemon，见 hvigorfile.ts
#     文件头那段）→ hvigorfile.ts 的 `env: {...process.env, ARK_FORM}` → 子进程。
#     ⚠️ tablet 模式**显式写成 full**，免得调用方 shell 里残留的一个
#     ARK_FORM=tools 把它悄悄变成另一个形态。
export ARK_FORM="$([ "$MODE" = tools ] && echo tools || echo full)"

PY=("${ARK_PYTHON:-python}")

# ⛔⛔ tools 形态**只属于 Ark Launcher**（lite 分支）。
#    用户 2026-10-03 定的范围原话：「拆分包体仅限于 Ark Launcher 这个版本，
#    Mindustry Ark 不做实际的拆分包体。」
#
#    ⚠️ 加这道门，是因为它真的被越过一次：2026-10-03 在 master 上跑了 tools 模式，
#    产出 dist/store/MindustryArk-v1.3.0.1-tools.app —— **一个叫 MindustryArk、
#    却既没有 JDK 也没有游戏的 1.5 MB 包**。名字对，内容错，而这种东西
#    一旦被当成「Mindustry Ark 的包」发出去，读者拿到的是一个跑不了游戏的版本。
#
#    ⭐ 判据用 `config.SHIPS_GAME`：它就是**本仓库的分支身份**
#    （config.py 里那句「这一行就是本分支与 master 之间唯一的代码差异」）。
#    ⛔ 不用 `APP_NAME == "ArkLauncher"`：那是把产品名硬编码进构建脚本，
#    改名时会**静默**失效，而这道门必须只在正确的那棵树上前进。
if [ "$MODE" = tools ]; then
    SHIPS_GAME="$("${PY[@]}" -c 'import sys;sys.path.insert(0,"scripts");import config;print(config.SHIPS_GAME)')" || exit 1
    if [ "$SHIPS_GAME" != "False" ]; then
        echo "!! 'tools' is not built from this tree." >&2
        echo "!!" >&2
        echo "!! The split package belongs to Ark Launcher (the lite branch), which is" >&2
        echo "!! the tree where config.SHIPS_GAME is False. This tree has it True, so" >&2
        echo "!! this is Mindustry Ark -- and Mindustry Ark always ships the game and" >&2
        echo "!! the runtime. Splitting it would produce a package named after this" >&2
        echo "!! app that cannot run a game at all." >&2
        echo "!!" >&2
        echo "!! Use the lite worktree for a tools build." >&2
        echo "!! For this tree, the mode you want is 'tablet'." >&2
        exit 2
    fi
fi
MODJSON="entry/src/main/module.json5"
PERM="ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY"
BUILT_APP="build/outputs/release/MindustryArk-release-signed.app"
OUTDIR="dist/store"
# 文件名带版本，与 dist/ 里的其他产物一致（HAP 与 payload 都带版本）。
# 以前不带：商店包在同一目录里靠"只有一个"来区分，一旦两个版本并存，
# 名字完全一样，就只能靠哈希去认 -- 而上传时看的就是文件名。
# 版本从 config.py 取（它在 import 时就自检 APP_VERSION 与 VERSION_CODE 一致），
# 不在这里手写，免得像别处手抄的版本号那样悄悄过期。
ARTIFACT="$("${PY[@]}" -c 'import sys;sys.path.insert(0,"scripts");import config;print(config.ARTIFACT_NAME)')" || exit 1
OUTAPP="$OUTDIR/$ARTIFACT-$MODE.app"
BACKUP="${TEMP:-/tmp}/module.json5.pre-store"

# tools 模式把 entry/libs/arm64-v8a/ 挪到这里。
# ⛔ **不能放在 entry/libs/ 里面** —— hvigor 会递归收集那里的 `.so`，
#    stash 会被原样打进包（而验证闸门的体积上限正是为了兜住这类事）。
# ⛔ **不能放 ${TEMP}** —— 那通常是 C: 盘，与仓库不同卷 ⇒ `mv` 会变成
#    172 MB 的**拷贝**，既慢又可能中途失败。
# ⇒ 仓库根：同卷，`mv` 就是一次 rename（瞬时）。
STASH_DIR=".tools-stash"
STASHED_SIG=""
LIBS_DIR="entry/libs/arm64-v8a"

echo "############ store build: mode = $MODE ############"
echo "   permission $PERM: $([ "$WANT_PERM" = yes ] && echo INJECTED || echo absent)"
echo "   deviceTypes: $WANT_DEVICES"
echo "   entry/libs/arm64-v8a: $([ "$STASH_LIBS" = yes ] && echo 'STASHED during the build' || echo kept)"

# ---------------------------------------------------------------------------
# 恢复，先装好，在一切写入之前
#   在写入之后才装的 trap 只能保护比它更晚发生的失败。
#   真正要命的失败就是写入本身。
# ---------------------------------------------------------------------------
# entry/libs/arm64-v8a 的「指纹」：文件数 + 磁盘占用。
# ⚠️ 两者都要：只数文件会漏掉「文件还在但被截断」。
libs_signature() {
    [ -d "$LIBS_DIR" ] || { echo "absent"; return; }
    n=$(find "$LIBS_DIR" -type f 2>/dev/null | wc -l)
    kb=$(du -sk "$LIBS_DIR" 2>/dev/null | cut -f1)
    echo "$n files, $kb KB"
}

restore() {
    rc=$?
    # ⭐ 先把挪走的那棵树放回去 —— 它比 manifest 要紧得多：
    #    manifest 有 git 兜底（`git checkout --`），而 entry/libs/ 是
    #    gitignore 的工作区目录，**没有任何东西能把它变回来**。
    if [ -d "$STASH_DIR/arm64-v8a" ]; then
        if [ -d "$LIBS_DIR" ]; then
            echo "!! $LIBS_DIR reappeared while the stashed copy exists -- NOT overwriting." >&2
            echo "!! the stashed copy is at $STASH_DIR/arm64-v8a" >&2
        else
            mv "$STASH_DIR/arm64-v8a" "$LIBS_DIR"
            now="$(libs_signature)"
            # 复核，不是假设 —— 同下面 manifest 那段的道理。
            if [ "$now" = "$STASHED_SIG" ]; then
                echo "   entry/libs/arm64-v8a restored: $now   OK"
            else
                echo "!! entry/libs/arm64-v8a restored, but the signature CHANGED" >&2
                echo "!!   before: $STASHED_SIG" >&2
                echo "!!   after : $now" >&2
                echo "!!   the tree is back in place, but check it before trusting a build" >&2
            fi
            rmdir "$STASH_DIR" 2>/dev/null || true
        fi
    fi
    if [ -f "$BACKUP" ]; then
        "${PY[@]}" - "$MODJSON" "$BACKUP" <<'PYEOF'
import hashlib, io, os, shutil, sys
path, b = sys.argv[1], sys.argv[2]
want = io.open(b + ".sha256").read().strip()
shutil.copyfile(b, path)
got = hashlib.sha256(open(path, "rb").read()).hexdigest()
print("   restored %s  (sha256 %s%s)"
      % (path, got[:16], "" if got == want else "  *** MISMATCH, expected %s ***" % want[:16]))
PYEOF
    fi
    exit $rc
}
trap restore EXIT

# ---------------------------------------------------------------------------
# 闸门：FORCE_COMPAT_MODE 必须为 false。
#
# 该常量会在每一台设备上强制 -Xint，它存在的唯一目的是测量
# 解释器在并不需要它的硬件上要付出多少代价。如果它被留着没关，
# 而 store 包又是从这个工作树构建的，那每个用户拿到的都会是
# 解释模式跑的游戏，设备上却没有任何东西会说明原因。
#
# 这里选择检查而不是信任，因为"记得改回去"正是那种
# 一直有效、直到它失效为止的指示。
# ---------------------------------------------------------------------------
FORCE_LINE="$(grep -nE '^const FORCE_COMPAT_MODE' entry/src/main/ets/pages/Index.ets || true)"
case "$FORCE_LINE" in
    *"= false"*) : ;;
    "")  echo "!! could not find FORCE_COMPAT_MODE in Index.ets -- refusing to build" >&2
         exit 1 ;;
    *)   echo "!! FORCE_COMPAT_MODE is not false:" >&2
         echo "!!   $FORCE_LINE" >&2
         echo "!! that forces interpreted mode on every device. Set it back to false" >&2
         echo "!! before building anything that could ship." >&2
         exit 1 ;;
esac
echo "   gate: FORCE_COMPAT_MODE = false"

# ---------------------------------------------------------------------------
# 1. 前置检查、备份、注入
# ---------------------------------------------------------------------------
"${PY[@]}" - "$MODJSON" "$PERM" "$BACKUP" "$WANT_PERM" "$WANT_DEVICES" "$MODE" <<'PYEOF' || exit 1
import hashlib, io, os, re, sys
path, perm, backup, want_perm, want_devices, mode = sys.argv[1:7]
src = io.open(path, encoding="utf-8").read()

# ⚠️ 匹配声明本身，而不是名字。module.json5 有意在注释里
# 提到这个权限 -- 就是解释它为何缺席的那段 --
# 所以子串判断在干净的工作树上也会说"已声明"并拒绝
# 运行。实测：裸名字出现一次（第 36 行，在注释里），
# 而 '"name": "<perm>"' 出现零次。
DECL = '"name": "%s"' % perm
if DECL in src:
    print("!! %s ALREADY declares %s." % (path, perm))
    print("!! Either a previous run died before restoring it, or it was added by")
    print("!! hand. Restore it (git checkout -- %s) before running this --" % path)
    print("!! otherwise the backup below would capture the WRONG 'original'.")
    sys.exit(1)

io.open(backup, "w", encoding="utf-8", newline="").write(src)
digest = hashlib.sha256(src.encode("utf-8")).hexdigest()
io.open(backup + ".sha256", "w").write(digest)
print("   original saved: sha256 %s" % digest[:16])

# ⚠️ 锚点是那个数组，不是某条权限条目。
#
# 以前是插在 READ_WRITE_DOWNLOAD_DIRECTORY 条目之前，那样很方便，
# 因为那条目存在，而且明确不是注释。
# 那也是个陷阱：任何删除或重命名该权限的改动都会
# 在最糟的时刻把本脚本一起带走 -- 那时 ACL 刚刚
# 获批，而 store 构建正是你想产出的东西。
#
# 数组本身是结构性的。增删权限时它不会动，而如果
# 它没了，那 module.json5 就不再是 manifest，
# 这时大声失败才是正确答案。
m = re.search(r'"requestPermissions"\s*:\s*\[', src)
if not m:
    print("!! could not find the requestPermissions array in %s" % path)
    print("!! this script injects INTO that array; without it there is nowhere to")
    print("!! put the permission, and the manifest is not what this expects.")
    sys.exit(1)
after = m.end()

# 缩进取自数组的第一条条目，这样注入的文本会和
# 已有内容对齐。空数组时回退到 manifest 惯用的六个
# 空格。
nm = re.search(r'\n([ \t]+)\S', src[after:])
indent = nm.group(1) if nm else '      '

NEW = (indent + "// STORE BUILD ONLY -- injected by scripts/make_store_app.sh and removed\n"
       + indent + "// again on exit. See RELEASE-MAINTENANCE.md 2.11 for why this cannot be\n"
       + indent + "// declared unconditionally. Never commit a module.json5 containing this.\n"
       + indent + "// The ACL's supported devices are tablet and PC/2in1, which is why the\n"
       + indent + "// package this script produces claims those and nothing else.\n"
       + indent + '{ "name": "%s", "reason": "$string:perm_reason_CODE_MEMORY", '
                  # 是 `always`，而不是 `inuse`。JVM 的 JIT 从进程启动那一刻
                  # 到进程退出的全程都需要这块内存，而哪个 ability 在前台
                  # 跟这件事毫无关系。它还必须在形式上 MATCH
                  # 那份 AGC ACL 申请，在那边时机被设为 always -- 一个包的
                  # usedScene 与它自己的 ACL 申请给出的答案不一致，
                  # 就是一处不值得发布出去的不一致。
                  '"usedScene": { "abilities": [ "EntryAbility" ], "when": "always" } },\n' % perm)

# 插成第一条而不是最后一条：一个写成 `[]` 的数组，
# 它的收尾方括号紧跟在 `[` 之后，而插成第一条的处理
# 对空数组和有内容的数组都是一样的。
out = src[:after] + "\n" + NEW + src[after:] if want_perm == "yes" else src

# --- deviceTypes，两种模式下都会重写 --------------------------------
#
# manifest 出厂时带的是工具链模板的值 ["phone","tablet","2in1",
# "tv"]，那是一个起点而不是一个决定。每个模式把它收窄到
# 该包自己的用途，而 "tv" 两边都去掉：这里没有任何东西
# 在 TV 上跑过，而声明一个平台就是一份承诺。
#
# 用户已确认 AppGallery 按它过滤，所以这个切分正是让
# 手机用户不会被提供 tablet 包的东西 -- 对他们来说那会是
# *更糟* 的那个，因为他们无法被授予它期望的 ACL。
dm = re.search(r'"deviceTypes"\s*:\s*\[[^\]]*\]', out)
if not dm:
    print("!! no deviceTypes array in %s" % path)
    print("!! without it a package declares no platform, and the split between the")
    print("!! two store builds has nowhere to live.")
    sys.exit(1)
out = out[:dm.start()] + '"deviceTypes": %s' % want_devices + out[dm.end():]
print("   deviceTypes -> %s" % want_devices)

# 对写入本身做的廉价检查，在它落盘之前。下面的构建
# 闸门检查的是产物；这一条在备份还新鲜的时候
# 抓出被改坏的编辑。
#
# ⚠️ 方向随模式而反 —— 与下面产物闸门里的那条同一个道理。
#    这里原本只写「必须有」，因为那时只有 tablet 一个模式；
#    tools 模式下不注入 ⇒ 那次检查必然失败，而它会报
#    「注入产出的文件里没有这个权限」—— 对着一个**本来就不该有它**的模式。
decl = ('"name": "%s"' % perm) in out
if want_perm == "yes":
    if not decl:
        print("!! the injection produced a file without the permission in it")
        sys.exit(1)
else:
    if decl:
        print("!! mode=%s must NOT declare %s, but the edited manifest does" % (mode, perm))
        print("!! if you injected it by hand, remove it -- otherwise a package that is")
        print("!! supposed to work on phones would need an ACL phones cannot be granted.")
        sys.exit(1)

io.open(path, "w", encoding="utf-8", newline="\n").write(out)
print("   %s" % ("injected %s" % perm if want_perm == "yes"
                else "no permission injected (mode=%s does not need it)" % mode))
PYEOF

# ---------------------------------------------------------------------------
# 2. 构建
# ---------------------------------------------------------------------------
echo
echo "############ building the store .app ############"
# ---------------------------------------------------------------------------
# tools 形态：把运行时那棵树挪走
#
# ⚠️ 这一段必须在 `trap restore EXIT` **之后**（它在文件上方），
#    否则一旦这里或之后的任何一步失败，树就留在 stash 里没人管。
#
# ⚠️ 只 `mv` 不 `cp` 也不 `rm`：`entry/libs/arm64-v8a` 有 172 MB，而
#    **没有任何脚本能重建它**（docs/BUILDING.md 记着这个缺口）。
#    同卷 rename 是瞬时的，所以「挪」比「拷贝一份」更快也更安全。
# ---------------------------------------------------------------------------
if [ "$STASH_LIBS" = yes ]; then
    # 残留检测：stash 还在 ⇒ 上一次 tools 构建没走完。
    # ⛔ 不自动恢复：那会在用户不知情时改动一棵 172 MB 的树，
    #    而且「自动恢复」如果判断错了，会把树挪到更糟的地方。
    if [ -e "$STASH_DIR" ]; then
        echo "!! $STASH_DIR already exists -- a previous tools build did not finish." >&2
        echo "!! Your entry/libs/arm64-v8a is probably sitting inside it." >&2
        echo "!! Nothing here will touch it. Check and restore it by hand:" >&2
        echo "!!     ls \"$STASH_DIR\"" >&2
        echo "!!     mv \"$STASH_DIR/arm64-v8a\" \"$LIBS_DIR\" && rmdir \"$STASH_DIR\"" >&2
        echo "!! then re-run. (Refusing rather than restoring automatically, because" >&2
        echo "!! moving it while it is half-moved is worse than stopping.)" >&2
        exit 1
    fi

    STASHED_SIG="$(libs_signature)"
    if [ "$STASHED_SIG" = "absent" ]; then
        echo "   entry/libs/arm64-v8a is already absent -- nothing to stash"
        echo "   (that is a clean clone, or a tree that never ran prep_vendor.py)"
    else
        echo "   stashing $LIBS_DIR  ($STASHED_SIG)"
        mkdir -p "$STASH_DIR" || exit 1
        mv "$LIBS_DIR" "$STASH_DIR/arm64-v8a" || exit 1
    fi
fi

bash build.sh assembleApp --mode project -p product=release -p buildMode=release --no-daemon > /tmp/store_app.log 2>&1
if [ $? -ne 0 ] || ! grep -q "BUILD SUCCESSFUL" /tmp/store_app.log; then
    grep -Ei "BUILD (SUCCESSFUL|FAILED)" /tmp/store_app.log | head -1
    echo "!! build failed -- tail of the log:" >&2
    tail -25 /tmp/store_app.log >&2
    exit 1
fi
grep -Ei "BUILD (SUCCESSFUL|FAILED)" /tmp/store_app.log | head -1

# ---------------------------------------------------------------------------
# 2b. 以带模式名的名字另存一份
#
# hvigor 每个 product 只写一个固定路径，所以构建第二个模式会
# 覆盖第一个 -- 而这两个包只靠一个在文件列表里看不见的
# 权限来区分。在这里改名意味着两者可以同时存在，
# 文件名也能说明哪个是哪个。
#
# 是拷贝不是移动：下面的闸门要读 $BUILT_APP，闸门失败时应该
# 让构建树保持 hvigor 留下的样子。
# ---------------------------------------------------------------------------
echo
echo "############ keeping the artifact as $ARTIFACT-$MODE.app ############"
if [ ! -f "$BUILT_APP" ]; then
    echo "!! the build reported success but there is no .app at $BUILT_APP" >&2
    echo "!! do not go looking for an older one -- that is how a stale package gets" >&2
    echo "!! uploaded. Check the build log above." >&2
    exit 1
fi
mkdir -p "$OUTDIR"
cp -f "$BUILT_APP" "$OUTAPP"
echo "   $OUTAPP"

# ---------------------------------------------------------------------------
# 2c. 签名到底有没有真的被附加？
#
# 结尾的消息告诉读者这个文件是 release 签名的。那是一个关于
# 签名的主张，而签名不是 zip 条目 -- HarmonyOS 把它附加在
# 归档之后 -- 所以列出 .app 的内容两条路都证明不了什么。
# 实测如此，这也是本检查存在的原因：脚本里原本没有任何
# 地方验证它。
#
# hvigor 会把两个变体并排产出，而带签名那个大出的部分
# 正好是签名块（实测：153,246,249 vs 153,231,519 = +14,730 B）。
# 两者一比，主张就变成了实测。
#
# 如果签名配置缺失或错误，hvigor 仍然会成功，并且仍然
# 写出一个叫 "-signed" 的文件 -- 这正是本检查要抓的失败。
# ---------------------------------------------------------------------------
UNSIGNED_APP="${BUILT_APP%-signed.app}-unsigned.app"
if [ -f "$UNSIGNED_APP" ]; then
    SZ_SIGNED=$(wc -c < "$BUILT_APP")
    SZ_UNSIGNED=$(wc -c < "$UNSIGNED_APP")
    if [ "$SZ_SIGNED" -le "$SZ_UNSIGNED" ]; then
        echo "!! '$BUILT_APP' is NOT LARGER than the unsigned variant:" >&2
        echo "!!   signed   $SZ_SIGNED B" >&2
        echo "!!   unsigned $SZ_UNSIGNED B" >&2
        echo "!! The file is named -signed but no signature was appended, which means" >&2
        echo "!! the release signingConfig did not take effect. Check the 'release'" >&2
        echo "!! entry in the root build-profile.json5 (it is skip-worktree, so it is" >&2
        echo "!! not in git and cannot be reviewed by 'git diff'). Do not upload." >&2
        exit 1
    fi
    echo "   signature present: +$((SZ_SIGNED - SZ_UNSIGNED)) B over the unsigned variant"
else
    echo "   (no -unsigned variant to compare against; the signature is not verified)" >&2
fi

# ---------------------------------------------------------------------------
# 3. 闸门 -- 包才是被上传的东西，所以要检查包
#
# 两条不变式，**两条都按模式取正反两个方向**：
#
#   1. deviceTypes 恰好等于这个模式声称的那一组。
#      tablet ⇒ tablet + 2in1：正是它让 store 不会把**带运行时**的包
#      提供给手机（那会装得上却起不来）。一个意外带上 "phone" 的包
#      会被提供给它服务不了的设备。
#      tools  ⇒ 含 phone：那正是这个模式存在的理由。
#   2. 可执行内存权限的有无：
#      tablet ⇒ **必须有**。没有它就没有 JIT，安装后永远起不来 --
#               从外面看是静默的。唯一的证据是 launcher 有没有打日志
#               "executable memory works (probe=42)"。
#      tools  ⇒ **必须没有**。这个模式不带 JVM，也就不需要它；
#               而一旦声明了它，包又会掉回「手机上装不了」--
#               把这个模式的意义整个抵消掉。
# ---------------------------------------------------------------------------
echo
echo "############ gate: the ARTIFACT has the shape mode=$MODE requires ############"
"${PY[@]}" - "$BUILT_APP" "$PERM" "$WANT_PERM" "$WANT_DEVICES" "$MODE" <<'PYEOF'
import hashlib, io, json, os, re, sys, zipfile
app, perm, want_perm, want_devices, mode = sys.argv[1:6]
if not os.path.exists(app):
    sys.exit("!! no .app at %s" % app)
z = zipfile.ZipFile(app)
inner = [n for n in z.namelist() if n.endswith(".hap")]
if not inner:
    sys.exit("!! the .app contains no .hap")
h = zipfile.ZipFile(io.BytesIO(z.read(inner[0])))
mod = json.loads(h.read("module.json").decode())["module"]
names = [p["name"] for p in mod.get("requestPermissions", [])]
print("   declared permissions: %s" % names)
print("   deviceTypes: %s" % mod.get("deviceTypes"))

# ---------------------------------------------------------------------------
# 检查项。
#
# 1. deviceTypes 与本构建声称的一致，最先检查，因为它决定
#    这个包会被提供给谁。⚠️ 方向随模式而反：tablet 模式下多出
#    "phone" 意味着 store 会把一个**带运行时、跑不动**的应用
#    提供给手机；而 tools 模式下少了 "phone" 意味着
#    这个模式白做了 —— 它全部的价值就是能在手机上装。
#
# 2. 权限**有无**，同样随模式而反。tablet 下它缺席时的那种失败，
#    看起来像一台慢平板，而不是一个坏包；tools 下它**出现**
#    则会把包又推回「手机上装不了」。
#
# 3. module.json5 在未注释行上声明的每一个权限，都在
#    包里。这是通用不变式 -- manifest 被改成某种
#    包不反映的样子 -- 与单模式版本相比未变。
#    它正是当初抓住那个旧陷阱的东西：注入被锚定在一条
#    后来被删掉的权限条目上。
# ---------------------------------------------------------------------------
expected = json.loads(want_devices)
actual = mod.get("deviceTypes") or []
if sorted(actual) != sorted(expected):
    sys.exit("!! mode=%s expects deviceTypes %s but the package declares %s -- do not upload"
             % (mode, expected, actual))

# ⚠️ 这条**必须按 want_perm 分两臂**，不能只写「必须有」。
#
# 本项目原本只写「必须有」，因为那时只有 tablet 一个模式。tools 模式
# （2026-10-03）**不要运行时、也就不该声明这条权限** ⇒ 一条写死
# 「必须有」的检查会把 tools 构建直接打回，而报错会说「包缺了权限」、
# 完全不提「这个模式本来就不该有它」。
#
# ⭐ 两臂都是**硬闸门**（方向相反，强度相同），这与 verify_hap.py 的 §6
#    对游戏 jar 的做法一致：**「该有的必须有」与「不该有的必须没有」
#    是同一件事的两面，少一面就等于少一道闸门。**
has = perm in names
if want_perm == "yes":
    if not has:
        sys.exit("!! THE PACKAGE IS MISSING THE INJECTED PERMISSION: %s -- do not upload. "
                 "Without it there is no JIT, and the app installs and does not start." % perm)
    print("   ok: deviceTypes %s, permission declared" % sorted(actual))
else:
    if has:
        sys.exit("!! the package DECLARES %s, and mode=%s must not need it -- do not upload. "
                 "This mode carries no JVM, so it needs no executable memory; declaring the "
                 "permission would put it back out of reach of phones, which is the whole "
                 "point of this mode." % (perm, mode))
    print("   ok: deviceTypes %s, no executable-memory permission (as this mode requires)"
          % sorted(actual))

# 脚本开头已经 cd 到项目根目录，所以这里本来就是正确的
# 基准 -- 从 .app 所在目录去算 "../.." 跳转层数，正是第一版把
# 深度算错一层的原因。
manifest = "entry/src/main/module.json5"
declared = []
if os.path.exists(manifest):
    for line in io.open(manifest, encoding="utf-8"):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        # 特意锚定在 "ohos.permission." 上。一个裸的 `"name": "..."` 也会
        # 匹配模块名、ability 名和 extension 名 --
        # 实测，它们在第一版里全都命中了，会被报告成
        # "declared but missing from the package"，从而让构建
        # 因为三个根本不是权限的东西而失败。
        for nm in re.findall(r'"name"\s*:\s*"(ohos\.permission\.[^"]+)"', stripped):
            if nm not in declared:
                declared.append(nm)
    # 被注入的那个不在 module.json5 里 -- 它是本脚本在写盘途中
    # 加进去的，而且只在 tablet 模式下，所以这里不算"已声明"。
    absent = [p for p in declared if p not in names]
    print("   module.json5 declares %d, package carries %d" % (len(declared), len(names)))
    if absent:
        sys.exit("!! DECLARED IN THE MANIFEST BUT NOT IN THE PACKAGE: %s -- do not upload"
                 % absent)
else:
    print("   (module.json5 not found at %s -- skipped the manifest cross-check)" % manifest)
v = json.loads(z.read("pack.info").decode())["summary"]["app"]["version"]
print()
print("   %s" % os.path.basename(app))
print("   versionName %s   versionCode %s" % (v["name"], v["code"]))
print("   size %d B" % os.path.getsize(app))
print("   sha256 %s" % hashlib.sha256(open(app, "rb").read()).hexdigest())
PYEOF
GATE_RC=$?

# ---------------------------------------------------------------------------
# 4. 把 manifest 放回去，并说明这件事
#
# EXIT 上的 trap 会做这件事，但消息很重要：看到构建成功的
# 读者需要知道工作树是否干净，因为他们接下来可能要做的事
# 是 `git diff` 或者再跑一次构建。
# ---------------------------------------------------------------------------
echo
if [ -f "$BACKUP" ]; then
    echo "   manifest restored (the trap will do it again on exit; that is harmless)"
fi

echo
if [ "$GATE_RC" -eq 0 ]; then
    echo "############ OK -- upload this file ############"
    echo "   $OUTAPP"
    echo
    if [ "$MODE" = tools ]; then
        echo "   phone + tablet + 2in1, NO executable-memory ACL."
        echo "   This package carries no JVM and no game, so there is nothing in it"
        echo "   that needs a permission phones cannot be granted -- which is the"
        echo "   whole reason this mode exists."
        echo
        echo "   ⚠️ It CANNOT run games. It manages saves and data packs. Do not"
        echo "   advertise it as the game."
    else
        echo "   tablet + 2in1, WITH the executable-memory ACL."
        echo "   Needs the Release Profile that carries that ACL entry."
        echo "   Phones are deliberately NOT covered: the ACL cannot reach them and the"
        echo "   interpreted fallback does not save them, so a phone package would install"
        echo "   and never start. Self-signed installs are how phones are served."
        echo "   ⭐ For a phone-installable package, use: bash scripts/make_store_app.sh tools"
    fi
    echo
    echo "   Signed with the RELEASE certificate, so it cannot be sideloaded and"
    echo "   cannot be tested on your own hardware. Same constraint as 2.10/2.11."
    if [ "$MODE" != tools ]; then
        echo "   ⚠️ Which means the ACL is UNVERIFIED until it is in the store: if the"
        echo "   grant does not take effect the app still runs, just interpreted -- so a"
        echo "   failed ACL looks like a slow tablet and nothing else. The launcher log"
        echo "   line to look for is 'executable memory works (probe=42)'."
    fi
else
    echo "############ GATE FAILED -- do not upload ############" >&2
fi
exit $GATE_RC
