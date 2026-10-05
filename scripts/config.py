# -*- coding: utf-8 -*-
r"""Every path the build needs, in one place.

WHY THIS FILE EXISTS
    The toolchain used to name its inputs as literals inside each script. That
    made a fresh checkout depend on the original author's directory layout --
    which is not something a public repository can ask of anyone -- and it meant
    one fact ("where does the game jar live") was written down in four files and
    could drift between them.

    Everything here is overridable from the environment, so a different machine
    only has to set variables rather than edit scripts. The defaults point at
    payload-src/, which is where the inputs are expected to sit (see
    payload-src/README.md).

WHAT IS NOT HERE
    Scratch directories (the Arc build tree, the extracted natives) stay local to
    the scripts that own them: they are recreated on every run and nobody needs
    to configure them.

HOW TO SEE WHAT IT RESOLVES TO
    python scripts/config.py            print each path and whether it exists
    python scripts/config.py --json     the same, as JSON, for scripts

NAMING
    Environment variables use the ARK_ prefix so they cannot collide with
    anything else. DEVECO_SDK_HOME is the exception and is read as-is, because
    hvigor and DevEco already define it and build.sh exports it -- honouring the
    existing name means the prep scripts inherit the same SDK when they are run
    from deploy.sh.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)


def _env(name, default):
    """Environment override, or the default. An empty variable counts as unset:
    'export ARK_ARC_SRC=' in a shell should not produce the empty path."""
    v = os.environ.get(name)
    return v if v else default


# ---------------------------------------------------------------------------
# DevEco Studio / HarmonyOS SDK
# ---------------------------------------------------------------------------
# Studio 根目录含 sdk/ 和 tools/；SDK 根目录含 default/，其中
# 是 OpenHarmony 原生工具链。两者分开，意味着下面的
# node 和 hvigor 路径不必各自单独配置。
DEVECO_STUDIO = _env("ARK_DEVECO_STUDIO", r"E:\Program Files\DevEco Studio")
DEVECO_SDK_HOME = _env("DEVECO_SDK_HOME", os.path.join(DEVECO_STUDIO, "sdk"))

NATIVE_SDK = _env("ARK_NATIVE_SDK",
                  os.path.join(DEVECO_SDK_HOME, "default", "openharmony", "native"))
SYSROOT = os.path.join(NATIVE_SDK, "sysroot")

CLANG = os.path.join(NATIVE_SDK, "llvm", "bin", "clang.exe")
LLVM_BIN = os.path.join(NATIVE_SDK, "llvm", "bin")
READELF = os.path.join(LLVM_BIN, "llvm-readelf.exe")

# 设备工具 -- 同一 SDK 内 native/ 的上一级
HDC = os.path.join(DEVECO_SDK_HOME, "default", "openharmony", "toolchains", "hdc.exe")

NODE = _env("ARK_NODE", os.path.join(DEVECO_STUDIO, "tools", "node", "node.exe"))
HVIGOR = _env("ARK_HVIGOR",
              os.path.join(DEVECO_STUDIO, "tools", "hvigor", "bin", "hvigorw.js"))

# ---------------------------------------------------------------------------
# 主机工具
# ---------------------------------------------------------------------------
# 开发所在的机器上 javac/jar 不在 PATH 中，所以 JDK 是
# 显式指定路径的。只有 Arc 补丁和那个单类 helper jar 需要它。
JAVA_HOME = _env("ARK_JAVA_HOME", r"C:\Program Files\Java\jdk-17")
JAVAC = _env("ARK_JAVAC", os.path.join(JAVA_HOME, "bin", "javac.exe"))
JAR = _env("ARK_JAR", os.path.join(JAVA_HOME, "bin", "jar.exe"))

PYTHON = _env("ARK_PYTHON", sys.executable or "python")

TMP = os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"

# ---------------------------------------------------------------------------
# Payload 输入 -- prep_*.py 脚本消费的东西
# ---------------------------------------------------------------------------
PAYLOAD_SRC = _env("ARK_PAYLOAD_SRC", os.path.join(PROJECT_ROOT, "payload-src"))

# ⭐ 随包发布的游戏 jar。这是上游发布版，逐字节原样 -- 我们的东西
# 在当前架构下完全没写进去。我们的 Arc 改动以独立 jar 发布，
# 在 classpath 上排在它前面；见 make_patch_jar.py
# 和 launcher.c 里的 PATCH_JAR。
#
# 任何人都可替换：prep_game.py 按 SHA-1 识别构建，而不是按
# 文件名。
UPSTREAM_JAR = _env("ARK_UPSTREAM_JAR", os.path.join(PAYLOAD_SRC, "Mindustry.jar"))

# ⚠️ 2026-09-28 从 GAME_JAR 改名。它不再是游戏 jar，而
# 旧名字已经造成过一次错误结论：当那个 pristine jar 作为
# UPSTREAM_JAR 时，"GAME_JAR" 指向的是另一个文件，而 prep_arc.py 正是通过它
# 读 native 库。改动它指向的位置会把上游那个
# 无音频的 libarcarm64.so 塞进分发包。
#
# 它是什么：承载我们 Arc native 库的 jar，prep_arc.py
# 从中解出到 entry/libs/arm64-v8a/arc/。由 build_variants.py 从
# UPSTREAM_JAR 构建 -- 流水线中唯一无法从本仓库
# 复现的东西（libarcarm64.so 的编译配方不在仓库里）。
NATIVES_JAR = _env("ARK_NATIVES_JAR", os.path.join(PAYLOAD_SRC, "mindustry-1.0-audio.jar"))

# 由 patch_mindustry.py 从 UPSTREAM_JAR 生成。2026-09-28 已废弃：我们的
# 类现在随补丁 jar 发布，而不再写进游戏 jar，所以
# 构建里没有任何东西读它。保留是因为 build_variants.py 仍会读，且
# 两个脚本都保留，作为旧链路做过什么的记录。
PATCHED_JAR = _env("ARK_PATCHED_JAR", os.path.join(PAYLOAD_SRC, "mindustry-1.0.jar"))

# 向后兼容别名。等没有任何引用后再删。
GAME_JAR = NATIVES_JAR

# Arc 的源码，用于重新编译进 jar 的三个类。
ARC_SRC = _env("ARK_ARC_SRC", r"C:\Users\Haohandc\Arc")

# LWJGL：Java jar 和 native 库，全在一个目录。
LWJGL_SRC = _env("ARK_LWJGL_SRC", os.path.join(PAYLOAD_SRC, "lwjgl-ohos"))

# 构建运行时所用的精简 JDK：它的 lib/server/libjvm.so 就是
# 要发布的 JVM，而它的 lib/libcxxabi_shim.so 是替换 shim
# 所链接的对象。
JDK_SLIM = _env("ARK_JDK_SLIM", os.path.join(PAYLOAD_SRC, "jdk21slim"))
SRC_JVM = _env("ARK_SRC_JVM", os.path.join(JDK_SLIM, "lib", "server", "libjvm.so"))
SRC_CXXABI_SHIM = _env("ARK_SRC_SHIM", os.path.join(JDK_SLIM, "lib", "libcxxabi_shim.so"))

# ---------------------------------------------------------------------------
# 项目内的输出
# ---------------------------------------------------------------------------
CPP = os.path.join(PROJECT_ROOT, "entry", "src", "main", "cpp")
LIBS = os.path.join(PROJECT_ROOT, "entry", "libs", "arm64-v8a")

# 查看哪个构建产物的输出。构建 profile 定义了两个 --
# "default"（调试证书，deploy.sh 装到设备上的那个）和
# "release"（AppGallery 证书）-- 而产品名是路径的
# 组成部分，所以两者不会互相覆盖：
#
#     entry/build/<product>/outputs/default/
#
# 默认取 "default" 让所有现有调用仍指向
# 原来的位置；ARK_PRODUCT=release 是商店构建要的。这里
# 刻意不从"任意位置最新文件"自动检测：磁盘上有两个
# 产物时，最新优先会悄悄开始描述另一个构建。
PRODUCT = _env("ARK_PRODUCT", "default")

# ── 构建形态 ────────────────────────────────────────────────────────────────
# FULL    : 日常与 tablet 商店包。包里带 JDK、游戏与游戏链（Arc/LWJGL/patchjar）。
# TOOLS   : 「管理工具」形态 —— **把整个 entry/libs/arm64-v8a/ 挪走之后再构建**
#           ⇒ 包里没有 JDK、没有游戏、没有游戏链。它是唯一能在手机上架的形态，
#           因为不跑 JVM 就不需要 ALLOW_WRITABLE_CODE_MEMORY，
#           而那条 ACL 只覆盖平板与 PC/2in1（见 make_store_app.sh 的文件头）。
#
# ⛔⛔ **这【不是】分支身份，别把它当成第二个 SHIPS_GAME。**
#     `SHIPS_GAME` 是**可提交的**布尔，因为它是「这个仓库是哪一版」的身份；
#     而构建形态是**构建时**的参数，与 `make_store_app.sh` 注入 manifest 属于同一类，
#     本来就不该提交。判断标准：**换一棵源码树还是同一个东西 ⇒ 形态；否则 ⇒ 身份。**
# ⚠️ 它一旦取值出错，后果是**闸门方向反了**（该断言「JDK 必须在」还是「必须不在」），
#    而报错会指向「缺条目」、完全不提这个变量 —— `hvigorfile.ts` 因此把它打进了日志。
FORM = _env("ARK_FORM", "full")
FORM_TOOLS = "tools"
IS_TOOLS = (FORM == FORM_TOOLS)
OUT_DIR = os.path.join(PROJECT_ROOT, "entry", "build", PRODUCT, "outputs", "default")

# 这三者必须与 entry/build-profile.json5 的
# artifactName 和 AppScope/app.json5 的 versionName 一致。verify_hap.py 会从
# 构建出的包里读回 artifact 名并比对，所以只对三者之一
# 而不是全部做版本提升，会让构建失败，而不是产出一个
# 名字与内容不符的文件。
APP_NAME = "MindustryArk"

# ---------------------------------------------------------------------------
# 版本
# ---------------------------------------------------------------------------
# versionName 和 artifactName 允许的字符不同，这就是
# 这里的陷阱 -- 两者都是靠构建实测的，不是从文档读来的：
#
#   versionName   必须以数字或点开头（hvigor 的 schema 模式是
#                 ^[0-9.]+|(?=.*[{])(?=.*[}])[0-9a-zA-Z_.{}]+$，它的第一个
#                 分支是前缀匹配，所以首字符之后几乎
#                 什么都能通过 -- 包括空格和感叹号）。
#                 开头的 "v" 会被拒绝。
#   artifactName  ^[\da-zA-Z0-9._-]+$ -- 不允许空格，不允许 "+"。
#
# 所以开头的 "v" 属于发布 tag 和 artifact 名，从不属于
# version name，两者安全的字符集是数字、字母、点、
# 下划线和连字符。
APP_VERSION = "1.3.3.2"

# versionCode 是平台实际据以排序安装的整数。
#
#   base = major*1000000 + minor*10000 + patch*100
#   后两位：该版本的一个构建取 1..98，99 表示
#   它的最终发布
#
# ⭐⭐ 【哪一位在什么时候动】—— 机制在上面，政策在这里。
#    上面那几行只说「每个写法算出什么数」，不说「该用哪一个」，
#    而这两件事读者都会问。用户 2026-10-02 问过一次「第 4 位会不会一直是 1」，
#    当时答案只存在于记忆里，所以补在这里。
#
#    ⭐⭐ 2026-10-03 用户重定了整张表。**四条各有其职，从第 1 位开始定义** ——
#       旧表只有第 4 位有定义，而且方向和这张**相反**（见下面的「已作废」）。
#
#      第 1 位   **重大更新** —— 后端 / 图形引擎这类**底层更换**
#                                        ⇒ 1.3.1.1 -> 2.0.0.1 (2000001)
#      第 2 位   **可见的直观更新**        ⇒ 1.3.1.1 -> 1.4.0.1 (1040001)
#      第 3 位   **在上一版功能上的小修补**，看得见
#                                        ⇒ 1.3.1.1 -> 1.3.2.1 (1030201)
#      第 4 位   **修 bug，没有加东西**    ⇒ 1.3.1.1 -> 1.3.1.2 (1030102)
#
#    ⭐ **「重切一版」也走第 4 位**（打包错了、签名要重来、重新上传，内容与
#       上一版相同）。用户 2026-10-03 的原话是它「属于修 bug 的范畴」。
#       分辨靠**发布说明**、不靠号：
#         ⭐ **号回答「变了多少」，说明回答「变了什么」。**
#
#    ⛔⛔ 已作废（**别照它做**）——这里曾经写着：
#         「第 4 位 **不要**拿去装修复，那样 `1.2.0.2` 会让读者以为什么都没变」
#       那条已被上面这版取代：**现在第 4 位就是修 bug 用的。**
#       旧理由想靠「禁止某种用法」来避免歧义；新做法是把歧义**写进发布说明**。
#       ⇒ 判据不同：旧的是「这个号许不许表示修复」，新的是「这次发布该不该升位」。
#
# ⚠️ **历史记录，不是政策**：上面那张旧表时期，本项目节奏是「每次发布都换
#    一套功能」，所以第 2 / 3 位几乎每次都动、第 4 位每次都重置回 1。
#    七次发布里它只不是 1 两回，而那两回都是「同一套东西再来一版」：
#    `0.2.0.2`（改名，代码没动）与 `1.0.0.2`（1.0.0 的第二个 RC）。
#    ⛔ 那两个号**不改写** —— 它们是已经发出去的事实的记录。
#
# 这样既保留 semver 读者期望的顺序（beta 排在自己的
# 最终发布之前），又保持为普通 int32，而这是该字段唯一接受的类型：
# 实测 0 <= versionCode <= 2147483647。
#
#   0.1.0-beta1 -> 10001        0.1.0.1 -> 10001        0.1.0 -> 10099
#   0.1.1-beta1 -> 10101        0.2.0.1 -> 20001        1.0.0 -> 1000099
#   0.2.0.2     -> 20002
#
# 第四段取代了预发布后缀，两者共用同一个
# 槽位，因为它们回答同一个问题 -- 这是该版本的哪个构建。
#
#   原因：AppGallery 的准入检查会拒绝不是纯
#        数字和点的 versionName。实测，不是从文档读来的：上传一个 .app，
#        其 versionName 为 `0.2.0-beta.2`，返回 版本名称规范性检测 不通过
#        (55/100)，且无法绕过 -- 上传无法继续。该
#        检查建议用 "A.B.C.D"，这也是 HarmonyOS 给自家系统应用
#        采用的形式。
#
#   以及为什么旧写法仍必须能解析：`0.2.0-beta.1` 已发布并
#        打过 tag，而 version_code_for() 会被来自这个常量
#        之外其他来源的版本字符串调用。只接受新形式的
#        正则会把一个已发布的 tag 变成硬失败。
#
# 预发布号可以带点也可以不带点 -- 0.2.0-beta1 和
# 0.2.0-beta.1 都得 20001，因为写法和字母都不参与
# 运算。本项目在 0.2.0 时改用带点形式，到 0.2.0.2 时
# 完全弃用该后缀。
#
# 下面的 version_code_for() 推导它，模块会把自身常量
# 与推导结果比对，所以改了版本号却忘改 code 会在
# import 时失败，而不是发布一个无法替换上一版的安装包。
#
# ⭐ 为什么从 0.3.0.1 跳到 1.0.0.1（2026-09-22，用户拍板）。
# 应用功能已完整并在两台设备上验证过，且正要去
# 上架商店 -- 在那里这个字符串就是用户会读到的。SemVer 的 0.x 字面
# 意思是"不可用于生产，任何东西都可能变"，停在那儿会
# 低估它。1.0.0 就是这个 RC 所候选的发布版。
#
# ⚠️ versionCode 从 30001 跳到 1000001，才使它成为升级
# 而不是降级，所以已装 `0.3.0.1` 的人会原地装它。反过
# 来不成立：一旦 1.0.0 的构建发布，退回任何 0.x 都是
# 降级，平台会拒绝。
VERSION_CODE = 1030302


def version_code_for(version):
    """versionCode for a version string, per the rule above.

    Handles the only shapes this project uses: M[.m[.p[.b]]][-pre[.]N]. Anything
    else raises rather than guessing -- a wrong versionCode is invisible until an
    install silently refuses to upgrade, which is a bad way to find out.

    At most one of the fourth segment and the pre-release suffix may be present:
    they occupy the same slot, so a string carrying both has two contradictory
    answers to "which build is this", and picking one silently would be the same
    class of mistake as guessing.

    The dot before the pre-release number is OPTIONAL, and deliberately so. The
    pre-release part is not read for the code -- only the digit after it is -- so
    `beta.1` and `beta1` are the same version as far as install ordering goes and
    both must parse. Making the dot required would have turned every older version
    string, including ones already released, into a hard failure.

    (The difference between the two spellings is real but not ours to enforce:
    semver reads `beta.1` as two identifiers and `beta1` as one, and only
    identifiers that are purely numeric compare numerically. That matters when a
    project reaches `beta10`; it does not change the ordering here, which comes
    from versionCode.)
    """
    import re

    m = re.fullmatch(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?"
                     r"(?:-([a-z]+)\.?(\d+))?", version)
    if not m:
        raise ValueError("unrecognised version %r; expected M[.m[.p[.b]]][-pre[.]N]"
                         % version)
    major = int(m.group(1))
    minor = int(m.group(2) or 0)
    patch = int(m.group(3) or 0)
    build = m.group(4)
    pre = m.group(6)

    if build is not None and pre is not None:
        raise ValueError("%r carries both a fourth segment and a pre-release "
                         "number; they mean the same thing -- which build of "
                         "this version -- so give one or the other" % version)

    if build is not None:
        n = int(build)
        # 这里的 0 值得单独给一条消息而不是范围错误：产生它的
        # 合理途径是某构建工具把三段名字补齐成四段，
        # 那会把版本名和它的
        # versionCode 放到最终发布边界的两侧。
        if n == 0:
            raise ValueError("fourth segment is 0 in %r -- that is not a build "
                             "number, and it usually means something padded a "
                             "three-segment name; write the segment explicitly"
                             % version)
        # 这里拒绝 99，尽管它确实是最终发布槽位，因为
        # 接受它会让 `0.2.0.99` 成为 `0.2.0` 的第二种写法 -- 同一个
        # 版本两个名字，这正是"这是哪个构建"开始
        # 得到两个答案的原因。最终发布只有一种说法，就是
        # 不写这一段。
        if not 1 <= n <= 98:
            raise ValueError("build number %d out of range 1..98 (99 means the "
                             "final release -- write the version with no fourth "
                             "segment)" % n)
    elif pre is not None:
        n = int(pre)
        if not 1 <= n <= 98:
            raise ValueError("pre-release number %d out of range 1..98 (99 means "
                             "the final release)" % n)
    else:
        n = 99
    return major * 1000000 + minor * 10000 + patch * 100 + n


if version_code_for(APP_VERSION) != VERSION_CODE:
    raise SystemExit(
        "FAIL VERSION_CODE %d does not match %s (%d). Fix one of them:\n"
        "     APP_VERSION = %r\n"
        "     VERSION_CODE = %d"
        % (VERSION_CODE, APP_VERSION, version_code_for(APP_VERSION),
           APP_VERSION, version_code_for(APP_VERSION)))

ARTIFACT_NAME = "%s-v%s" % (APP_NAME, APP_VERSION)
BUNDLE_NAME = "com.haohandc.mindustryark"


# ---------------------------------------------------------------------------
# 这个构建发不发游戏本体
# ---------------------------------------------------------------------------
# ⭐ 它是 `master` 与 `lite` 分支之间**唯一**的一个代码开关。
#
#    master（默认，True）—— 包里带一份 Mindustry，开箱即玩。
#    lite（False）        —— 包里没有游戏，玩家自己提供 jar。
#
# 为什么是一个值，而不是让 lite 分支各自修改三个脚本
#
#     三个脚本里有三处【方向相反】的断言，而它们说的是同一件事：
#
#         scripts/prep_game.py        把游戏放进 entry/libs/  ←→ 保证那里没有
#         scripts/verify_hap.py §6    产物里【必须】有这个条目 ←→ 【必须没有】
#         scripts/make_payload_zip.py 载荷包里要求它            ←→ 不要求
#
#     硬删的话，这三处会在两个分支上各自演化，而它们必须一直相反 ——
#     这正是「同一份知识存在两处、其中一处先跑偏」的形态（本项目栽过多次）。
#     读同一个值，三个脚本就在两个分支上【逐字节相同】，
#     唯一的差异是这个常量本身。
#
# ⛔ 别把它做成环境变量。分支身份必须是【可提交的】：
#     环境变量在不同机器上、不同 shell 里可以不同，而
#     `python scripts/verify_hap.py` 的结论必须只由仓库内容决定。
SHIPS_GAME = True


# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------
def sha1f(path):
    """SHA-1 of a file on disk. Streamed, because several inputs are >100 MB."""
    import hashlib
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def require(path, what):
    """Fail loudly and early. A missing input that a script silently works around
    is how a build ends up shipping the previous artifact -- which this project
    has done twice."""
    if not os.path.exists(path):
        raise SystemExit("FAIL missing %s\n     %s\n"
                         "     set the matching ARK_* variable, or see "
                         "payload-src/README.md" % (what, path))
    return path


# --json 报告 / 下面打印的集合。分组是为了让人扫一眼就能看懂。
GROUPS = [
    ("DevEco / SDK", [
        ("DevEco Studio", DEVECO_STUDIO),
        ("SDK home", DEVECO_SDK_HOME),
        ("native SDK", NATIVE_SDK),
        ("hdc", HDC),
        ("node", NODE),
        ("hvigor", HVIGOR),
    ]),
    ("Host tools", [
        ("javac", JAVAC),
        ("jar", JAR),
        ("python", PYTHON if os.path.sep in PYTHON else "(from PATH: %s)" % PYTHON),
        ("temp", TMP),
    ]),
    ("Payload inputs", [
        ("upstream jar", UPSTREAM_JAR),
        ("patched jar", PATCHED_JAR),
        ("game jar (pinned)", GAME_JAR),
        ("Arc sources", ARC_SRC),
        ("LWJGL", LWJGL_SRC),
        ("JDK (slim)", JDK_SLIM),
    ]),
    ("Outputs", [
        ("native sources", CPP),
        ("payload dest", LIBS),
        ("hap output (product=%s)" % PRODUCT, OUT_DIR),
    ]),
]


def _main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    if "--json" in sys.argv:
        import json
        print(json.dumps({k: v for _, items in GROUPS for k, v in items}, indent=2))
        return 0

    print("project root: %s" % PROJECT_ROOT)
    print()
    missing = 0
    for title, items in GROUPS:
        print("[%s]" % title)
        for label, path in items:
            real = path if os.path.sep in path else ""
            if not real:
                print("  %-20s %s" % (label, path))
                continue
            ok = os.path.exists(path)
            if not ok:
                missing += 1
            # 必须存在的输入 vs 干净检出时预期不存在的
            # 输出 -- 把两者都报成 FAIL 会让读者
            # 学会无视这个词。
            expected = title != "Outputs"
            mark = "ok" if ok else ("MISSING" if expected else "not yet built")
            print("  %-20s %-4s %s" % (label, mark, path))
        print()

    if missing:
        print("%d input(s) missing -- see payload-src/README.md" % missing)
    return 0

# ---------------------------------------------------------------------------
# 自检：`SHIPS_GAME` 只允许赋值一次
# ---------------------------------------------------------------------------
# ⚠️ 为什么这条检查必须存在
#
#   2026-10-03：把 master 合并进 lite 时，git 把 master 那段注释连同
#   `SHIPS_GAME = True` 整块【追加】在 lite 的 `SHIPS_GAME = False` 后面。
#   合并没有报冲突，Python 也没有报错 —— 它只是取最后一个赋值，
#   于是 lite 分支静默地变回了 master：包里没有游戏，而开关说应该有。
#
#   拦住它的是 `verify_hap.py` 第 6 段，但那要等到构建之后。
#   `config.py` 是每个脚本每次都会 import 的 —— 在这里拦，
#   代价从「打出一个包、然后被闸门拒绝」变成「import 就停」。
#
#   ⛔ 这两个分支的这个开关是【相反】的，所以「重复赋值」在这里不是风格问题，
#   是分支身份问题。它值得一条专门的检查，而不是一句注释。
def _check_ships_game_once():
    n = 0
    with open(os.path.abspath(__file__), encoding="utf-8") as f:
        for line in f:
            if line.startswith("SHIPS_GAME"):
                n += 1
    if n != 1:
        raise SystemExit(
            "FAIL SHIPS_GAME is assigned %d times in this file -- it must be exactly once.\n"
            "     Python keeps the LAST assignment, so a duplicate silently picks one,\n"
            "     and the two branches set it to opposite values.\n"
            "     This is what a bad merge of master into lite looks like." % n)


_check_ships_game_once()

if __name__ == "__main__":
    sys.exit(_main())
