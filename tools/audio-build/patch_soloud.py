# -*- coding: utf-8 -*-
r"""
给 SoLoud 源码加上 WITH_SDL3 后端（四处改动）。

SoLoud 的后端是编译期选定的（`Soloud::init()` 里一堆 `#if defined(WITH_XXX)` 分支）。
我们需要的 SDL3 后端它没有 —— 而目标平台（OpenHarmony）只提供 SDL3 的音频驱动（OHAudio），
ALSA / PulseAudio / miniaudio 一概没有，所以现成的后端一个都用不了。

用法: python patch_soloud.py <soloud源码根目录>
可重复执行（幂等）。
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

# (相对路径, 原文本, 新文本, 说明)
EDITS = [
    # 1) 枚举加 SDL3 —— 放在 NULLDRIVER 之后，这样 AUTO..NULLDRIVER 的数值都不变
    ("include/soloud.h",
     """        NULLDRIVER,
        BACKEND_MAX,""",
     """        NULLDRIVER,
        SDL3,
        BACKEND_MAX,""",
     "soloud.h: BACKENDS 枚举加 SDL3"),

    # 2) 后端 init 函数声明
    ("include/soloud_internal.h",
     """// SDL1 "non-dynamic" back-end initialization call
result sdl1static_init(""",
     """// SDL3 back-end initialization call
result sdl3_init(SoLoud::Soloud *aSoloud, unsigned int aFlags = Soloud::CLIP_ROUNDOFF, unsigned int aSamplerate = 44100, unsigned int aBuffer = 2048, unsigned int aChannels = 2);

// SDL1 "non-dynamic" back-end initialization call
result sdl1static_init(""",
     "soloud_internal.h: 声明 sdl3_init"),

    # 3) "没有启用任何后端" 的 #error 检查里放行 WITH_SDL3
    ("src/core/soloud.cpp",
     """    !defined(WITH_JACK) && !defined(WITH_NOSOUND) && !defined(WITH_MINIAUDIO)""",
     """    !defined(WITH_JACK) && !defined(WITH_NOSOUND) && !defined(WITH_MINIAUDIO) && \\
    !defined(WITH_SDL3)""",
     "soloud.cpp: #error 检查放行 WITH_SDL3"),

    # 4) init() 里加 SDL3 分支
    ("src/core/soloud.cpp",
     """#if defined(WITH_SDL1)
    if(!inited &&
        (aBackend == Soloud::SDL1 ||
            aBackend == Soloud::AUTO)){""",
     """#if defined(WITH_SDL3)
    if(!inited &&
        (aBackend == Soloud::SDL3 ||
            aBackend == Soloud::AUTO)){
        if(aBufferSize == Soloud::AUTO)
            buffersize = 2048;

        int ret = sdl3_init(this, aFlags, samplerate, buffersize, aChannels);
        if(ret == 0){
            inited = 1;
            mBackendID = Soloud::SDL3;
        }

        if(ret != 0 && aBackend != Soloud::AUTO)
            return ret;
    }
#endif

#if defined(WITH_SDL1)
    if(!inited &&
        (aBackend == Soloud::SDL1 ||
            aBackend == Soloud::AUTO)){""",
     "soloud.cpp: init() 加 SDL3 分支"),
]


def main():
    if len(sys.argv) < 2:
        raise SystemExit("用法: python patch_soloud.py <soloud源码根目录>")
    root = sys.argv[1]

    ok = 0
    already = 0
    missing = []

    for rel, old, new, desc in EDITS:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            missing.append("%s (文件不存在)" % rel)
            continue
        src = io.open(path, encoding="utf-8", errors="replace").read()

        marker = new.split("\n")[0].strip()
        if old not in src:
            # 已经打过补丁？（用新文本里的特征串判断）
            if "WITH_SDL3" in src and any(k in src for k in ("sdl3_init", "SDL3,")):
                print("  跳过（已打过）: %s" % desc)
                already += 1
                continue
            missing.append("%s : 找不到待替换文本" % rel)
            continue

        io.open(path, "w", encoding="utf-8", newline="").write(src.replace(old, new, 1))
        print("  OK  %s" % desc)
        ok += 1

    print()
    print("应用 %d 处，跳过 %d 处" % (ok, already))
    if missing:
        print("!! 有问题：")
        for m in missing:
            print("   " + m)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
