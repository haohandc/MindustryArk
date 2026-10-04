# -*- coding: utf-8 -*-
r"""AddressSanitizer 开关。

    python scripts/asan.py status
    python scripts/asan.py on
    python scripts/asan.py off

ASan 要设两处，而它们都在**被 git 跟踪**的文件里：

    AppScope/app.json5            "app": { "asanEnabled": true }
    entry/build-profile.json5     externalNativeOptions.arguments 里加
                                  -DOHOS_ENABLE_ASAN=ON

两个都是**手工维护**的文件（带注释），所以这里按文本改、并且**每一处替换都断言命中数**，
不用 json 往返 —— 那会把注释全吃掉。

⛔⛔ **为什么要有这个脚本，而不是手改两下**：
   开是两处编辑，**关也是两处** —— 而「关」正是会被忘掉的那一半，忘了就把
   `asanEnabled: true` 提交进仓库了。所以关键在于它有 `off`，且 `off` 是**逐字还原**。

⛔⛔ **它还会删掉 `entry/.cxx`**。那不是顺手清理：`entry/build-profile.json5` 自己的注释写着
   「entry/.cxx holds one CMake cache per product/buildMode, so **a flag change does not
   reach a cache that already exists**」⇒ 不清缓存的话，**标志会被接受、构建会成功、
   产物却没插桩** —— 正是本项目反复踩的那种「开了等于没开、而且看不出来」。
   代价是下一次 native 全量重编一次（SDL 那 ~490 个文件），可接受。

代价（实测自 SDK，不是文档转述）：
  · **只在 debug 生效** —— DevEco 的校验 schema 对 `asanEnabled` 写的是
    "Release version is not configurable"（`sdk/default/hms/toolchains/configcheck/configSchema_rich.json`）
    ⇒ **上架/商店包不可能带上它**，不必担心商店包变大或变慢。
  · 运行期：工具链会加
    `-fsanitize=address -shared-libasan -fno-omit-frame-pointer **-fsanitize-recover=address**`
    （`sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake:171`）。
    ⭐ **最后那个是「报告后继续跑」** ⇒ 一次运行要**去看日志**，⛔ 不能以「没闪退」判定没问题。
  · **覆盖不到**：`libjvm_real.so`（25 MB 预编译 OpenJDK）、`libarc*.so`（预编译）、
    以及 `game/mindustry.so`（游戏本体）。ASan 只能看见**我们自己编译的**那几个
    —— `main` / `shield` / `jarver` / `savemeta` / `storprobe` 与编进 entry 的 SDL。
    ⚠️ 本项目真正在追的那个崩溃（18 条 faultlog，落在
    `Java_arc_freetype_FreeType_00024Face_loadChar`）**恰好是覆盖不到的那一类**。
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_JSON5 = os.path.join(ROOT, "AppScope", "app.json5")
ENTRY_PROFILE = os.path.join(ROOT, "entry", "build-profile.json5")
CXX_CACHE = os.path.join(ROOT, "entry", ".cxx")
# ⭐ `off` 靠它把两份文件**逐字节**还回去。⚠️ 必须在 .gitignore 里（是临时物料，不是源码）。
BACKUP_DIR = os.path.join(ROOT, ".asan-backup")

# ⭐ 参数名来自 SDK 工具链源码，⛔ 不是从文档抄的：
#    sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake:171
#        if(OHOS_ENABLE_ASAN STREQUAL ON)
ASAN_TOKEN = "-DOHOS_ENABLE_ASAN=ON"
# ⛔ 关的时候必须把它留住 —— 它是**另一个**承重参数（见入口那份 build-profile 的长注释）。
KEEP_TOKEN = "-DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1"

# app.json5 里 app 对象的第一行（用来插一行进去）。
APP_OPEN_RE = re.compile(r'^([ \t]*"app"[ \t]*:[ \t]*\{[ \t]*\r?\n)', re.M)
# ⛔ 整行匹配（含缩进与行尾逗号），这样删的时候不会留下孤零零的逗号。
ASAN_LINE_RE = re.compile(r'^[ \t]*"asanEnabled"[ \t]*:[ \t]*(?:true|false)[ \t]*,?[ \t]*\r?\n',
                          re.M)
ARGS_RE = re.compile(r'("arguments"[ \t]*:[ \t]*")([^"]*)(")')


def _read(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def _write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def _count(regex, text):
    return len(regex.findall(text))


def app_state():
    """(有没有那一行, 那一行的值是不是 true)。"""
    text = _read(APP_JSON5)
    m = re.search(r'^[ \t]*"asanEnabled"[ \t]*:[ \t]*(true|false)', text, re.M)
    if m is None:
        return False, False
    return True, (m.group(1) == "true")


def args_state():
    text = _read(ENTRY_PROFILE)
    m = ARGS_RE.search(text)
    if m is None:
        return None
    return m.group(2)


def status():
    present, on = app_state()
    args = args_state()
    print("AppScope/app.json5        asanEnabled: %s"
          % ("true" if on else ("false" if present else "absent (defaults to false)")))
    print("entry/build-profile.json5 arguments: %r" % (args,))
    tok = (args is not None) and (ASAN_TOKEN in args.split())
    print("entry/.cxx               %s" % ("present" if os.path.isdir(CXX_CACHE) else "absent"))
    print()
    print("VERDICT: ASan is %s" % ("ON" if (on and tok) else "OFF"))
    if on != tok:
        # ⛔ 只有一半设上就是「开着但没插桩」，必须说出来而不是静默。
        print("  !! the two halves DISAGREE -- that is the silent failure this script exists")
        print("     to prevent: the flag is accepted, the build succeeds, and the binaries")
        print("     are un-instrumented. Run `on` (or `off`) to make them agree.")
    return 0


class Refuse(Exception):
    """一个「再往下就会改坏东西」的拒绝。⛔ 必须在**写任何文件之前**抛出。"""


def clear_cxx():
    if os.path.isdir(CXX_CACHE):
        shutil.rmtree(CXX_CACHE)
        print("removed entry/.cxx (the CMake cache would have kept the old flags)")
    else:
        print("entry/.cxx was already absent")


# ---------------------------------------------------------------------------
# 两份文件**先都算出来、都校验完，然后才写**
#
# ⛔⛔ 这不是风格。第一版是「改一个、再校验另一个」，于是第二个文件被拒时
#    **第一个已经写进去了** —— 退出码 1、提示 "refusing to edit"，但盘上留下的是
#    **半开状态**，正是本脚本 `status()` 里称为
#    "the silent failure this script exists to prevent" 的那种。
#    ⇒ 拒绝只能发生在**动盘之前**。（2026-10-05 由子 agent 审查查出，独立复现确认。）
# ---------------------------------------------------------------------------

def _plan_app(text, on):
    """算出 app.json5 该变成什么。⛔ 只算不写；有问题就 `raise Refuse`。"""
    n = _count(ASAN_LINE_RE, text)
    if on:
        if n == 1:
            return ASAN_LINE_RE.sub('    "asanEnabled": true,\n', text, count=1)
        if n == 0:
            hits = _count(APP_OPEN_RE, text)
            if hits != 1:
                raise Refuse("expected exactly one '\"app\": {' in %s, found %d"
                             % (APP_JSON5, hits))
            return APP_OPEN_RE.sub(r'\1    "asanEnabled": true,\n', text, count=1)
        raise Refuse("found %d asanEnabled lines in %s" % (n, APP_JSON5))
    if n > 1:
        raise Refuse("found %d asanEnabled lines in %s" % (n, APP_JSON5))
    if n == 1:
        return ASAN_LINE_RE.sub("", text, count=1)
    return text


def _plan_profile(text, on):
    """算出 entry/build-profile.json5 该变成什么。⛔ 只算不写。"""
    if _count(ARGS_RE, text) != 1:
        raise Refuse('expected exactly one "arguments" entry in %s' % ENTRY_PROFILE)
    toks = ARGS_RE.search(text).group(2).split()
    if on:
        if ASAN_TOKEN in toks:
            return text
        new = " ".join(toks + [ASAN_TOKEN])
    else:
        if ASAN_TOKEN not in toks:
            return text
        new = " ".join(t for t in toks if t != ASAN_TOKEN)
        # ⛔ 不变量：关掉 ASan **不能**把另一个参数一起弄丢。丢了它 = 同名库被映射两次
        #    （见入口 build-profile 里那段注释），而那是个更难查的故障。
        if KEEP_TOKEN not in new.split():
            raise Refuse("removing the ASan flag would also have dropped %s" % KEEP_TOKEN)
    return ARGS_RE.sub(lambda m: m.group(1) + new + m.group(3), text, count=1)


def _backup_present():
    return all(os.path.isfile(os.path.join(BACKUP_DIR, n))
               for n in ("app.json5", "build-profile.json5"))


def turn_on():
    app_text = _read(APP_JSON5)
    prof_text = _read(ENTRY_PROFILE)
    try:
        app_new = _plan_app(app_text, True)
        prof_new = _plan_profile(prof_text, True)
    except Refuse as e:
        print("!! refusing to edit: %s" % e)
        print("   (nothing was written -- both files are checked before either is touched)")
        return 1

    # ⭐ 两份的原状先存下来 —— 这是 `off` 能**逐字节还原**的依据。
    #   ⚠️ 只在**没有**备份时写：连着跑两次 `on`，还原时给的仍是**最初**那份，
    #      而不是第二次跑之前的中间态。
    if not _backup_present():
        os.makedirs(BACKUP_DIR, exist_ok=True)
        _write(os.path.join(BACKUP_DIR, "app.json5"), app_text)
        _write(os.path.join(BACKUP_DIR, "build-profile.json5"), prof_text)
        print("saved the originals to %s" % os.path.relpath(BACKUP_DIR, ROOT))

    _write(APP_JSON5, app_new)
    _write(ENTRY_PROFILE, prof_new)
    clear_cxx()

    print()
    print("ASan is ON. Both edited files ARE TRACKED BY GIT:")
    print("    AppScope/app.json5")
    print("    entry/build-profile.json5")
    print("  * run `python scripts/asan.py off` before you commit anything -- it restores")
    print("    both files byte-for-byte from .asan-backup/, so `git diff` goes empty again.")
    print("  * do NOT also tick the IDE box (Run > Edit Configurations > Diagnostics >")
    print("    Address Sanitizer): it OVERRIDES app.json5, so `off` would not turn it off.")
    print("  * the run reports and CONTINUES (-fsanitize-recover=address) -- judge a run")
    print("    by the log, not by whether the app stayed up.")
    print("  * build normally: bash build.sh assembleHap --mode module -p product=default"
          " -p buildMode=debug --no-daemon")
    return 0


def turn_off():
    # ⭐ 正常路径：从备份**逐字节还原**。这比「按 token 删掉」强 ——
    #    后者只有在基线正好是规范形式时才等价：若基线里本来就有一行
    #    `"asanEnabled": false`，删行 != 还原；`arguments` 里多一个空格也一样。
    #    ⇒ 「开一次再关掉，git diff 应当为空」这句话，只有还原才配得上。
    if _backup_present():
        _write(APP_JSON5, _read(os.path.join(BACKUP_DIR, "app.json5")))
        _write(ENTRY_PROFILE, _read(os.path.join(BACKUP_DIR, "build-profile.json5")))
        shutil.rmtree(BACKUP_DIR, ignore_errors=True)
        clear_cxx()
        print("ASan is OFF: both files restored byte-for-byte from .asan-backup/.")
        print("`git diff --stat` on those two files should now be empty.")
        return 0

    # 没有备份（备份被删了 / 当初是别人开的）⇒ 退回到「按 token 去掉」。
    # ⚠️ 本条路**不保证**逐字还原，所以输出里不说那句话。
    app_text = _read(APP_JSON5)
    prof_text = _read(ENTRY_PROFILE)
    try:
        app_new = _plan_app(app_text, False)
        prof_new = _plan_profile(prof_text, False)
    except Refuse as e:
        print("!! refusing to edit: %s" % e)
        print("   (nothing was written)")
        return 1
    _write(APP_JSON5, app_new)
    _write(ENTRY_PROFILE, prof_new)
    clear_cxx()
    print("ASan is OFF (no backup was found, so the flags were removed by hand).")
    print("!! there was no .asan-backup/, so compare the two files yourself -- this path")
    print("   does not promise a byte-for-byte restore:  git diff --stat")
    return 0


def main():
    usage = "usage: python scripts/asan.py {status|on|off}"
    if len(sys.argv) != 2 or sys.argv[1] not in ("status", "on", "off"):
        print(usage)
        return 2
    cmd = sys.argv[1]
    if cmd == "status":
        return status()
    if cmd == "on":
        return turn_on()
    return turn_off()


if __name__ == "__main__":
    sys.exit(main())
