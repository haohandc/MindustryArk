# -*- coding: utf-8 -*-
r"""
把 libarcarm64_fixed.so 的【全部未定义符号】逐个拿去「设备上会有的库」里找，
找出真正解析不到的 —— 那才是 dlopen 会失败的点。

设备上可用的库 = OHOS sysroot 里的系统库（musl libc / libc++_shared / libm ...）
              + AMCL 提供的 libSDL3.so
              + 我们自编的 libSDL3.so（同源，符号一致）

这不是"猜"，是把每个未定义符号真的在库里查一遍（llvm-nm 读 .dynsym）。
"""
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

# 路径一律可用 ARK_* 覆盖，且不含用户名 —— 仓库的「无绝对路径」发布检查会数带盘符的行，
# 带【用户名】的那种是它唯一点名值得中性化的形态。理由与 tools/audio-build/build.sh 顶部那段相同。
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
REF = os.path.join(os.path.dirname(REPO), "MindustryArkDocs")
TMPROOT = os.environ.get("ARK_TMP") or os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"
BUILD = os.environ.get("ARK_SOLOUD_BUILD") or os.path.join(TMPROOT, "soloudbuild")
SDK = os.environ.get("ARK_DEVECO_SDK_NATIVE") or os.path.join(
    os.environ.get("ARK_DEVECO_STUDIO") or "E:/Program Files/DevEco Studio",
    "sdk", "default", "openharmony", "native")
NM = os.path.join(SDK, "llvm", "bin", "llvm-nm.exe")
SYSROOT_LIB = os.path.join(SDK, "sysroot", "usr", "lib", "aarch64-linux-ohos")
OURS = os.path.join(BUILD, "libarcarm64_fixed.so")
OUR_SDL3 = os.path.join(REF, "sdl3-ohos", "libSDL3.so")
# AMCL bundle 里实际存在的那一份（= 设备上运行时真正加载的）
# 已实测：与 OHOS NDK 的 libc++_shared.so 大小/导出符号【完全一致】
AMCL_LIBS = os.path.join(REF, "amcl_probe", "libs", "arm64-v8a")


def base(sym):
    """去掉 ELF 版本后缀：`SDL_Init@@SDL3_0.0.0` / `SDL_Init@SDL3_0.0.0` -> `SDL_Init`"""
    return sym.split("@", 1)[0]


def undefs(path):
    o = subprocess.run([NM, "--dynamic", path], capture_output=True, text=True).stdout
    return set(base(s) for s in re.findall(r"\sU\s+(\S+)", o))


def defined(path):
    o = subprocess.run([NM, "--dynamic", "--defined-only", path], capture_output=True, text=True).stdout
    return set(base(l.split()[-1]) for l in o.split("\n") if l.strip() and " U " not in l)


def main():
    want = undefs(OURS)
    print("我们的未定义符号 = %d 个" % len(want))

    # 收集候选提供者
    providers = {}
    if os.path.isdir(SYSROOT_LIB):
        for f in sorted(os.listdir(SYSROOT_LIB)):
            if f.endswith(".so"):
                p = os.path.join(SYSROOT_LIB, f)
                try:
                    providers["sysroot/" + f] = defined(p)
                except Exception:
                    pass
    if os.path.isfile(OUR_SDL3):
        providers["sdl3-ohos/libSDL3.so"] = defined(OUR_SDL3)
    # AMCL bundle：设备上真正加载的那一份（libSDL3.so / libc++_shared.so 都在这里）
    if os.path.isdir(AMCL_LIBS):
        for f in ("libc++_shared.so", "libSDL3.so"):
            p = os.path.join(AMCL_LIBS, f)
            if os.path.isfile(p):
                providers["amcl-bundle/" + f] = defined(p)

    print("候选提供者 %d 个：%s" % (len(providers), ", ".join(sorted(providers))))
    print()

    resolved = {}
    for name, have in providers.items():
        for s in want:
            if s in have and s not in resolved:
                resolved[s] = name

    missing = sorted(want - set(resolved))
    print("=" * 68)
    print("解析结果")
    print("=" * 68)
    print("  能解析 %d / %d" % (len(resolved), len(want)))
    print()
    print("  按提供者统计：")
    by = {}
    for s, p in resolved.items():
        by.setdefault(p, []).append(s)
    for p in sorted(by, key=lambda k: -len(by[k])):
        print("    %-44s %3d 个" % (p, len(by[p])))
    print()
    if missing:
        print("  ❌ 解析不到的 %d 个（dlopen 会失败）：" % len(missing))
        for s in missing:
            print("     - %s" % s)
    else:
        print("  ✅ 全部未定义符号都能在设备上的库里找到")
    print("=" * 68)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
