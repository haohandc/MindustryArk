# -*- coding: utf-8 -*-
r"""
Gate: inspect the ACTUAL signed HAP and confirm the JDK shipped in the shape the
loader needs.

Rationale (the lesson that keeps recurring in this project): a successful build
message is not evidence about the bytes on disk. The earlier audio accident was
exactly this -- a library that was "rebuilt" but whose output file was never
re-linked, with the same filename as before. So every claim here is read out of
the packaged archive, not inferred from the build log.

Checks
  1. libs/arm64/libjvm.so exists and its DT_NEEDED is the ABSOLUTE device path
     to the real JVM (musl ignores RPATH/RUNPATH and does not expand $ORIGIN, so
     a bare name here would silently resolve to the stub instead of the JVM).
  2. libs/arm64/jdk21/lib/server/libjvm_real.so exists and exports
     JNI_CreateJavaVM.
  3. libs/arm64/jdk21/lib/jimg.so exists (the renamed module image -- the whole
     reason the jimage is called .so).
  4. libjvm_real.so's own DT_NEEDED resolve: libcxxabi_shim.so and libc.so.
  5. the patched module-name format string is present in libjvm_real.so.

ASCII-only output.
"""
import io
import os
import re
import subprocess
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = config.PROJECT_ROOT
READELF = config.READELF
NM = os.path.join(config.LLVM_BIN, "llvm-nm.exe")

DEVICE_JVM = "/data/storage/el1/bundle/libs/arm64/jdk21/lib/server/libjvm_real.so"
TMP = os.path.join(PROJECT_ROOT, "_hapcheck")


def find_hap():
    """Pick the artifact to inspect, deterministically.

    This used to take the newest .hap by mtime. Since setting artifactName in
    entry/build-profile.json5, hvigor writes TWO packages with the same
    timestamp -- <name>.hap (signed) and <name>-unsigned.hap -- so the newest
    one is decided by directory order, which is not a decision. The unsigned
    package is what gets verified: signing appends a signature block and does
    not change the payload being checked here, and preferring it means the check
    does not depend on which naming convention hvigor happens to be using.

    WHICH PRODUCT is config.OUT_DIR, i.e. ARK_PRODUCT, and it is never guessed.
    The build profile defines "default" and "release", whose outputs live in
    separate directories; a search rooted at entry/build/ would find both and
    then have to pick, and "newest" would quietly start verifying the other
    product the moment somebody built it. Enumerating only the requested
    product's directory means a store build cannot be checked by accident
    against the device build.
    """
    root = config.OUT_DIR
    hits = []
    for dp, _d, fs in os.walk(root):
        for f in fs:
            if f.endswith(".hap"):
                hits.append(os.path.join(dp, f))
    if not hits:
        # 这里必须写明产品和目录："没有 HAP" 和
        # "你要错了产品" 否则看上去一模一样，而本项目
        # 已经有过一轮盯着 entry/build/default/，
        # 而 release 构建其实躺在 entry/build/release/ 的教训。
        print("!! no .hap under %s" % root)
        print("   (ARK_PRODUCT=%s -- set ARK_PRODUCT=release for a store build)" % config.PRODUCT)
        return None

    # 只要当前版本。产品的输出目录是累积的：版本一升
    # 它也会留着上一版本的包，而 hvigor 并不会清理
    # 它们。把整个目录排序取第一个在这里不是平局裁决，
    # 而是抛硬币 -- 实测，`-v0.2.0-beta.2-` 排在
    # `-v0.2.0.2-` 之前，因为 `-` (0x2D) < `.` (0x2E)，于是被
    # 校验的会是那个陈旧构建，版本闸门接着就会
    # 为一个本不该打开的文件报出不匹配。
    #
    # 改成按 artifactName 过滤，失败信息才会说实话：
    # "这里没有这个版本的构建"，外加这里都有些什么。
    want = config.ARTIFACT_NAME
    hits.sort()
    mine = [p for p in hits if os.path.basename(p).startswith(want)]
    others = [p for p in hits if p not in mine]
    if others:
        print("   NOTE  %d .hap(s) here are a DIFFERENT version, ignored:" % len(others))
        for p in others:
            print("         %s" % os.path.basename(p))
    if not mine:
        print("!! no .hap for version %s under %s" % (config.APP_VERSION, root))
        print("   run: bash build.sh assembleHap --mode module "
              "-p product=%s -p buildMode=<debug|release>" % config.PRODUCT)
        return None
    unsigned = sorted(p for p in mine if p.endswith("-unsigned.hap"))
    if unsigned:
        return unsigned[0]
    return mine[0]


