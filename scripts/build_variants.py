# -*- coding: utf-8 -*-
r"""
从一个【已打好 Arc 补丁】的基础 jar 派生所有原生库变体。

⭐ 存在的理由（2026-09-18 踩坑）：
   流水线本来是
       patch_mindustry.py  ->  mindustry-1.0.jar        （换 Arc 类，原生库还是官方的）
       repack.py           ->  mindustry-1.0-audio.jar  （在【上一步的产物】上换 .so）
   —— 顺序不能颠倒。我后来重跑了 patch_mindustry.py 来加 providerall，
   于是 mindustry-1.0.jar 被刷新，而 mindustry-1.0-audio.jar 还停在旧基础上。
   更糟的是我把 providerall 的 stage JSON 直接指向了 mindustry-1.0.jar，
   结果设备上音频退化回"没有可用后端"：
       [E] Failed to initialize audio, disabling sound: ArcRuntimeException: Other error

   所以：**凡是换原生库，一律走本脚本，永远不要在别处手工 repack。**

   基础 jar 的 .so = 官方版（miniaudio，鸿蒙上无可用音频后端）
   派生 jar 的 .so = 我们自编版（SDL3 后端）

用法：
    python build_variants.py
环境变量可覆盖（见 config.py）：
    ARK_PATCHED_JAR（基础 jar）/ ARK_GAME_JAR（决定输出目录）/ ARK_TMP
    仍可用 AUDIO_SO / AUDIODBG_SO / OFFICIAL_SO 覆盖这三个中间产物
"""
import hashlib
import os
import re
import subprocess
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

TMP = config.TMP
# The variants land next to the pinned one they are compared against, which is
# what prep_game.py ships (ARK_GAME_JAR).
OUT_DIR = os.path.dirname(config.GAME_JAR)

BASE_JAR = config.PATCHED_JAR
OFFICIAL_SO = os.environ.get("OFFICIAL_SO", os.path.join(TMP, "arcjni", "official.so"))
TARGET = "libarcarm64.so"

# 变体：输出文件名 -> 用哪个 .so
VARIANTS = [
    ("mindustry-1.0-audio.jar",
     os.environ.get("AUDIO_SO", os.path.join(TMP, "soloudbuild", "libarcarm64_fixed.so")),
     False),
    ("mindustry-1.0-audio-debug.jar",
     os.environ.get("AUDIODBG_SO", os.path.join(TMP, "soloudbuild", "libarcarm64_dbg_fixed.so")),
     True),
]

# 音频变体的 .so 必须真的带 SDL3 后端、且不带 miniaudio
def java_syms(blob):
    """取 Java_ 符号名（.dynsym 的字符串就在文件里，直接扫足够可靠）"""
    return set(re.findall(rb"Java_[A-Za-z0-9_]+", blob))


# ⭐⭐ 决定性闸门：必须在**链接后的二进制**里确认这些函数被真的调用了。
# 2026-09-19 踩坑：libarcarm64_fixed.so 是 18:12 链接的，而 SDL_SetMainReady 的修复
# 是 21:10 才进源码的 —— 源码改了、目标文件重编了，但**那个输出文件从没重新链接过**。
# 于是"我们的音频版 .so"其实是个修复前的旧构建，设备上就是没声音。
# ⚠️ 不能用 `b"SDL_SetMainReady" in blob` 判断：日志文案「已调用 SDL_SetMainReady()」
#    本身就含这个子串，会假阳性。必须读**动态符号表**看它是不是 UND。
READELF = config.READELF

# 这些必须是 UND（未定义 = 由设备上的 libSDL3.so 提供 = 我们确实调用了）
REQUIRED_UND = [
    "SDL_SetMainReady",              # ⭐ 音频能不能初始化取决于它
    "SDL_InitSubSystem",
    "SDL_OpenAudioDeviceStream",
    "SDL_ResumeAudioStreamDevice",
]


