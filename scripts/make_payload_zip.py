# -*- coding: utf-8 -*-
r"""
Package the assembled payload as the release attachment.

    python scripts/make_payload_zip.py

WHY THIS IS A SCRIPT AND NOT A COMMAND SOMEONE RUNS BY HAND

    It was done by hand until 2026-09-22, and the shipped zip had already gone
    stale without anyone noticing: comparing the v0.2.0-beta.2 payload against the
    working tree showed it was MISSING 21 entries --

        20 x entry/libs/arm64-v8a/jdkhome/...   (produced by prep_jdkconf.py)
         1 x entry/libs/arm64-v8a/probe/probe-mod.jar.so   (no longer produced)

    and nothing extra. That is not a cosmetic difference. jdkhome/conf/security/
    java.security is what Security.<clinit> reads, and without it the JVM cannot
    define a class at runtime at all -- mod loading dies with
    "NoClassDefFoundError: java.security.Security". So anyone who built from the
    old payload got a package whose mods could not load, and the payload looked
    perfectly fine doing it.

    A hand-made zip of a directory that changes is a step that goes wrong
    silently, which is why this project's rule is that every step derived from
    another artifact gets a script with assertions. The assertions below are the
    point of the file; the zipping is incidental.

WHAT IT ASSERTS
    1. Before writing: the entries that have each broken a build at least once are
       present in entry/libs. A missing one is a hard stop with the producing
       script named, rather than a smaller zip nobody checks.
    2. After writing: the zip is reopened and the entry SET is compared against
       what was on disk. Equal or it fails. Writing a file and believing it
       landed is the mistake this whole script exists to prevent, so it is not
       repeated inside the script.

OUTPUT
    dist/<ARTIFACT_NAME>-payload.zip, named from scripts/config.py so the version
    cannot drift from the HAP's.
"""
import hashlib
import io
import os
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

PAYLOAD_README = "README-PAYLOAD.txt"

# 相对 config.LIBS 的路径 -> 为什么缺了它是致命的，或者它是谁产出的
#
# ⚠️ 不要加 "arm64-v8a/" 前缀：config.LIBS 已经以它结尾。两边都写会让
# 路径翻倍，这个文件的第一版就是这么干的 ——
# 断言在一个明明就在那里的文件上报错，这就是它被发现的方式。
# 在正确的工作树上失败的检查，和在坏掉的工作树上通过的检查是同一种缺陷：
# 它会让读者学会忽略它。
REQUIRED = {
    "jdk21/lib/jimg.so":
        "the module image (134 MB). Renamed from lib/modules by prep_jdklib.py -- "
        "java.base insists on the name 'modules' and will not accept anything else",
    "jdk21/lib/server/libjvm_real.so":
        "the real JVM. Without it the anchor libjvm.so has nothing to load",
    "jdkhome/conf/security/java.security.so":
        "Security.<clinit> reads this. MISSING IT MAKES EVERY RUNTIME CLASS "
        "DEFINITION FAIL, so mods cannot load -- run scripts/prep_jdkconf.py",
    "jdkhome/lib/security/cacerts.so":
        "the trust store. Without it TLS has no roots and networking fails "
        "in a way that looks like a server problem -- run scripts/prep_jdkconf.py",
    # ⛔ "game/mindustry.so" 【不在】上面这张字面量里 —— 按 config.SHIPS_GAME 在
    #    下面挂上/摘掉。理由与另外两处一样：这个条目在 master 上要求存在、在 lite 上
    #    要求存在会让【每一次】构建都失败，而同一条断言的两个方向说的是同一件事。
    # "probe/probe-mod.jar.so" 曾经也在这里要求，现在不再要求，因为
    # 它已经不再产出：tools/probe-mod/build.sh 不再把它安装进
    # libs/，因为每次启动把它拷进游戏 mods 目录的 ArkTS 代码
    # 已经随导入器其余部分一起删掉了。
    # 留着这条断言现在会在一个完全正常的工作树上失败 —— 而
    # 一个在正确的工作树上失败的检查，和一个在坏掉的树上通过的检查是同一种缺陷：
    # 它会让读者学会忽略它。
}

# ⭐ 游戏本体：master 要求它在载荷包里，lite 要求它【不】在 —— 见 config.SHIPS_GAME。
#    两臂都是断言。lite 上如果把这条留在上面那张表里，每一次构建都会停在
#    "MISSING: entry/libs/game/mindustry.so"，而那是一个【完全正常】的工作树。
if config.SHIPS_GAME:
    REQUIRED["game/mindustry.so"] = \
        "the game jar, renamed. The classpath points at it"

