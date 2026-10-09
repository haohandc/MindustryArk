# -*- coding: utf-8 -*-
r"""Place the game jar inside the HAP's library area, under a *.so name.

WHY A *.so NAME
    hvigor copies entry/libs/arm64-v8a/** into the HAP only for names ending in
    ".so"; content is never inspected. Measured on the built HAP: the 140 MB
    module image ships as jdk21/lib/jimg.so and the real JVM as libjvm_real.so,
    both at exactly their project sizes, while everything under jdk21/conf/ was
    dropped silently. A jar is no more of an ELF than the module image is, so it
    takes the same road. The JVM opens a class-path entry by content, not by
    name, so the extension is invisible to it.

WHY A SUBDIRECTORY
    The top-level names in libs/arm64-v8a/ are the ones the platform treats as
    the app's native libraries. A jar is not one. Placing it one level down
    matches where the module image already lives and is known not to be mapped.

WHY THIS IS A SCRIPT AND NOT A COPY COMMAND
    This file is derived from a versioned artifact that was itself the product of
    a multi-stage build (patch -> repack -> variant). This project has already
    shipped a wrong jar once, by re-running an upstream stage and forgetting a
    downstream one, and a stale library once more. So the source is identified by
    its SHA-1, not by its file name, and the result is verified after the copy.
    A mismatch aborts without touching the destination.

⭐ 两个方向，一个开关

    `config.SHIPS_GAME` 决定这个构建发不发游戏本体，而两个方向的断言是【相反】的：

        master（True）  把游戏放进 entry/libs/，并按 SHA-1 回验它落对了
        lite （False）  保证那里【没有】游戏 —— 发现残留就清掉（--check 时报 FAIL）

    ⛔ 为什么 lite 方向不是「把复制那几行删掉」：

        `entry/libs/` 是 gitignore 的工作区目录，**切分支不会动它**。同一个工作树
        从 master 切到 lite，那个 85 MB 的游戏 jar 还在原地，而
        `launcher.c` 的 `resolve_game_jar()` 会真的找到它并加载 —— lite 包
        会带着游戏跑起来，界面上看不出来。⇒ 必须有人主动清掉它，这个脚本
        就是那个人。反过来说：**删掉这个脚本，等于删掉「残留会被清掉」这件事本身。**

Usage:  python prep_game.py [--check]
        --check  verify only; do not copy (master) / do not remove (lite)
"""

import argparse
import hashlib
import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

PROJECT_ROOT = config.PROJECT_ROOT

# ⭐ 上游发布 jar，未修改 -- 与 Anuken 发布的内容逐字节一致。
#
# 2026-09-28 变更。这里以前复制音频修复过的变体，那是
# build_arc_patch.py -> patch_mindustry.py -> build_variants.py 的产物。在
# 当前架构下，这些都不会写进游戏 jar：我们的 Arc
# 改动作为单独的 jar 在 class path 上排在它前面发布（make_patch_jar.py、
# launcher.c 里的 PATCH_JAR），而 Arc natives 通过
# prep_arc.py 来自 bundle。所以放进游戏槽位的就是原始 jar。
#
# 因此下面的哈希标识的是一个上游产物，这比过去是更强的
# 陈述：两处哈希和文件名检查以前全都
# 指向我们自己的多阶段输出，链中任何一处出错都会
# 产生一个只有这个常量才能注意到的不同 jar。
SRC = config.UPSTREAM_JAR

# Mindustry v8 Build 160.7，官方桌面发布版。
#
# ⭐ 2026-10-09：SHA-1 → SHA-256。理由不是强度，是**便利**：上游 GitHub Release
#    的 asset 自带 `digest: "sha256:…"`，换版本时可以直接和它对，不必自己先算一遍。
#    【实测已核对】这份与 Anuken/Mindustry v160.7 那条 asset 的 digest 一致
#    （88677884 字节）。上一个版本 160.5 是 c2fd5a5d…（88902250）。
SRC_SHA256 = "36d94941a1639478ad1d9be25a9d802c6f77552f400c6da0338b7b019f63a0d1"

DEST = os.path.join(PROJECT_ROOT,
                    "entry", "libs", "arm64-v8a", "game", "mindustry.so")


def sha256_of(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def ship(check):
    """master：把钉住的那份 jar 放进 entry/libs/，并回验它落对了。"""
    if not os.path.isfile(SRC):
        print("FAIL source jar is missing: %s" % SRC)
        return 1

    actual = sha256_of(SRC)
    print("source : %s" % SRC)
    print("size   : %d" % os.path.getsize(SRC))
    print("sha256 : %s" % actual)
    if actual != SRC_SHA256:
        print("FAIL this is NOT the pinned artifact.")
        print("     expected %s" % SRC_SHA256)
        print("     This slot takes the upstream release byte-for-byte. Re-download it")
        print("     rather than building or patching a jar into it -- see the note on SRC.")
        return 1
    print("       -> matches the pinned upstream release")

    if check:
        if os.path.isfile(DEST):
            ok = sha256_of(DEST) == SRC_SHA256
            print("dest   : present, %s" % ("matches" if ok else "DIFFERS"))
            return 0 if ok else 1
        print("dest   : ABSENT")
        return 1

    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    shutil.copyfile(SRC, DEST)

    # 校验实际落盘的内容，而不是我们打算写入的内容。
    if sha256_of(DEST) != SRC_SHA256:
        print("FAIL the copy does not match the source; removing it")
        os.remove(DEST)
        return 1

    print("dest   : %s" % DEST)
    print("       : %d bytes, sha256 verified" % os.path.getsize(DEST))
    print("OK")
    return 0


def strip(check):
    """lite：保证 entry/libs/ 里【没有】游戏。

    ⚠️ 这里【不】碰 SRC。lite 上不需要那个上游 jar 存在 —— 这个脚本在 lite 上的
    职责是「确认那个槽位是空的」，而「确认空」不需要任何输入。要求 SRC 存在会
    让一个完全正常的工作树失败，而「在正确的工作树上失败的检查」和「在坏掉的
    工作树上通过的检查」是同一种缺陷：它会让读者学会忽略它。
    """
    if not os.path.isfile(DEST):
        print("game jar : absent, as intended")
        print("           %s" % DEST)
        return 0

    size = os.path.getsize(DEST)
    if check:
        print("FAIL a game jar is present: %s" % DEST)
        print("     %d bytes. This build must not ship one." % size)
        print("     Remove it: python scripts/prep_game.py")
        return 1

    os.remove(DEST)
    print("game jar : removed, %d bytes" % size)
    print("           %s" % DEST)
    print("           %s ships no game; the player supplies one." % config.APP_NAME)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    print("mode   : %s" % ("ship the game" if config.SHIPS_GAME
                           else "no game in the package"))
    if config.SHIPS_GAME:
        return ship(a.check)
    return strip(a.check)


if __name__ == "__main__":
    sys.exit(main())