def check_version_matches_name(hap, ok_ref):
    """The file name, the artifactName and the packaged version must all agree.

    A download whose name says one version and whose contents say another is
    worse than one with no version in the name at all -- and the three places
    that carry the version are edited at different times:

        AppScope/app.json5                     versionName
        entry/build-profile.json5              targets[].output.artifactName

    so "I remember changing them together" is not a safe assumption. The
    artifactName is read back out of pack.info rather than out of the build
    profile, which is the difference between checking what was built and
    checking what we intended to build.

    deploy.sh used to keep a third hand-written copy as HAP_BASE. It is no longer
    listed here because it no longer exists: that copy went stale at the
    v0.1.0-beta1 -> v0.2.0-beta.1 bump -- this docstring named it, nothing checked
    it, and the script ended up looking for a HAP that had been renamed -- so
    deploy.sh now asks config.ARTIFACT_NAME for the name instead. Two copies that
    both get checked beat three where one is only mentioned.

    String comparison throughout: a rename that is not also a version bump fails
    too, because the file name is the only part of this a downloader can see.
    """
    print("== 0. version in the file name vs. in the package ==")
    import json
    import zipfile

    name = os.path.basename(hap)
    with zipfile.ZipFile(hap) as z:
        info = json.loads(z.read("pack.info").decode("utf-8"))

    ver = info["summary"]["app"]["version"]["name"]
    code = info["summary"]["app"]["version"]["code"]
    packname = info["packages"][0]["name"]
    ver_want = config.APP_VERSION
    code_want = config.VERSION_CODE
    name_want = config.ARTIFACT_NAME

    print("   file name       %s" % name)
    print("   artifactName    %s   (in pack.info)" % packname)
    print("   versionName     %s   (config: %s / %s)"
          % (ver, ver_want, name_want))
    print("   versionCode     %s   (config: %s)" % (code, code_want))

    problems = []
    if packname != name_want:
        problems.append("artifactName %r != config.ARTIFACT_NAME %r"
                        % (packname, name_want))
    if ver != ver_want:
        problems.append("versionName %r != config.APP_VERSION %r"
                        % (ver, ver_want))
    # versionCode 是平台给安装排序的依据，也是这些里唯一
    # 会静默失败的：code 太低不会报错，它只是
    # 拒绝替换已安装的构建。校验时比对的是由 versionName
    # 推导出的值，而不只是常量 -- 所以只改了一个没改另一个的
    # 版本升级会在这里被抓住，而不是在设备上。
    if code != code_want:
        problems.append("versionCode %r != config.VERSION_CODE %r"
                        % (code, code_want))
    derived = config.version_code_for(ver)
    if code != derived:
        problems.append("versionCode %r != %d, which is what versionName %r "
                        "derives to" % (code, derived, ver))
    if not name.startswith(name_want):
        problems.append("file name %r does not start with %r" % (name, name_want))
    if name not in (name_want + ".hap", name_want + "-unsigned.hap"):
        problems.append("unexpected artifact name %r -- expected %r or %r"
                        % (name, name_want + ".hap", name_want + "-unsigned.hap"))
    for p in problems:
        print("   MISMATCH  %s" % p)
    print("   %s" % ("OK" if not problems else "FAIL"))
    print()
    if problems:
        ok_ref[0] = False