# 故意不做的断言：libmain.so 和 libSDL3.so。
#   它们出现在 HAP 的 libs/arm64-v8a/ 下，但它们是构建产物 ——
#   hvigor 从 CMake 树里取它们，"bash build.sh assembleHap"
#   会从源码重新生成这两个。在这里要求它们等于要求有人
#   把编译产物和他们编译所用的源码一起发出去，而
#   这个文件的第一版确实要求了 libmain.so，结果在一个完全正常的
#   payload 上停了下来。


def sha256f(path):
    h = hashlib.sha256()
    with io.open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def collect():
    """`entry/libs` 下的每个文件，返回 (绝对路径, zip 内的路径)。

    ⭐⭐ **基准是【仓库根】，不是 `entry/libs` 的父目录。** 这一行改了是修缺陷，
    不是改风格：以 `dirname(LIBS)` 为基准时 zip 的顶层是 `arm64-v8a/`，
    而 `dist/README-PAYLOAD.txt`（zip 里唯一带说明的文件）让人**在仓库根 unzip** ——
    那样会解出 `<仓库根>/arm64-v8a/`，**不是** `entry/libs/arm64-v8a/`，
    于是 `deploy.sh` 找不到 libs。实测过（2026-10-03）：

        unzip 在仓库根          -> <根>/arm64-v8a/            不对
        解到 entry/libs/ 里      -> entry/libs/arm64-v8a/     对

    ⭐ 以仓库根为基准之后，顶层就是 `entry/libs/`，README 里那句
    「在仓库根 unzip」**变成对的**，而且 `README-PAYLOAD.txt` 自己落在仓库根
    （它该在的地方），不会再被塞进 `entry/libs/`。
    ⚠️ 这与 v1.1.0.1 那份载荷的布局一致；1.2.0.1 / 1.3.0.1 用的是 `arm64-v8a/`，
    那两份里的 README 指令是坏的。
    """
    out = []
    root = config.LIBS
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, config.PROJECT_ROOT)
            out.append((full, rel.replace(os.sep, "/")))
    return out


def main():
    root = config.PROJECT_ROOT
    dist = os.path.join(root, "dist")
    os.makedirs(dist, exist_ok=True)

    if not os.path.isdir(config.LIBS):
        sys.exit("!! %s does not exist -- run the prep_* scripts first" % config.LIBS)

    # --- 1. 断言，在任何东西被写入之前 -----------------------
    print("checking the payload")
    for rel, why in sorted(REQUIRED.items()):
        full = os.path.join(config.LIBS, rel)
        if not os.path.isfile(full):
            sys.exit("!! MISSING: entry/libs/%s\n"
                     "   why it matters: %s\n"
                     "   refusing to write a payload that cannot build a working app"
                     % (rel, why))
        print("   ok  %-52s %8.1f MB" % (rel, os.path.getsize(full) / 1048576.0))

    readme = os.path.join(dist, PAYLOAD_README)
    if not os.path.isfile(readme):
        sys.exit("!! %s is missing -- it is the only documentation in the zip" % readme)

    files = collect()
    if not files:
        sys.exit("!! nothing under %s" % config.LIBS)

    # --- 2. 写入 -----------------------------------------------------------
    out = os.path.join(dist, "%s-payload.zip" % config.ARTIFACT_NAME)
    print("\nwriting %s" % os.path.basename(out))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.write(readme, PAYLOAD_README)
        for full, rel in files:
            z.write(full, rel)

    # --- 3. 重新打开并比对【集合】 ------------------------------------
    # 不是比数量：丢一个条目、多一个条目，数量照样对得上，
    # 而这正是当时手工发现的那种漂移的形态。
    print("verifying the written zip")
    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad is not None:
            sys.exit("!! the zip is corrupt at %s" % bad)
        got = set(z.namelist())
    want = set([PAYLOAD_README] + [rel for _full, rel in files])
    missing = sorted(want - got)
    extra = sorted(got - want)
    if missing or extra:
        sys.exit("!! the zip does not match the directory\n"
                 "   missing: %s\n   unexpected: %s" % (missing[:10], extra[:10]))

    size = os.path.getsize(out)
    print("   %d entries (excluding README), matches the directory exactly"
          % (len(got) - 1))
    print("   %.1f MB   sha256 %s" % (size / 1048576.0, sha256f(out)[:32]))
    print("\n%s" % out)
    print("\nAttach that file to the release. It is not needed to play -- it is what")
    print("someone needs to rebuild the HAP themselves.")


if __name__ == "__main__":
    main()
