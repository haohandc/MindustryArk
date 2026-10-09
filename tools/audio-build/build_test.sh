#!/bin/bash
# 把 gen_jni.py 生成的 3 个非 SoLoud JNI 文件编成 Windows DLL，跑真实 JVM 功能测试。
# 这是"上设备前"能做的最后一道、也是最实在的一道验证。
set -e

# 路径一律可覆盖，且不含用户名（理由见 build.sh 顶部那段）
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMPROOT="${ARK_TMP:-${TEMP:-${TMPDIR:-/tmp}}}"
BUILD="${ARK_SOLOUD_BUILD:-$TMPROOT/soloudbuild}"
HERE="${ARK_JNIFUNC_DIR:-$TMPROOT/jnifunc}"
JNI="$BUILD/jni"
STB="$BUILD/csrc"
GXX="${ARK_MINGW_GXX:-/d/Program Files/JetBrains/CLion 2025.1.4/bin/mingw/bin/g++.exe}"
JDK="${ARK_JAVA_HOME:-C:/Program Files/Java/jdk-17}"
# 待测的那个 jar。默认取仓库外那份历史构建（它与 payload-src/ 里的不是同一份：
# 87085693 vs 87085754 字节），换机器时用 ARK_TEST_JAR 指过去。
JAR="${ARK_TEST_JAR:-$REPO/../MindustryArkDocs/mindustry-ohos/mindustry-1.0.jar}"

cd "$HERE"

echo "=== 1. 编译 JNI 绑定为 Windows DLL ==="
"$GXX" -shared -O1 -std=c++17 \
    -o arcjnitest.dll \
    "$JNI/buffers_jni.cpp" "$JNI/nativeutils_jni.cpp" "$JNI/pixmap_jni.cpp" \
    -I"$JDK/include" -I"$JDK/include/win32" -I"$STB" \
    -Wl,--kill-at \
    -static-libgcc -static-libstdc++
echo "  ok  arcjnitest.dll  ($(stat -c%s arcjnitest.dll) 字节)"

echo "=== 2. 检查导出的 JNI 符号 ==="
"/e/Program Files/DevEco Studio/sdk/default/openharmony/native/llvm/bin/llvm-nm.exe" --defined-only arcjnitest.dll 2>/dev/null \
    | grep -c "Java_" | sed 's/^/  导出 Java_ 符号数 = /'
echo "  期望 = 17（Buffers 10 + NativeUtils 3 + Pixmap 4）"

echo
echo "=== 3. 编译 Java 测试 ==="
"$JDK/bin/javac.exe" -encoding UTF-8 -cp "$JAR" -d . ArcJniTest.java
echo "  ok"

echo
echo "=== 4. 运行功能测试 ==="
"$JDK/bin/java.exe" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 \
    -Djava.library.path="$HERE" -cp "$HERE;$JAR" ArcJniTest
