# -*- coding: utf-8 -*-
r"""
为 Arc 里【全部 4 个】含 native 方法的文件生成 JNI 绑定，并立刻与官方 libarcarm64.so 的
`Java_*` 符号集做【全量】比对。

⚠️ 教训：上一次只比了 Soloud 那 66 个就下结论"零差异"，而官方其实是 83 个符号、
   覆盖 4 个类 —— 设备上一启动就 UnsatisfiedLinkError。
   所以这次的验收判据是【完整的 Java_ 符号集】，不是自己关心的那一类。
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_jni

# 路径一律可覆盖，且不含用户名（理由见 build.sh 顶部那段）
_TMPROOT = os.environ.get("ARK_TMP") or os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"
_BUILD = os.environ.get("ARK_SOLOUD_BUILD") or os.path.join(_TMPROOT, "soloudbuild")
_SDK = os.environ.get("ARK_DEVECO_SDK_NATIVE") or os.path.join(
    os.environ.get("ARK_DEVECO_STUDIO") or "E:/Program Files/DevEco Studio",
    "sdk", "default", "openharmony", "native")

# ⛔ 这里【故意不给默认值】：原先写死的是一棵带用户名的 Arc 检出，而那条正是
#    RELEASE-MAINTENANCE.md 点名「值得中性化」的形态。没有它就没有 .java 可读，
#    所以缺了就直接说清楚，而不是去猜一个路径。
ARC = os.environ.get("ARK_ARC_SRC")
if not ARC:
    raise SystemExit("!! 需要 ARK_ARC_SRC 指向 Arc 检出（含 arc-core/src 的那棵树）")
OUT = os.path.join(_BUILD, "jni")
OFFICIAL = os.path.join(_TMPROOT, "arcjni", "official.so")
NM = os.path.join(_SDK, "llvm", "bin", "llvm-nm.exe")

SOURCES = [
    (os.path.join(ARC, "arc", "audio", "Soloud.java"), "soloud_jni.cpp"),
    (os.path.join(ARC, "arc", "util", "Buffers.java"), "buffers_jni.cpp"),
    (os.path.join(ARC, "arc", "util", "NativeUtils.java"), "nativeutils_jni.cpp"),
    (os.path.join(ARC, "arc", "graphics", "Pixmap.java"), "pixmap_jni.cpp"),
]


def official_syms():
    out = subprocess.run([NM, "--dynamic", "--defined-only", OFFICIAL],
                         capture_output=True, text=True).stdout
    return sorted(set(re.findall(r"Java_\w+", out)))


def main():
    os.makedirs(OUT, exist_ok=True)

    ours = []
    print("为 4 个文件生成 JNI 绑定：")
    for src, outname in SOURCES:
        if not os.path.isfile(src):
            raise SystemExit("找不到 %s" % src)
        ours += gen_jni.generate(src, os.path.join(OUT, outname))
    ours = sorted(set(ours))

    off = official_syms()

    print()
    print("=" * 66)
    print("【全量】Java_ 符号比对")
    print("=" * 66)
    print("  官方 %d 个   我们 %d 个" % (len(off), len(ours)))

    missing = [s for s in off if s not in ours]
    extra = [s for s in ours if s not in off]

    if missing:
        print()
        print("  ❌ 我们会缺这 %d 个符号（设备上会 UnsatisfiedLinkError）：" % len(missing))
        for s in missing:
            print("     - %s" % s)
    else:
        print("  ✅ 官方的 %d 个符号，我们【一个不缺】" % len(off))

    if extra:
        print()
        print("  ⚠️ 我们多出 %d 个（官方没有）：" % len(extra))
        for s in extra:
            print("     + %s" % s)

    # 分类计数，确认没有任何一个类是"零覆盖"
    print()
    print("  按类分组：")
    groups = {}
    for s in off:
        parts = s.split("_")
        key = "_".join(parts[:4]) if len(parts) >= 5 else s
        groups.setdefault(key, [0, 0])
        groups[key][0] += 1
        if s in ours:
            groups[key][1] += 1
    for k in sorted(groups):
        tot, have = groups[k]
        print("     %-34s %2d/%2d %s" % (k, have, tot, "✅" if have == tot else "❌"))

    ok = not missing
    print()
    print("  结论：%s" % ("✅ 通过 —— 符号集与官方完全对齐" if ok else "❌ 不通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
