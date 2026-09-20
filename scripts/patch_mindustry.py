# -*- coding: utf-8 -*-
r"""
给 Mindustry.jar 打补丁：把它内置的 Arc 类换成我们改过的版本。

最小替换集（其余 846-25 个 arc 类保持原样，避免牵连）：
  · arc/graphics/gl/GLVersion*.class   —— GLES 从版本串自动识别
  · arc/graphics/gl/Shader*.class      —— GLSL 版本按 GL 类型选（不是按应用类型）
  · arc/backend/sdl/**                 —— SDL2 后端整体换成 SDL3 后端（同包同名，drop-in）
  · arc/backend/sdl/GLBootstrap*.class —— 新增：重建 GL 分发表

保留 arc/backend/sdl/jni/**（Mindustry 的 DesktopLauncher / ErrorDialog 常量池仍引用它们）

就地打补丁而不是"额外挂一个补丁 jar"的原因：classpath 顺序不可控，
Mindustry.jar 里旧的 SDL2 类会先命中。
"""
import hashlib
import io
import os
import shutil
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

TB = os.path.join(config.TMP, "arcbuild")
# The upstream release jar in, the patched jar out. Both sit in payload-src/
# (config.py), so the three-stage chain -- patch, repack, variant -- can be
# re-run in place without moving anything by hand.
SRC_JAR = config.UPSTREAM_JAR
OUT_DIR = os.path.dirname(config.PATCHED_JAR)
OUT_JAR = config.PATCHED_JAR

# 单文件替换（arc-core 改动）
SINGLE = [
    (os.path.join(TB, "core"), "arc/graphics/gl/GLVersion.class"),
    (os.path.join(TB, "core"), "arc/graphics/gl/GLVersion$GlType.class"),
    (os.path.join(TB, "core"), "arc/graphics/gl/Shader.class"),
]

# 目录替换（backend-sdl3 整体覆盖 backend-sdl）
DIRS = [
    (os.path.join(TB, "sdl3", "arc", "backend", "sdl"), "arc/backend/sdl/"),
]


def collect_replacements():
    out = {}
    for root, rel in SINGLE:
        p = os.path.join(root, rel.replace("/", os.sep))
        if not os.path.isfile(p):
            raise SystemExit("缺少文件: %s" % p)
        out[rel] = p
    for root, prefix in DIRS:
        if not os.path.isdir(root):
            raise SystemExit("缺少目录: %s" % root)
        for fn in sorted(os.listdir(root)):
            if fn.endswith(".class"):
                out[prefix + fn] = os.path.join(root, fn)
    return out


def main():
    repl = collect_replacements()
    print("要替换/新增的类 = %d 个" % len(repl))
    for k in sorted(repl):
        print("   " + k)
    print()

    if not os.path.isfile(SRC_JAR):
        raise SystemExit("找不到源 jar: %s" % SRC_JAR)

    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.exists(OUT_JAR):
        os.remove(OUT_JAR)

    src = zipfile.ZipFile(SRC_JAR, "r")
    done = set()
    entries = 0
    replaced = 0
    added = 0

    with zipfile.ZipFile(OUT_JAR, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            name = item.filename
            entries += 1
            if name in repl:
                data = open(repl[name], "rb").read()
                dst.writestr(item, data)          # 保留原 entry 元数据（时间戳/属性）
                done.add(name)
                replaced += 1
            else:
                # 原样搬运，避免解压再压缩造成的任何差异
                dst.writestr(item, src.read(name))
        # 新增的类（必须用完整路径，否则会落到 jar 根目录）
        for name in sorted(repl):
            if name not in done:
                dst.writestr(zipfile.ZipInfo(name, date_time=(2026, 9, 18, 0, 0, 0)), open(repl[name], "rb").read())
                done.add(name)
                added += 1
    src.close()

    size = os.path.getsize(OUT_JAR)
    with open(OUT_JAR, "rb") as f:
        sha1 = hashlib.sha1(f.read()).hexdigest()

    print("原始条目 = %d" % entries)
    print("替换   = %d" % replaced)
    print("新增   = %d" % added)
    print()
    print("产物 = %s" % OUT_JAR)
    print("size = %d" % size)
    print("sha1 = %s" % sha1)

    # 自检：产物里的这些类是不是我们的版本
    print()
    print("=== 自检：产物内已替换类的字节数 ===")
    with zipfile.ZipFile(OUT_JAR) as z:
        for name in sorted(repl):
            got = len(z.read(name))
            want = len(open(repl[name], "rb").read())
            flag = "OK " if got == want else "!! "
            print("  %s%-42s %d" % (flag, name, got))
        # 确认 jni 还在
        jni = [n for n in z.namelist() if n.startswith("arc/backend/sdl/jni/")]
        print()
        print("  保留的 jni 条目 = %d 个" % len(jni))
        # 确认 Mindustry 主类还在
        for must in ("mindustry/desktop/DesktopLauncher.class", "mindustry/Vars.class"):
            print("  %s%s" % ("OK " if must in z.namelist() else "!! ", must))


if __name__ == "__main__":
    main()
