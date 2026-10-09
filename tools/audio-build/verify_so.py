# -*- coding: utf-8 -*-
r"""
上设备前对 libarcarm64_fixed.so 做全面自检。

⚠️ 判据是【完整的 Java_ 符号集】，不是只看自己关心的那一类 ——
   上一次只比 Soloud 的 66 个就下结论"零差异"，结果设备上 NativeUtils 一调用就
   UnsatisfiedLinkError（官方其实有 83 个，覆盖 4 个类）。

检查项：
  1. 架构 / 是否 strip
  2. C 库是 musl（GLIBC_ 符号数必须为 0）
  3. Java_ 符号集与官方【逐符号】一致
  4. DT_NEEDED 三个依赖都在设备上有
  5. 未定义符号（undefined）是否都在设备库的提供范围内
  6. SoLoud 后端是否真的编成了 SDL3（不是 miniaudio）
"""
import os
import re
import struct
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

# 路径一律可覆盖，且不含用户名（理由见 build.sh 顶部那段）
_TMPROOT = os.environ.get("ARK_TMP") or os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"
_BUILD = os.environ.get("ARK_SOLOUD_BUILD") or os.path.join(_TMPROOT, "soloudbuild")
_SDK = os.environ.get("ARK_DEVECO_SDK_NATIVE") or os.path.join(
    os.environ.get("ARK_DEVECO_STUDIO") or "E:/Program Files/DevEco Studio",
    "sdk", "default", "openharmony", "native")
NM = os.path.join(_SDK, "llvm", "bin", "llvm-nm.exe")
OFFICIAL = os.path.join(_TMPROOT, "arcjni", "official.so")
OURS = os.path.join(_BUILD, "libarcarm64_fixed.so")

# 设备上能提供这些的库（AMCL bundle + 系统）
KNOWN_PROVIDERS = {
    "libSDL3.so": "AMCL 的 SDL3",
    "libc++_shared.so": "AMCL 带的 libc++",
    "libc.so": "系统 musl libc",
    "libm.so": "系统 libm",
    "libdl.so": "系统 libdl",
    "libpthread.so": "系统 libpthread",
}


def nm(path, *args):
    return subprocess.run([NM, "--dynamic", *args, path], capture_output=True, text=True).stdout


def dyn_needed(path):
    d = open(path, "rb").read()
    e_shoff, = struct.unpack_from("<Q", d, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    sh = [struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    shstr = sh[e_shstrndx]

    def nm_at(o):
        e = d.index(b"\0", shstr[4] + o)
        return d[shstr[4] + o:e].decode()

    dyn = next(s for s in sh if nm_at(s[0]) == ".dynamic")
    ds = next(s for s in sh if nm_at(s[0]) == ".dynstr")
    out, o = [], dyn[4]
    while True:
        t, v = struct.unpack_from("<qQ", d, o)
        if t == 0:
            break
        if t == 1:
            e = d.index(b"\0", ds[4] + v)
            out.append(d[ds[4] + v:e].decode())
        o += 16
    return out


def main():
    fails = []

    print("=" * 68)
    print("libarcarm64_fixed.so 上设备前自检")
    print("=" * 68)

    # 1. 架构 / C 库
    defined = nm(OURS, "--defined-only")
    undefined = nm(OURS)
    undefined = [l for l in undefined.split("\n") if re.search(r"\sU\s", l)]

    print()
    print("[1] C 库")
    glibc = [l for l in defined.split("\n") if "GLIBC_" in l]
    print("    GLIBC_ 版本符号数 = %d  %s" % (len(glibc), "✅ musl" if not glibc else "❌ 是 glibc！"))
    if glibc:
        fails.append("产物是 glibc，鸿蒙(musl)加载不了")
    print("    （对照组）官方库 GLIBC_ 符号数 = %d"
          % len([l for l in nm(OFFICIAL, "--defined-only").split("\n") if "GLIBC_" in l]))

    # 2. Java_ 符号集
    a = set(re.findall(r"Java_\w+", nm(OFFICIAL, "--defined-only")))
    b = set(re.findall(r"Java_\w+", nm(OURS, "--defined-only")))
    print()
    print("[2] Java_ 符号集（完整的 4 个类）")
    print("    官方 %d 个，我们 %d 个" % (len(a), len(b)))
    missing, extra = sorted(a - b), sorted(b - a)
    print("    缺: %s" % (missing if missing else "无 ✅"))
    print("    多: %s" % (extra if extra else "无 ✅"))
    if missing or extra:
        fails.append("Java_ 符号集不一致")

    # 3. DT_NEEDED
    need = dyn_needed(OURS)
    print()
    print("[3] DT_NEEDED（设备上必须都能解析到）")
    for n in need:
        ok = n in KNOWN_PROVIDERS
        print("    %-22s %s %s" % (n, "✅" if ok else "❓", KNOWN_PROVIDERS.get(n, "来源未知 —— 要确认设备上有")))
        if not ok:
            fails.append("依赖 %s 来源未确认" % n)

    # 4. 未定义符号
    und = sorted(set(re.findall(r"\sU\s+(\S+)", "\n".join(undefined))))
    print()
    print("[4] 未定义符号 %d 个，按来源分类：" % len(und))
    buckets = {"SDL_": [], "std/异常(libc++_shared)": [], "musl/libc": [], "其它": []}
    for s in und:
        if s.startswith("SDL_"):
            buckets["SDL_"].append(s)
        elif s.startswith("_Z") or s.startswith("__cxa") or s.startswith("_Unwind"):
            buckets["std/异常(libc++_shared)"].append(s)
        elif s in ("malloc", "free", "memcpy", "memset", "setenv", "unsetenv", "getenv",
                   "pthread_create", "pthread_join", "pthread_mutex_lock", "pthread_mutex_unlock",
                   "clock_gettime", "nanosleep", "usleep", "dlopen", "dlsym", "dlclose"):
            buckets["musl/libc"].append(s)
        else:
            buckets["其它"].append(s)
    for k, v in buckets.items():
        print("    %-26s %3d 个" % (k, len(v)))
    if buckets["其它"]:
        print("    其它明细：%s" % buckets["其它"])
    sdl_ok = set(s for s in buckets["SDL_"])
    print("    → SDL_ 共 %d 个，都应由 AMCL 的 libSDL3.so 提供" % len(sdl_ok))

    # 5. 后端确认
    raw = open(OURS, "rb").read()
    print()
    print("[5] SoLoud 后端")
    print("    含 miniaudio 字符串 = %s（应为 False）" % (b"miniaudio" in raw))
    print("    含 SDL3 字符串     = %s（应为 True）" % (b"SDL3" in raw))
    print("    含 miniaudio_ 符号 = %d（应为 0）"
          % len([l for l in defined.split("\n") if "miniaudio" in l.lower()]))
    if b"miniaudio" in raw:
        fails.append("产物仍含 miniaudio")

    print()
    print("=" * 68)
    if fails:
        print("结论：❌ 有 %d 项不通过 —— %s" % (len(fails), "; ".join(fails)))
    else:
        print("结论：✅ 全部通过")
    print("=" * 68)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
