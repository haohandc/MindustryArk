# -*- coding: utf-8 -*-
r"""
把新编的 libarcarm64.so（带 SDL3 音频后端 + 全部 4 个类的 JNI 绑定）替换进 Mindustry.jar。

只替换 arm64-Linux 那一个原生库（`libarcarm64.so`），其余平台的库保持原样。

⚠️ 自检这次是【全量】的：上一次只查了 `Java_arc_audio_Soloud_` 这一类，
   而官方库其实有 83 个 Java_ 符号、覆盖 4 个类 —— 结果设备上一启动
   `NativeUtils.setEnv` 就 UnsatisfiedLinkError。
   现在逐个核对官方那 83 个符号是否都在新库里。
"""
import hashlib
import os
import re
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

# 路径一律可覆盖，且不含用户名（理由见 build.sh 顶部那段）。
# ⚠️ 这里沿用【历史位置】作默认值，是为了让行为不变；仓库自己的等价物在 payload-src/
#    （但两份 mindustry-1.0.jar 不是同一个构建：87085693 vs 87085754 字节），
#    要用仓库那份就显式设 ARK_SRC_JAR / ARK_OUT_JAR。
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
REF = os.path.join(os.path.dirname(REPO), "MindustryArkDocs")
TMPROOT = os.environ.get("ARK_TMP") or os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"
BUILD = os.environ.get("ARK_SOLOUD_BUILD") or os.path.join(TMPROOT, "soloudbuild")
SRC_JAR = os.environ.get("ARK_SRC_JAR") or os.path.join(REF, "mindustry-ohos", "mindustry-1.0.jar")
NEW_SO = os.path.join(BUILD, "libarcarm64_fixed.so")
OUT_JAR = os.environ.get("ARK_OUT_JAR") or os.path.join(REF, "mindustry-ohos", "mindustry-1.0-audio.jar")
OFFICIAL = os.path.join(TMPROOT, "arcjni", "official.so")
TARGET = "libarcarm64.so"


def java_syms(blob):
    """取 Java_ 符号名（.dynsym 的字符串就在文件里，直接扫足够可靠且不用外挂工具）"""
    return set(re.findall(rb"Java_[A-Za-z0-9_]+", blob))


def main():
    for p in (SRC_JAR, NEW_SO, OFFICIAL):
        if not os.path.isfile(p):
            raise SystemExit("找不到 %s" % p)

    new_data = open(NEW_SO, "rb").read()
    print("新 libarcarm64.so = %d 字节" % len(new_data))

    src = zipfile.ZipFile(SRC_JAR, "r")
    print("原 libarcarm64.so = %d 字节" % len(src.read(TARGET)))

    replaced = 0
    with zipfile.ZipFile(OUT_JAR, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            if item.filename == TARGET:
                dst.writestr(item, new_data)
                replaced += 1
            else:
                dst.writestr(item, src.read(item.filename))
    src.close()

    if replaced != 1:
        raise SystemExit("!! 替换次数 = %d，期望 1" % replaced)

    data = open(OUT_JAR, "rb").read()
    print()
    print("产物 = %s" % OUT_JAR)
    print("size = %d" % len(data))
    print("sha1 = %s" % hashlib.sha1(data).hexdigest())

    # ---------------- 自检 ----------------
    fails = []
    print()
    print("=" * 64)
    print("自检")
    print("=" * 64)

    with zipfile.ZipFile(OUT_JAR) as z:
        got = z.read(TARGET)
        names = z.namelist()

        ok = len(got) == len(new_data)
        print("  [1] 字节数一致 = %s" % ok)
        if not ok:
            fails.append("jar 里的 .so 长度不对")

        print("  [2] 含 SDL3 后端字符串 = %s" % (b"SDL3" in got))
        print("  [3] 不含 miniaudio = %s（用错后端会没声音）" % (b"miniaudio" not in got))
        if b"miniaudio" in got:
            fails.append("仍含 miniaudio")

        # ⭐ 全量 Java_ 符号核对 —— 上次就是漏在这里
        want = java_syms(open(OFFICIAL, "rb").read())
        have = java_syms(got)
        miss = sorted(s.decode() for s in want - have)
        extra = sorted(s.decode() for s in have - want)
        print("  [4] Java_ 符号：官方 %d 个，新库 %d 个" % (len(want), len(have)))
        print("       缺 = %s" % (miss if miss else "无 ✅"))
        print("       多 = %s" % (extra if extra else "无 ✅"))
        if miss:
            fails.append("缺 %d 个 Java_ 符号: %s" % (len(miss), miss[:5]))

        for cls in (b"Java_arc_audio_Soloud", b"Java_arc_util_Buffers",
                    b"Java_arc_util_NativeUtils", b"Java_arc_graphics_Pixmap"):
            n = len([s for s in have if s.startswith(cls)])
            print("       %-32s %2d 个  %s" % (cls.decode(), n, "✅" if n else "❌"))
            if not n:
                fails.append("类 %s 一个符号都没有" % cls.decode())

        print("  [5] mindustry 主类仍在 = %s" % ("mindustry/desktop/DesktopLauncher.class" in names))
        print("  [6] 原生库条目数 = %d" % len([n for n in names if n.endswith((".so", ".dll", ".dylib"))]))
        if "mindustry/desktop/DesktopLauncher.class" not in names:
            fails.append("主类不见了")

    print()
    print("结论：%s" % ("✅ 全部通过" if not fails else "❌ " + "; ".join(fails)))
    print("=" * 64)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
