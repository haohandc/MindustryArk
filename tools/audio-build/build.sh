#!/bin/bash
# =============================================================================
# 重新编译 libarcarm64.so（SoLoud + SDL3 音频后端 + 全部 4 个类的 JNI 绑定）
#
# 对应用户 Arc 仓库 arc-core/build.gradle 里 jnigen 的配置，但：
#   · 后端从 miniaudio 换成 SDL3（miniaudio 不支持 OpenHarmony）
#   · JNI 绑定不跑 jnigen，改用 gen_jni.py 直接从 .java 生成（规则相同）
#
# 用法: bash build.sh
# 产物: libarcarm64_new.so（未改 DT_NEEDED）→ fix_needed.py → libarcarm64_fixed.so
# =============================================================================
set -e

# ⚠️ 路径一律可用 ARK_* 覆盖，且**不含用户名**。本仓库有一条「无绝对路径」的发布检查
#    （见 RELEASE-MAINTENANCE.md），它数带盘符的行；带【用户名】的那种是它唯一点名
#    值得中性化的形态。所以这里能推导的一律推导。
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# 临时树：优先级与 scripts/config.py 的 TMP 一致
TMPROOT="${ARK_TMP:-${TEMP:-${TMPDIR:-/tmp}}}"
BUILD="${ARK_SOLOUD_BUILD:-$TMPROOT/soloudbuild}"
SRC="${ARK_SOLOUD_SRC:-$TMPROOT/soloud-src}"
SDK="${ARK_DEVECO_STUDIO:-E:/Program Files/DevEco Studio}/sdk/default/openharmony/native"
# ⭐ 用【仓库自带】的 SDL 头。原先指向一棵仓库外的拷贝，但两者逐字节相同
#    （实测 SDL3/SDL_audio.h：sha1 136bf4fc…、98065 字节，两边一致）。
SDL_INC="${ARK_SDL_INC:-$REPO/entry/src/main/cpp/SDL/include}"
# 链接期只需要一个能解析 SDL_* 的 libSDL3.so；设备上实际解析到 AMCL 那一份。
SDL3_LIB="${ARK_SDL3_LIB:-$REPO/../MindustryArkDocs/sdl3-ohos}"

CXX="$SDK/llvm/bin/clang++.exe"
CC="$SDK/llvm/bin/clang.exe"
NM="$SDK/llvm/bin/llvm-nm.exe"
STRIP="$SDK/llvm/bin/llvm-strip.exe"

# ⚠️ SDK 路径含空格 → 必须用数组，不能拼成字符串（拼字符串会在空格处被拆成两个参数）
TARGET=(--target=aarch64-linux-ohos)
SYSROOT=(--sysroot="$SDK/sysroot")

# 与官方一致：SOLOUD_MAX_VOICE_COUNT=100；我们额外加 WITH_SDL3
COMMON=(-fPIC -O2 -fvisibility=default -D__MUSL__ -DSOLOUD_MAX_VOICE_COUNT=100 -DWITH_SDL3)
INCS=(-I"$SRC/include" -I"$SRC/src/audiosource/wav" -I"$BUILD/csrc" -I"$BUILD/include" -I"$SDL_INC")

OBJ="$BUILD/obj"
mkdir -p "$OBJ"
cd "$BUILD"

echo "=== 1/4 生成 JNI 绑定（4 个类，全量比对官方符号）==="
python gen_all_jni.py

echo
echo "=== 2/4 编译 ==="

compile_cpp() {  # $1=源文件 $2=目标名
    local f="$1" o="$OBJ/$2.o"
    if [ -f "$o" ] && [ "$o" -nt "$f" ]; then return 0; fi
    if ! "$CXX" "${TARGET[@]}" "${SYSROOT[@]}" "${COMMON[@]}" "${INCS[@]}" -std=c++17 -c "$f" -o "$o" 2> "$OBJ/err_$2.txt"; then
        echo "  ❌ $2"; head -20 "$OBJ/err_$2.txt"; return 1
    fi
    rm -f "$OBJ/err_$2.txt"
    echo "  ok $2"
}