def run(tool, *args):
    r = subprocess.run([tool] + list(args), capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.stdout + r.stderr


# ==========================================================================
# tools 形态（「管理工具」包）—— 一个**只有本形态才有**的独立闸门。
#
# 为什么它值得单独一段而不是给每一节加一个 `if`：下面的 1–8 节全部是在
# 校验「JVM 装载链」和「游戏的 Arc/LWJGL」这两条链的字节，而 tools 形态
# **把这两条链整个拿掉**。给 8 个地方各加一个取反的 if，等于把
# 「这个形态是什么」埋进 8 个分散的否定里；而它自身的性质其实很短：
# **包里只有 CMake 自己编出来的那几个库，别的什么都没有。**
# ==========================================================================

# tools 形态下**允许**出现在 libs/ 下的条目。
#
# ⭐ 这是一份**白名单**，不是「禁用清单」。这个区别是承重的：
#    禁用清单只挡得住你**想到**的东西（JDK、游戏 jar、Arc、LWJGL），
#    而白名单挡住的是一切**没想到**的 —— 一个漏掉的 JDK 文件、一个放错位置
#    的 stash、hvigor 收集规则变了导致多带的东西。tools 形态的全部意义
#    就是「它很小、且它没有运行时」，而这两件事只有白名单能保住。
#
# ⚠️ 为什么是这几个而不是更少：下面每一个都被 ArkTS **无条件 import**
#    （或由 SDL3 在挂载时 dlopen），少一个就是应用起不来。
#    `libmain.so` 是唯一的例外：XComponent 不建时它不会被 dlopen，
#    但它是 CMake 的产物、拿掉它反而要动构建 ⇒ 留着，代价 0.04 MB。
#
# ⭐ 这份清单是**对着实测产物列的**，不是推的。第一次跑 tools 构建时
#    它只有 6 项，闸门当场拦下一个我没想到的 `libc++_shared.so`
#    （NDK 的 C++ 运行时，SDL3 是 C++ 所以被 native 构建带进来）。
#    ⇒ **这不是闸门误报，这正是白名单存在的意义**：清单只挡得住想到的东西。
TOOLS_ALLOWED_LIBS = (
    "libs/arm64-v8a/libSDL3.so",       # EntryAbility 的 `import sdl from 'libSDL3.so'`
    "libs/arm64-v8a/libc++_shared.so", # NDK 的 C++ 运行时（SDL3 是 C++）
    "libs/arm64-v8a/libmain.so",       # CMake 产物（launcher.c），见上
    "libs/arm64-v8a/libshield.so",     # Index.ets 的 import
    "libs/arm64-v8a/libjarver.so",     # GameLibrary 的 import
    "libs/arm64-v8a/libsavemeta.so",   # SaveLibrary 的 import
    "libs/arm64-v8a/libstorprobe.so",  # StorageRoot 的 import
)

# tools 形态产物的体积上限（字节）。
#
# ⚠️ **这个数字是实测来的，不是拍的**：2026-10-03 的 tools 产物是
#    **3.6 MB**（libs/ 合计 3.12 MB，最大一项 libSDL3.so 1.84 MB）；
#    而完整包是 **265.9 MB**。
# ⇒ 取 10 MB：比实测高约 2.8 倍（构建选项的微小变化、或将来多一个
#    小库都不会误报），比完整包低约 26 倍。**不是边界值**，所以它不会
#    变成那种「每次都报 FAIL、于是大家学会忽略它」的检查。
# ⚠️ 若将来这个包合理地长到接近 10 MB，**要连实测值一起改**，并说明为什么——
#    不要只把数字调大让它过去。
# 它挡的是三条用别的方式都很难发现的回归：有人跑了 prep_vendor.py 把
# libjvm.so 造了回来；stash 放错位置导致它的 .so 被打进包；
# hvigor「只收 .so」这条规则变了。三者都不会让别的闸门响。
TOOLS_MAX_BYTES = 10 * 1024 * 1024


def check_tools_form(hap, ok_ref):
    """`ARK_FORM=tools` 专用的检查。返回进程退出码。"""
    print("== form: tools (a management tool -- no JVM, no game) ==")
    print("   ARK_FORM=tools was passed to this build, so the whole JVM and game")
    print("   chains are expected to be ABSENT. See scripts/config.py's FORM block.")
    print()

    ok = ok_ref[0]
    with zipfile.ZipFile(hap) as z:
        names = z.namelist()

        # ① 白名单：libs/ 下除了允许的那几个，一个都不许有。
        #    用「前缀 + 不在允许集里」来判，所以它同时覆盖 jdk21/、game/、
        #    arc/、lwjgl*/、patchjar/、jdkhome/ 以及顶层那两个 .so。
        present = [n for n in names if n.startswith("libs/")]
        unexpected = sorted(p for p in present if p not in TOOLS_ALLOWED_LIBS)
        print("== tools-1. nothing but the built libraries ==")
        for p in TOOLS_ALLOWED_LIBS:
            print("   %-8s %s" % ("OK" if p in names else "MISSING", p))
        if unexpected:
            print("   !! %d unexpected entries under libs/:" % len(unexpected))
            for p in unexpected[:20]:
                print("      %s" % p)
            if len(unexpected) > 20:
                print("      ... and %d more" % (len(unexpected) - 20))
            print("   This build must not carry a runtime. If you ran")
            print("       python scripts/prep_vendor.py")
            print("   (or any other prep_* script) after the stash step, that is why.")
            ok = False
        else:
            print("   no unexpected entries under libs/   OK")
        # 缺失的那几个也要报（`present` 只说明「没有多的」，不说明「没少的」）
        missing = [p for p in TOOLS_ALLOWED_LIBS if p not in names]
        if missing:
            print("   !! MISSING, and ArkTS imports these unconditionally:")
            for p in missing:
                print("      %s" % p)
            ok = False
        print()

    # ② 体积闸门。⚠️ 建在**产物**上（读归档），不是读目录 ——
    #    「目录里有没有东西」与「包里有什么」是两件事，本项目为此有过教训。
    size = os.path.getsize(hap)
    print("== tools-2. the artifact is small ==")
    print("   %d bytes (%.1f MB), limit %.1f MB"
          % (size, size / 1048576.0, TOOLS_MAX_BYTES / 1048576.0))
    if size > TOOLS_MAX_BYTES:
        print("   !! OVER the limit -- something big got in. The full package is")
        print("      ~266 MB, so this is not a marginal miss: a runtime is present.")
        ok = False
    else:
        print("   under the limit   OK")
    print()

    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main():
    hap = find_hap()
    if not hap:
        print("no .hap found -- build first")
        return 1
    print("HAP: %s" % hap.replace(HERE + os.sep, ""))
    print("     %d bytes" % os.path.getsize(hap))
    print()

    # 收进一个列表，好让辅助函数能标出失败而无需
    # 通过返回值层层传递。这项检查放最前，因为名称和
    # 版本不一致会让后面所有内容描述的都是错误的构建。
    ok_ref = [True]
    check_version_matches_name(hap, ok_ref)

    # tools 形态走**自己那一段**并就地返回，不再往下走 1–8 节。
    # ⛔ 不要改成「在每一节里加 if」：那 8 节校验的是 JVM 装载链与游戏链的字节，
    #    而 tools 形态把这两条链整个拿掉了 —— 用 8 个分散的否定去表达
    #    「这个形态是什么」，会把它的性质埋掉，也更容易漏掉一节。
    if config.IS_TOOLS:
        return check_tools_form(hap, ok_ref)

    os.makedirs(TMP, exist_ok=True)
    with zipfile.ZipFile(hap) as z:
        names = z.namelist()
        # 1) 到底哪些进了包
        want = {
            "anchor": "libs/arm64-v8a/libjvm.so",
            "realjvm": "libs/arm64-v8a/jdk21/lib/server/libjvm_real.so",
            "jimage": "libs/arm64-v8a/jdk21/lib/jimg.so",
            "shim": "libs/arm64-v8a/libcxxabi_shim.so",
            "sdl": "libs/arm64-v8a/libSDL3.so",
            "mainso": "libs/arm64-v8a/libmain.so",
            # [A] 我们自己写的三个 NAPI 模块。⚠️ 2026-10-02 才发现它们一直【不在】
            # 这份清单里 —— 也就是说闸门从来没检查过它们，而 CMake 改坏、它们没被编出来时，
            # 构建照样 PASS。⭐ 清单是「必须存在」的清单，漏一项就等于漏一道闸门。
            "shield": "libs/arm64-v8a/libshield.so",
            "jarver": "libs/arm64-v8a/libjarver.so",
            "savemeta": "libs/arm64-v8a/libsavemeta.so",
        }
        # libcxxabi_real.so 不再列在这里是故意的：手写的
        # shim 替换已于 2026-09-19 移除（见 CMakeLists.txt）。
        print("== 1. presence in the archive ==")
        missing = []
        for label, p in want.items():
            ok = p in names
            if not ok:
                missing.append(label)
            print("   %-9s %-6s %s" % (label, "OK" if ok else "MISSING", p))

        n_jdk = len([n for n in names if n.startswith("libs/arm64-v8a/jdk21/")])
        n_so = len([n for n in names
                    if n.startswith("libs/arm64-v8a/jdk21/") and n.endswith(".so")])
        print("   jdk21 entries: %d   of which *.so: %d" % (n_jdk, n_so))
        print()

        if missing:
            print("!! missing: %s" % ", ".join(missing))
            return 1

        # 只解压我们需要检查的那部分
        for label, p in want.items():
            dst = os.path.join(TMP, label + ".so")
            with z.open(p) as src, open(dst, "wb") as out:
                out.write(src.read())

    print("== 2. anchor: DT_NEEDED must be the absolute device path ==")
    anchor = os.path.join(TMP, "anchor.so")
    out = run(READELF, "-d", anchor)
    needed = [l.strip() for l in out.splitlines() if "NEEDED" in l]
    for l in needed:
        print("   %s" % l)
    got = DEVICE_JVM in out
    print("   contains the device path: %s" % ("YES" if got else "NO"))
    print()

    print("== 3. real libjvm: exports + module-image patch ==")
    real = os.path.join(TMP, "realjvm.so")
    out_n = run(NM, "-D", "--defined-only", real)
    has_create = re.search(r"\bJNI_CreateJavaVM\b", out_n) is not None
    print("   exports JNI_CreateJavaVM : %s" % ("YES" if has_create else "NO"))
    out_d = run(READELF, "-d", real)
    for l in out_d.splitlines():
        if "NEEDED" in l or "SONAME" in l:
            print("   %s" % l.strip())
    blob = open(real, "rb").read()
    # 模块镜像的改名补丁：改后的格式串里是 jimg.so，改之前是 modules。
    #
    # 这里原来是两个只 print、不参与判定的布尔值 —— 也就是第 5 条检查
    # （本文件开头 docstring 自己列的那一条）**恒真**。后果很具体：一个**没打过补丁**
    # 的 libjvm_real.so（运行时找不到那个改名成 jimg.so 的模块镜像）只要还导出
    # JNI_CreateJavaVM 且 .dynamic 完整，就会打出 RESULT: PASS。
    #
    # 这正是本项目反复记下的那一条：「每次都报 PASS 的检查等于没有检查」。
    # 而它对着的是整个自建启动器最核心的那个补丁，所以这个洞比它看起来贵。
    img_ok = (b"%s%slib%sjimg.so" in blob) and (b"%s%slib%smodules" not in blob)
    print("   '%s' present  : %s" % ("%s%slib%sjimg.so",
                                     b"%s%slib%sjimg.so" in blob))
    print("   old 'modules' gone : %s" % (b"%s%slib%smodules" not in blob))
    # SONAME 的**值**也要是 libjvm.so（锚库靠它被找到）——
    # 原来 dyn_ok 只要求存在 (SONAME) 这个 tag，不要求它的值，所以这一行也是只 print。
    soname_ok = ("(SONAME)" in out_d) and ("libjvm.so" in out_d)
    print("   dynamic: SONAME is libjvm.so      : %s" % soname_ok)

    # 动态表必须是完整的，而不只是能解析。一个只检查
    # "我改的字符串改了没" 的闸门曾经过关，而 23 个条目 --
    # 包括 121,769 个重定位 -- 已经悄悄消失，该库
    # 根本加载不了。所以要数条目并强制要求关键 tag 存在。
    n_entries = out_d.count("(NEEDED)") + out_d.count("(SONAME)")
    for tag in ("(RELA)", "(JMPREL)", "(SYMTAB)", "(STRTAB)", "(GNU_HASH)", "(INIT)"):
        n_entries += out_d.count(tag)
    print("   dynamic: required tags found      : %d" % n_entries)
    # ⚠️ `soname_ok` 收进来（原来那行只是又一次 print 了同一个判断）。
    dyn_ok = (soname_ok and "(RELA)" in out_d and "(JMPREL)" in out_d
              and "(SYMTAB)" in out_d and "(STRTAB)" in out_d
              and "(GNU_HASH)" in out_d)
    print()

    print("== 4. sanity: nothing absolute-and-wrong anywhere in the anchor ==")
    bad = [l for l in needed if "/" in l and DEVICE_JVM not in l]
    print("   offending NEEDED entries: %d" % len(bad))
    print()

    # shim 必须是 JDK 自带的那份，逐字节一致。AMCL -- 在这台
    # 设备上用同一个 libjvm.so 能跑 -- 用的就是这个文件，而
    # 放弃我们那份替换的全部意义就是不作出头的异类。哈希是
    # 唯一不会被"同名文件存在"骗过的检查。
    print("== 5. the shipped C++ shim is the unmodified JDK one ==")
    import hashlib
    # ⚠️ 接受两个值而不是一个，原因是一个 buildMode 决定。
    #
    # entry/build-profile.json5 里名为 "release" 的 buildOptionSet 条目设了
    # strip:true，它会覆盖 target 级的 strip:false -- 实测，不是
    # 假设：同一棵树在 buildMode=debug 下给出带 .symtab 的 libjvm_real.so
    # 25,322,128 B，而在 buildMode=release 下两者都没有，为
    # 20,108,408 B。所以一个包的 native 字节取决于它由哪个 buildMode
    # 产出，只接受其中之一的闸门会在另一个上 FAIL。
    #
    # 两个都接受才是诚实的做法：要校验的命题是"这些是
    # 我们组装出来的字节，不是别的东西"，而它对两者都成立。一个
    # 会在正确包上失败的闸门只会教人忽略它。
    #
    # 不接受的是未知值 -- 那仍然是 MISMATCH，并且
    # 失败时会打印哈希以便辨识。
    WANT_SHIM = (
        "b605f5863ca1a75170a814ab4054a9867c346e15",   # buildMode=debug，未 strip
        "ceff66f064a4fee9837b7ea1a2cd9e5997db1d80",   # buildMode=release，已 strip
    )
    shim_path = os.path.join(TMP, "shim.so")
    got_shim = hashlib.sha1(open(shim_path, "rb").read()).hexdigest()
    print("   expected %s" % " or ".join(WANT_SHIM))
    print("   actual   %s   %s" % (got_shim, "OK" if got_shim in WANT_SHIM else "MISMATCH"))
    print()

    # ==================================================================
    # 6. 游戏本体 —— 方向由 config.SHIPS_GAME 决定，两臂都是硬闸门。
    #
    #   master（True）条目【必须】在，且必须逐字节等于钉住的那一份 -- 所以对
    #                 它们做哈希。大小检查对未打补丁的 jar 会过关、对
    #                 「重跑上游阶段却漏了下游阶段」的 jar 也会过关，而本项目
    #                 已经这样发出去过一个错误的 jar。
    #                 （这个 jar 以 ".so" 之名发运（见 prep_game.py），意味着
    #                  工具链里没有任何东西会解析它：hvigor 不，打包器不，
    #                  安装器也不。一直到设备上它都是不透明的字节 -- 所以
    #                  哈希是唯一有意义的判据。流式读，不写下 87 MB 的副本只为删掉。）
    #
    #   lite（False） 条目【必须不在】-- 它一旦出现，说明上一次 master 构建的
    #                 残留进了包：entry/libs/ 是 gitignore 的工作区目录，
    #                 切分支不会动它，于是那个 85 MB 的 jar 会原地留下并被装进包。
    # ==================================================================
    GAME_ENTRY = "libs/arm64-v8a/game/mindustry.so"
    if config.SHIPS_GAME:
        print("== 6. the game jar, hashed as packaged ==")
        import hashlib
        # ⭐ 上游原版 jar，未修改 -- 所以这是关于 Anuken 发布的
        # 文件的陈述，而不是关于我们自己构建产物的。见
        # prep_game.py 里的说明。2026-09-28 更改；它曾固定的是我们多阶段的变体。
        WANT_GAME = "8e0fd5d7dd7828fccff59a693a635948883a704b"
        game_ok = False
        with zipfile.ZipFile(hap) as z:
            if GAME_ENTRY not in z.namelist():
                print("   MISSING from the archive: %s" % GAME_ENTRY)
            else:
                h = hashlib.sha1()
                n = 0
                with z.open(GAME_ENTRY) as src:
                    while True:
                        b = src.read(1 << 20)
                        if not b:
                            break
                        h.update(b)
                        n += len(b)
                got_game = h.hexdigest()
                game_ok = got_game == WANT_GAME
                print("   entry : %s" % GAME_ENTRY)
                print("   bytes : %d" % n)
                print("   expect: %s" % WANT_GAME)
                print("   actual: %s   %s" % (got_game, "OK" if game_ok else "MISMATCH"))
    else:
        print("== 6. the game jar, absent as intended ==")
        game_ok = True
        with zipfile.ZipFile(hap) as z:
            if GAME_ENTRY in z.namelist():
                print("   PRESENT, and this build must not ship one:")
                print("   %s" % GAME_ENTRY)
                print("   A master build left it in entry/libs/. Run:")
                print("       python scripts/prep_game.py")
                game_ok = False
            else:
                print("   absent  %s" % GAME_ENTRY)
    print()

    # ==================================================================
    # 6b. 补丁 jar。
    #
    # 按 2026-09-28 采用的架构，我们的 Arc 类不再
    # 写进游戏 jar；它们走一个单独的 jar，由启动器
    # 在 -Djava.class.path 上放在它前面。这让游戏 jar 保持原封
    #（步骤 6 固定它），并把我们的类放到一个新地方 -- 意味着
    # 它们所在之处需要自己的闸门，否则一个忘了包含
    # 它们的构建根本不会被任何东西发现。游戏仍会启动：它只是
    # 会跑上游的 SDL2 后端，而那个后端在这里加载不了自己的
    # libSDL2，于是这个失败看上去什么都不像，就是不像缺了个 jar。
    #
    # 检查三件事，按具体程度排序：
    #   * 条目存在且确实是个 jar
    #   * 只存在于我们后端的类在它里面
    #   * 还有一个带着我们所作改动的类（换个名字会让第一项
    #     检查照样过关，而补丁其实什么都没做）
    # ==================================================================
    print("== 6b. the Arc patch jar ==")
    PATCH_ENTRY = "libs/arm64-v8a/patchjar/arcpatch.so"
    # 只存在于我们后端的类。它们缺席意味着 jar 是用收窄过的
    # 源码集构建的 -- 这是本项目真犯过的错，见
    # build_arc_patch.py 里关于 SdlConfig 的说明。
    PATCH_MUST_EXIST = [
        "arc/backend/sdl/GLBootstrap.class",
        "arc/backend/sdl/GLDiag.class",
        "arc/backend/sdl/GLDispatchFix.class",
    ]
    # 一个我们改过的类，以及只有改后的版本才含有的字符串。
    PATCH_MARKER = ("arc/graphics/gl/GLVersion.class", b"(Ljava/lang/CharSequence;)Z")
    patch_ok = False
    with zipfile.ZipFile(hap) as z:
        if PATCH_ENTRY not in z.namelist():
            print("   MISSING from the archive: %s" % PATCH_ENTRY)
        else:
            blob = z.read(PATCH_ENTRY)
            print("   entry : %s" % PATCH_ENTRY)
            print("   bytes : %d" % len(blob))
            if blob[:2] != b"PK":
                print("   NOT a jar -- first two bytes are %r, expected PK" % blob[:2])
            else:
                inner = zipfile.ZipFile(io.BytesIO(blob))
                names = inner.namelist()
                print("   classes in it: %d" % len(names))
                missing = [n for n in PATCH_MUST_EXIST if n not in names]
                cls, marker = PATCH_MARKER
                if missing:
                    print("   MISSING classes: %s" % ", ".join(missing))
                elif cls not in names:
                    print("   MISSING: %s" % cls)
                elif marker not in inner.read(cls):
                    print("   %s does not carry the change (%r)" % (cls, marker))
                else:
                    patch_ok = True
                    print("   our classes are present and carry the change   OK")
    print()

    # ==================================================================
    # 7. LWJGL -- jar 和 native，两者都在且字节都正确。
    #
    # 理由与上面的游戏 jar 相同：Java 那半改名成 ".so" 发运，
    # native 那半对链上每个工具都不透明，所以两者都不被
    # 除它之外的任何东西校验。两半之间的版本不匹配
    # 就是它防的那个具体失败 -- 它们来自两个不同
    # 来源，且只会在设备上的第一次调用时才失败。
    # ==================================================================
    print("== 7. LWJGL payload ==")
    # lwjgl/libSDL3.so 被故意排除在这张表之外，也从 HAP 里排除。
    # 那里曾有过第二个 SDL3，取自一个预构建的 HarmonyOS 应用，
    # 而本项目是自己从 entry/src/main/cpp/SDL/ 构建到 bundle 顶层的。
    # org.lwjgl.librarypath 先列 bundle，且实测
    # 解析到的是 bundle 里那份，所以 lwjgl/ 那份永远到不了 --
    # 一个进程里同一库有两份，是本项目已经
    # 被咬过一次的隐患。见 prep_lwjgl.py。顶层
    # libs/arm64-v8a/libSDL3.so 的存在性在步骤 1 检查；它的哈希
    # 不固定，因为它是在这里构建的，固定它会在任何
    # 合法重建上失败，而不是在错误上失败。
    LWJGL = {
        "libs/arm64-v8a/lwjgl/liblwjgl.so":
            "663e5cab870ac3427cbfbe01f93facbc260fa504",
        "libs/arm64-v8a/lwjgl/liblwjgl_opengl.so":
            "f3661e892d4d2deb3aa574cab2e64c13b7ac6b4d",
        "libs/arm64-v8a/lwjgl-java/lwjgl.so":
            "cd7dd7a13abce9a2764364f58e138c6f99f50a7f",
        "libs/arm64-v8a/lwjgl-java/lwjgl-opengl.so":
            "27698e706465a088d4c8eda34f98d69e5c8b32f7",
        "libs/arm64-v8a/lwjgl-java/lwjgl-sdl.so":
            "96d577ef9b661fe4bb9bfb32fbb1de3ff34219cd",
    }
    # Arc 自己的 native 库。它们随包发运，而不是让 Arc 在
    # 运行时解压，因为解压出来的那份无法 dlopen -- 见 prep_arc.py。
    # 同样的闸门，同样的理由：下游没有任何东西校验这些字节。
    ARC = {
        "libs/arm64-v8a/arc/libarcarm64.so":
            "db9d78b196beaa237a153b622b781e06be973462",
        # 不是 jar 里那份：那份是 glibc 的，在这里加载不了。这是
        # Arc 的 Android 构建，其布局依赖已被改指向 libc.so；
        # 见 prep_freetype.py。哈希和 jar 里那份不同是故意的。
        # 两种 strip 状态都要，理由同上面的 WANT_SHIM。这两个也放在
        # libs/ 下，所以 release buildMode 也会 strip 它们。
        "libs/arm64-v8a/arc/libarc-freetypearm64.so": (
            "004df783590ce27c79396a6432cfb9820538db7c",   # debug
            "41537d6980215a0921b403a223c2a9ea1ec04f26",   # release
        ),
        "libs/arm64-v8a/arc/libarc-filedialogsarm64.so": (
            "0ac27bdfd455ed1190ff9ba0ce97c7ddeb0cc049",   # debug
            "f4f4e8290acf21453d6fef5aa254790897d3b866",   # release
        ),
    }
    LWJGL.update(ARC)
    # JDK 的时区数据库，以 .so 之名发运，理由和
    # 模块镜像一样：hvigor 只携带以 ".so" 结尾的名字，而
    # java.base 正是按这个确切名字打开 "tzdb.dat"。没有它游戏就
    # 起不来 -- 见 prep_jdklib.py。
    LWJGL["libs/arm64-v8a/jdk21/lib/tzdb.so"] = \
        "330a69ed889539d7b8f9ec8bcb00f49b5ee2895d"

    # 启动器自己的 helper jar 做结构检查而不是哈希检查：
    # 它在每次 prep 运行时从源码编译，而 jar 带时间戳，
    # 所以同一份源码每次产出的文件都不同。要紧的是
    # 它应该携带的类确实在 HAP 里那份的里面。
    print("== 8. the launcher helper jar ==")
    # NOTE  `import io` 曾在这里，直到 2026-09-29 必须移除：Python 会判定一个
    # 名字在整函数内都是局部名，只要该函数任何位置出现对它的 import，
    # 所以这一行让 `io` 成了 main() 的局部名，顶层
    # import 不可见 -- 先执行的 6b 段死于
    # "cannot access local variable 'io'"。文件顶部的 import
    # 覆盖这里的每一处使用。
    helper_entry = "libs/arm64-v8a/launcher/helper.so"
    helper_class = "com/haohandc/launcher/NativeLoader.class"
    helper_ok = False
    with zipfile.ZipFile(hap) as z:
        if helper_entry not in z.namelist():
            print("   MISSING  %s" % helper_entry)
        else:
            blob = z.read(helper_entry)
            try:
                with zipfile.ZipFile(io.BytesIO(blob)) as inner:
                    helper_ok = helper_class in inner.namelist()
            except zipfile.BadZipFile:
                print("   NOT A JAR -- packaging corrupted it")
            print("   %-9s %s  %s"
                  % ("OK" if helper_ok else "FAIL", helper_entry,
                     "carries " + helper_class if helper_ok else ""))
    print()
    lwjgl_ok = True
    with zipfile.ZipFile(hap) as z:
        present = set(z.namelist())
        for entry, want in LWJGL.items():
            if entry not in present:
                print("   MISSING  %s" % entry)
                lwjgl_ok = False
                continue
            h = hashlib.sha1()
            with z.open(entry) as src:
                while True:
                    b = src.read(1 << 20)
                    if not b:
                        break
                    h.update(b)
            got_h = h.hexdigest()
            # `want` 要么是一个哈希，要么是被接受值的元组。
            ok_h = got_h in (want if isinstance(want, tuple) else (want,))
            lwjgl_ok = lwjgl_ok and ok_h
            print("   %-9s %-42s %s"
                  % ("OK" if ok_h else "MISMATCH", entry.split("/")[-1],
                     "" if ok_h else got_h))
    print()

    # ⛔ `img_ok` 是必须的：模块镜像改名那个补丁**只有它**在把关。
    #    在它进来之前，第 5 条检查只 print、不参与判定 ⇒ **恒真**
    #    （一个没打补丁的 libjvm_real.so 照样 PASS）。
    ok = (got and has_create and img_ok and not bad and got_shim in WANT_SHIM and dyn_ok
          and game_ok and patch_ok and lwjgl_ok and helper_ok and ok_ref[0])
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