def check_so_calls(so_path):
    """返回 (通过的列表, 失败原因列表)。用 readelf 读动态符号表。"""
    if not os.path.isfile(READELF):
        return [], ["找不到 llvm-readelf: %s（无法校验 .so 的调用集）" % READELF]
    r = subprocess.run([READELF, "--dyn-syms", "-W", so_path],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return [], ["readelf 失败: %s" % (r.stderr or "").strip()[:200]]

    und = set()
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 8 and parts[0].rstrip(":").isdigit() and "UND" in parts:
            und.add(parts[-1].split("@")[0])

    ok, bad = [], []
    for name in REQUIRED_UND:
        if name in und:
            ok.append(name)
        else:
            bad.append(name)
    return ok, bad


def sha1_of(data):
    return hashlib.sha1(data).hexdigest()


def check_base(base_bytes):
    """基础 jar 必须已经换过 Arc 类 —— 否则派生出来的变体缺 GL 修复，白跑一次设备。"""
    fails = []
    with zipfile.ZipFile(BASE_JAR) as z:
        names = set(z.namelist())
        for must in ("arc/backend/sdl/GLDispatchFix.class",
                     "arc/backend/sdl/GLBootstrap.class",
                     "mindustry/desktop/DesktopLauncher.class"):
            if must not in names:
                fails.append("基础 jar 缺 %s" % must)
        jni = [n for n in names if n.startswith("arc/backend/sdl/jni/")]
        if not jni:
            fails.append("基础 jar 缺 arc/backend/sdl/jni/**")
        so = z.read(TARGET)
        if b"miniaudio" not in so:
            fails.append("基础 jar 的 .so 里居然没有 miniaudio —— 是不是已经换过了？（基础 jar 应当是【官方 .so】）")
        # 再确认一遍 Arc 修复真的在（类字节里搜得到日志前缀）
        try:
            gdf = z.read("arc/backend/sdl/GLDispatchFix.class")
            if b"providerall" not in gdf and b"GLDispatchFix" not in gdf:
                fails.append("GLDispatchFix.class 看着不像我们的版本")
        except KeyError:
            pass
    return fails


def build(out_name, so_path, official_syms):
    out_jar = os.path.join(OUT_DIR, out_name)
    if not os.path.isfile(so_path):
        print("!! 跳过 %s：找不到 %s" % (out_name, so_path))
        return None

    # ⭐ 第一步就查：这个 .so 真的是"修好的那个"吗？（2026-09-19 就是这里出的问题）
    calls_ok, calls_bad = check_so_calls(so_path)
    print()
    print("=" * 70)
    print("%s —— .so 调用集闸门" % out_name)
    print("=" * 70)
    print("  .so = %s" % so_path)
    if calls_bad:
        print("  [X] 以下函数【没有】被调用（说明这个 .so 是修复前的旧构建）：")
        for n in calls_bad:
            print("        %s" % n)
        print()
        print("  中止：拒绝用它派生 jar（否则设备上会没声音，而且看不出原因）")
        print("  修法：进 soloudbuild/ 清掉 obj/ 重跑 build.sh -> llvm-strip -> fix_needed.py")
        return {"name": out_name, "sha1": "-", "size": 0,
                "fails": ["%s 未被调用: %s" % (out_name, calls_bad)]}
    for n in calls_ok:
        print("  [OK] %s = UND（我们确实调用了）" % n)

    new_so = open(so_path, "rb").read()
    src = zipfile.ZipFile(BASE_JAR, "r")
    old_len = len(src.read(TARGET))

    replaced = 0
    with zipfile.ZipFile(out_jar, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            if item.filename == TARGET:
                dst.writestr(item, new_so)
                replaced += 1
            else:
                dst.writestr(item, src.read(item.filename))
    src.close()
    if replaced != 1:
        raise SystemExit("!! %s: 替换次数 = %d，期望 1" % (out_name, replaced))

    data = open(out_jar, "rb").read()
    print()
    print("=" * 70)
    print("%s" % out_name)
    print("=" * 70)
    print("  .so      = %s" % so_path)
    print("  .so 大小 = %d  (基础 jar 里是 %d)" % (len(new_so), old_len))
    print("  jar 大小 = %d" % len(data))
    print("  jar sha1 = %s" % sha1_of(data))

    # ---------------- 自检 ----------------
    fails = []
    with zipfile.ZipFile(out_jar) as z:
        got = z.read(TARGET)
        names = z.namelist()

        if len(got) != len(new_so):
            fails.append("jar 里的 .so 长度不对")
        if b"SDL3" not in got:
            fails.append("新 .so 里没有 SDL3 后端字符串（会是没声音的原因）")
        if b"miniaudio" in got:
            fails.append("新 .so 里仍含 miniaudio（用错后端会没声音）")

        # ⭐ 全量 Java_ 符号核对
        have = java_syms(got)
        miss = sorted(s.decode() for s in official_syms - have)
        extra = sorted(s.decode() for s in have - official_syms)
        print("  [1] .so 字节数一致        = %s" % (len(got) == len(new_so)))
        print("  [2] 含 SDL3 后端          = %s" % (b"SDL3" in got))
        print("  [3] 不含 miniaudio        = %s" % (b"miniaudio" not in got))
        print("  [4] Java_ 符号：官方 %d / 本库 %d，缺 %d 多 %d"
              % (len(official_syms), len(have), len(miss), len(extra)))
        if miss:
            print("        缺 = %s" % miss[:8])
            fails.append("缺 %d 个 Java_ 符号" % len(miss))
        for cls in (b"Java_arc_audio_Soloud", b"Java_arc_util_Buffers",
                    b"Java_arc_util_NativeUtils", b"Java_arc_graphics_Pixmap"):
            n = len([s for s in have if s.startswith(cls)])
            print("        %-32s %2d 个  %s" % (cls.decode(), n, "OK" if n else "!!"))
            if not n:
                fails.append("类 %s 一个符号都没有" % cls.decode())

        # Arc 修复必须还在（这是本次踩坑的核心检查项）
        need = ["arc/backend/sdl/GLDispatchFix.class",
                "arc/backend/sdl/GLBootstrap.class",
                "arc/backend/sdl/SdlGraphics.class",
                "arc/graphics/gl/GLVersion$GlType.class",
                "mindustry/desktop/DesktopLauncher.class"]
        print("  [5] Arc 修复类 & 主类     = %s" % all(n in names for n in need))
        if not all(n in names for n in need):
            fails.append("缺 Arc 修复类或主类: %s" % [n for n in need if n not in names])
        print("  [6] 原生库条目数          = %d" % len([n for n in names if n.endswith((".so", ".dll", ".dylib"))]))

    print()
    print("  结论：%s" % ("✅ 通过" if not fails else "❌ " + "; ".join(fails)))
    return {"name": out_name, "sha1": sha1_of(data), "size": len(data), "fails": fails}


def main():
    print("基础 jar = %s" % BASE_JAR)
    base_bytes = open(BASE_JAR, "rb").read()
    print("基础 sha1 = %s  (%d 字节)" % (sha1_of(base_bytes), len(base_bytes)))
    print()

    checks = check_base(base_bytes)
    if checks:
        print("!! 基础 jar 自检失败：")
        for c in checks:
            print("   - " + c)
        return 1
    print("基础 jar 自检 OK（已换 Arc 类 + 仍是官方 .so）")

    official_syms = java_syms(open(OFFICIAL_SO, "rb").read())
    print("官方 .so 的 Java_ 符号 = %d 个" % len(official_syms))

    results = [build(n, p, official_syms) for n, p, _ in VARIANTS]

    print()
    print("=" * 70)
    print("汇总")
    print("=" * 70)
    for r in results:
        if r is None:
            print("  (跳过)")
        else:
            print("  %-32s %s  %d 字节  %s"
                  % (r["name"], r["sha1"], r["size"], "OK" if not r["fails"] else "FAIL"))
    bad = [r for r in results if r is not None and r["fails"]]
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