compile_c() {
    local f="$1" o="$OBJ/$2.o"
    if [ -f "$o" ] && [ "$o" -nt "$f" ]; then return 0; fi
    if ! "$CC" "${TARGET[@]}" "${SYSROOT[@]}" -fPIC -O2 -D__MUSL__ "${INCS[@]}" -c "$f" -o "$o" 2> "$OBJ/err_$2.txt"; then
        echo "  ❌ $2"; head -20 "$OBJ/err_$2.txt"; return 1
    fi
    rm -f "$OBJ/err_$2.txt"
    echo "  ok $2"
}

# --- SoLoud 核心 ---
for f in "$SRC"/src/core/*.cpp; do compile_cpp "$f" "$(basename "$f" .cpp)"; done
# --- wav 音源（.cpp + dr_libs 的 .c）---
for f in "$SRC"/src/audiosource/wav/*.cpp; do compile_cpp "$f" "$(basename "$f" .cpp)"; done
for f in "$SRC"/src/audiosource/wav/*.c;   do compile_c   "$f" "$(basename "$f" .c)"; done
# --- 滤波器 ---
for f in "$SRC"/src/filter/*.cpp; do compile_cpp "$f" "$(basename "$f" .cpp)"; done
# --- SDL3 音频后端（我写的）---
for f in "$SRC"/src/backend/sdl3/*.cpp; do compile_cpp "$f" "$(basename "$f" .cpp)"; done
# --- JNI 绑定（4 个类）---
for f in "$BUILD"/jni/*.cpp; do compile_cpp "$f" "$(basename "$f" .cpp)"; done

echo
echo "=== 3/4 链接 ==="
# -L 只用于【链接期】找到 libSDL3.so 以解析 SDL_* 符号；设备上实际解析到的是 AMCL 那一份
# （SONAME 由 fix_needed.py 从 libSDL3.so.0 改写成 libSDL3.so）
"$CXX" "${TARGET[@]}" "${SYSROOT[@]}" -shared -o "$BUILD/libarcarm64_new.so" \
    "$OBJ"/*.o \
    -Wl,-soname,libarcarm64.so \
    -Wl,-z,max-page-size=4096 \
    -L"$SDL3_LIB" \
    -lSDL3 -lc++_shared -lpthread -lrt -lm -ldl

echo
echo "=== 4/4 自检 ==="
file "$BUILD/libarcarm64_new.so" 2>/dev/null || true
echo "  size = $(stat -c%s "$BUILD/libarcarm64_new.so") 字节"
echo
echo "  --- C 库（musl 判据：libc.so 无版本号，且无 GLIBC_2.x）---"
"$NM" --dynamic --defined-only "$BUILD/libarcarm64_new.so" 2>/dev/null | grep -c "GLIBC_" | sed 's/^/    GLIBC_ 符号数 = /'
echo "  --- 导出的 Java_ 符号数 ---"
"$NM" --dynamic --defined-only "$BUILD/libarcarm64_new.so" 2>/dev/null | grep -c " Java_" | sed 's/^/    Java_ 符号数 = /'
echo "  --- DT_NEEDED ---"
# 路径经由环境变量传入 —— heredoc 是加引号的（'PYEOF'），bash 不会展开 $BUILD，
# 而在里面写死路径正是上面那条注释要避免的事。
ARK_SO="$BUILD/libarcarm64_new.so" python - <<'PYEOF'
import os, struct, sys
p = os.environ["ARK_SO"]
d = open(p, "rb").read()
# 极简 ELF64 动态段解析
e_shoff, = struct.unpack_from("<Q", d, 0x28)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 0x3A)
sh = []
for i in range(e_shnum):
    off = e_shoff + i*e_shentsize
    sh.append(struct.unpack_from("<IIQQQQIIQQ", d, off))
shstr = sh[e_shstrndx]
def name_at(o):
    e = d.index(b"\0", shstr[4]+o); return d[shstr[4]+o:e].decode()
dyn = None; dynstr = None
for s in sh:
    if name_at(s[0]) == ".dynamic": dyn = s
    if name_at(s[0]) == ".dynstr": dynstr = s
needed = []
off = dyn[4]
while True:
    tag, val = struct.unpack_from("<qQ", d, off)
    if tag == 0: break
    if tag == 1:
        e = d.index(b"\0", dynstr[4]+val); needed.append(d[dynstr[4]+val:e].decode())
    off += 16
for n in needed: print("    DT_NEEDED: %s" % n)
PYEOF
echo
echo "产物: $BUILD/libarcarm64_new.so"
