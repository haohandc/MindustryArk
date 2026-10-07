# -*- coding: utf-8 -*-
r"""
【独立交叉验证】直接从 jar 里的 .class 反推出应该有哪些 JNI 符号，再和我们的 .so 比对。

为什么这道检查值得单独做：
  前面的比对都是拿「官方 .so」当基准。万一 jar 里的 class 和官方 .so 版本不一致，
  或者我自己生成时漏了类，跟官方比是发现不了的。
  这里换一个【完全不同的一手来源】—— 我们要实际分发的那个 jar 的字节码本身 ——
  看它声明了哪些 native 方法，据此算出 JNI 符号名，再问"我们的 .so 提供了吗"。

符号名规则（JNI 规范）：
  Java_<类名，点换成 _>_<方法名>
  重载时追加 __<参数描述符，按 _1 _ _2 _3 转义>
  `_`->`_1`  `/`->`_`  `;`->`_2`  `[`->`_3`
"""
import os
import re
import subprocess
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

# 路径一律可覆盖，且不含用户名（理由见 build.sh 顶部那段）
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
REF = os.path.join(os.path.dirname(REPO), "MindustryArkDocs")
TMPROOT = os.environ.get("ARK_TMP") or os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"
BUILD = os.environ.get("ARK_SOLOUD_BUILD") or os.path.join(TMPROOT, "soloudbuild")
JDK = os.environ.get("ARK_JAVA_HOME") or "C:/Program Files/Java/jdk-17"
JAR = os.environ.get("ARK_TEST_JAR") or os.path.join(REF, "mindustry-ohos", "mindustry-1.0-audio.jar")
OURS = os.path.join(BUILD, "libarcarm64_fixed.so")
JAVAP = os.path.join(JDK, "bin", "javap.exe")

CLASSES = ["arc.audio.Soloud", "arc.util.Buffers", "arc.util.NativeUtils", "arc.graphics.Pixmap"]


def mangle(s):
    return s.replace("_", "_1").replace("/", "_").replace(";", "_2").replace("[", "_3")


def native_methods(cls):
    """用 javap 读出类里所有 native 方法的 (名字, 描述符)"""
    out = subprocess.run([JAVAP, "-p", "-s", "-cp", JAR, cls],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    methods = []
    lines = out.split("\n")
    for i, ln in enumerate(lines):
        if "native" not in ln:
            continue
        m = re.search(r"([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*;", ln)
        if not m or i + 1 >= len(lines):
            continue
        d = re.search(r"descriptor:\s*(\S+)", lines[i + 1])
        if not d:
            continue
        methods.append((m.group(1), d.group(1)))
    return methods


def main():
    if not os.path.isfile(JAR):
        raise SystemExit("找不到 %s" % JAR)

    # 注意 decode：regex 跑在 bytes 上得到的是 bytes，跟下面 str 的 expected 比会全不相等
    have = set(s.decode() for s in re.findall(rb"Java_[A-Za-z0-9_]+", open(OURS, "rb").read()))

    expected = {}
    per_class = {}
    for cls in CLASSES:
        ms = native_methods(cls)
        per_class[cls] = len(ms)
        prefix = "Java_" + mangle(cls.replace(".", "/")) + "_"
        counts = {}
        for name, _ in ms:
            counts[name] = counts.get(name, 0) + 1
        for name, desc in ms:
            sym = prefix + mangle(name)
            if counts[name] > 1:
                # 描述符去掉返回类型，只留参数部分
                params = desc[1:desc.index(")")]
                sym += "__" + mangle(params)
            expected[sym] = cls

    print("从 jar 的 .class 反推出的 native 方法数：")
    for cls in CLASSES:
        print("  %-26s %2d 个" % (cls, per_class[cls]))
    print("  合计 %d 个 native 方法 -> %d 个 JNI 符号（含重载）" % (sum(per_class.values()), len(expected)))

    exp = set(expected)
    miss = sorted(exp - have)
    extra = sorted(have - exp)

    print()
    print("=" * 66)
    print("比对：jar 里声明的 native 方法  vs  我们 .so 里实际导出的 JNI 符号")
    print("=" * 66)
    print("  应提供 %d 个，实际提供 %d 个" % (len(exp), len(have)))
    print()
    if miss:
        print("  ❌ jar 需要、但我们的 .so 没导出的 %d 个（设备上会 UnsatisfiedLinkError）：" % len(miss))
        for s in miss:
            print("     - %s   （来自 %s）" % (s, expected[s]))
    else:
        print("  ✅ jar 声明的每一个 native 方法，我们的 .so 都导出了对应符号")
    if extra:
        print()
        print("  ⚠️ 我们多导出的 %d 个（无害）：" % len(extra))
        for s in extra:
            print("     + %s" % s)
    print("=" * 66)
    return 1 if miss else 0


if __name__ == "__main__":
    sys.exit(main())
