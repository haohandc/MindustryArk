# -*- coding: utf-8 -*-
r"""
从 Arc 的 jnigen 格式 .java 文件生成标准 JNI C++ 绑定。

jnigen 做的事就是：把文件开头的 `/*JNI ... */` 全局块原样放到生成文件顶部，
再为每个 `static native` 方法生成一个按 JNI 命名约定的 `extern "C"` 函数，
函数体就是方法后面那段 `/* ... */` 里的 C++ 代码。

设备上的 libarcarm64.so 证实了这一点：符号是标准的 `Java_<pkg>_<Class>_<name>`，
没有 JNI_OnLoad / RegisterNatives，重载用 JNI 长名（`sourcePlay__J` / `copyJni___3BILjava_nio_Buffer_2II`）。
所以我们不需要跑 jnigen（那要 gradle + libgdx 工具链），直接照这个规则生成即可。

支持全部 4 个含 native 的 Arc 文件：
  arc/audio/Soloud.java       66 个方法
  arc/util/Buffers.java       10 个方法
  arc/util/NativeUtils.java    3 个方法
  arc/graphics/Pixmap.java     4 个方法（其中 2 个标 MANUAL）

用法: python gen_jni.py <某.java> <输出.cpp>
"""
import io
import os
import re
import sys
from collections import Counter

sys.stdout.reconfigure(encoding="utf-8")

# Java 基本类型 -> JNI 类型
JNI_TYPE = {
    "void": "void",
    "int": "jint",
    "long": "jlong",
    "float": "jfloat",
    "double": "jdouble",
    "boolean": "jboolean",
    "byte": "jbyte",
    "short": "jshort",
    "char": "jchar",
    "String": "jstring",
    "Object": "jobject",
}

# 数组元素类型 -> (JNI 数组类型, JNI 元素指针类型, Get/Release 函数名中缀)
ARRAY_INFO = {
    "byte": ("jbyteArray", "jbyte", "Byte"),
    "int": ("jintArray", "jint", "Int"),
    "long": ("jlongArray", "jlong", "Long"),
    "float": ("jfloatArray", "jfloat", "Float"),
    "double": ("jdoubleArray", "jdouble", "Double"),
    "short": ("jshortArray", "jshort", "Short"),
    "char": ("jcharArray", "jchar", "Char"),
    "boolean": ("jbooleanArray", "jboolean", "Boolean"),
}

# JNI 长名（重载消歧）里用的基本类型编码
JNI_CODE = {
    "void": "V", "int": "I", "long": "J", "float": "F", "double": "D",
    "boolean": "Z", "byte": "B", "short": "S", "char": "C",
}

# 直接缓冲区参数：Java 类型 -> (C++ 指针类型, C++ 强制转换)
BUFFER_TYPES = {
    "ByteBuffer": "char",
    "ShortBuffer": "short",
    "CharBuffer": "char",
    "IntBuffer": "int",
    "LongBuffer": "long long",
    "FloatBuffer": "float",
    "DoubleBuffer": "double",
    "Buffer": "char",   # 无类型信息，按字节算（impl 里都是 memcpy + 字节偏移）
}


def jni_mangle(name):
    """JNI 长名规则：`_`->`_1` `/`->`_` `;`->`_2` `[`->`_3`"""
    return name.replace("_", "_1").replace("/", "_").replace(";", "_2").replace("[", "_3")


def jni_type(java_type):
    java_type = java_type.strip()
    if java_type.endswith("[]"):
        base = java_type[:-2].strip()
        return ARRAY_INFO.get(base, ("jobjectArray", "jobject", None))[0]
    if java_type in JNI_TYPE:
        return JNI_TYPE[java_type]
    return "jobject"


def jni_code(java_type):
    """JNI 长名参数编码。"""
    java_type = java_type.strip()
    if java_type.endswith("[]"):
        base = java_type[:-2].strip()
        return "_3" + JNI_CODE.get(base, jni_mangle("Ljava/lang/Object;"))
    if java_type in JNI_CODE:
        return JNI_CODE[java_type]
    if java_type == "String":
        return jni_mangle("Ljava/lang/String;")
    if java_type in BUFFER_TYPES:
        return jni_mangle("Ljava/nio/%s;" % java_type)
    return jni_mangle("Ljava/lang/Object;")


def split_params(param_text):
    """`long handle, int type` -> ['long handle', 'int type']"""
    param_text = param_text.strip()
    if not param_text:
        return []
    out, cur, depth = [], "", 0
    for ch in param_text:
        if ch in "<[":
            depth += 1
        elif ch in ">]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def parse(path):
    text = io.open(path, encoding="utf-8").read()

    pkg = re.search(r"^\s*package\s+([\w.]+)\s*;", text, re.M).group(1)
    cls = re.search(r"(?:class|interface|enum)\s+(\w+)", text).group(1)

    # 全局 /*JNI ... */ 块（可能缩进；只取第一个）
    m = re.search(r"/\*JNI\s*\n(.*?)\n\s*\*/", text, re.S)
    glob = m.group(1) if m else ""
    if glob:
        glob = "\n".join(ln[4:] if ln.startswith("    ") else ln for ln in glob.split("\n"))

    # native 方法：`static native` 与 `native static` 两种顺序都出现在 Arc 里
    pat = re.compile(
        r"(?:static\s+native|native\s+static)\s+"
        r"([A-Za-z_][\w.]*(?:\[\])?)\s+([A-Za-z_]\w*)\s*\(([^)]*)\)\s*;\s*/\*(.*?)\*/",
        re.S,
    )
    methods = []
    for mm in pat.finditer(text):
        ret, name, params, impl = mm.group(1), mm.group(2), mm.group(3), mm.group(4)
        impl = impl.strip()
        manual = False
        if re.match(r"^MANUAL\b", impl):
            manual = True
            impl = re.sub(r"^MANUAL\b[ \t]*", "", impl, count=1)
        methods.append(dict(ret=ret, name=name, params=params, impl=impl, manual=manual, line=text[:mm.start()].count("\n") + 1))
    return pkg, cls, glob, methods


RAII = """
namespace {
// String / byte[] 等参数用完要释放。jnigen 是在实现体之后显式插 Release 调用，
// 这里用 RAII 达到同样效果 —— 好处是不必改写实现体里的 return（实现体里可能有多个 return）。
struct ArcJniRelease{
    JNIEnv* env; jstring ref; const char* ptr;
    ArcJniRelease(JNIEnv* e, jstring r, const char* p) : env(e), ref(r), ptr(p){}
    ~ArcJniRelease(){ if(ptr != 0) env->ReleaseStringUTFChars(ref, ptr); }
    ArcJniRelease(const ArcJniRelease&) = delete;
    ArcJniRelease& operator=(const ArcJniRelease&) = delete;
};
"""


def raii_array(struct_name, jni_arr, elem_ptr, fn):
    return """
struct %s{
    JNIEnv* env; %s ref; %s* ptr;
    %s(JNIEnv* e, %s r, %s* p) : env(e), ref(r), ptr(p){}
    // JNI_ABORT: 这里只读不写回
    ~%s(){ if(ptr != 0) env->Release%sArrayElements(ref, ptr, JNI_ABORT); }
    %s(const %s&) = delete;
    %s& operator=(const %s&) = delete;
};
""" % (struct_name, jni_arr, elem_ptr, struct_name, jni_arr, elem_ptr,
       struct_name, fn, struct_name, struct_name, struct_name, struct_name)


def generate(src_path, out_path):
    pkg, cls, glob, methods = parse(src_path)
    prefix = "Java_" + jni_mangle(pkg.replace(".", "/")) + "_" + cls

    print("  %-32s -> %s  (%d 个 native 方法, MANUAL %d 个)"
          % (os.path.basename(src_path), prefix, len(methods),
             sum(1 for m in methods if m["manual"])))
    if not methods:
        raise SystemExit("!! %s 里没解析出 native 方法" % src_path)

    counts = Counter(m["name"] for m in methods)

    # 需要哪些数组类型的 RAII 释放器
    used_array_fns = set()
    for m in methods:
        if m["manual"]:
            continue
        for p in split_params(m["params"]):
            ptype = p.rsplit(None, 1)[0].strip() if len(p.rsplit(None, 1)) == 2 else p
            if ptype.endswith("[]"):
                info = ARRAY_INFO.get(ptype[:-2].strip())
                if info:
                    used_array_fns.add(info[2])

    p = []
    p.append("// 由 gen_jni.py 从 %s 生成 —— 请勿手工编辑。" % os.path.basename(src_path))
    p.append("// jnigen 的等价物：全局 JNI 块 + 每个 native 方法一个标准 JNI 导出函数。")
    p.append("")
    p.append("#include <jni.h>")
    p.append("")
    if glob:
        p.append(glob)
        p.append("")
    p.append(RAII.rstrip())
    for fn in sorted(used_array_fns):
        info = [v for v in ARRAY_INFO.values() if v[2] == fn][0]
        p.append(raii_array("ArcJniRelease" + fn + "Array", info[0], info[1], fn).rstrip())
    p.append("} // namespace")
    p.append("")
    p.append('extern "C" {')
    p.append("")

    for m in methods:
        ret, name = m["ret"], m["name"]
        params = split_params(m["params"])
        sym = prefix + "_" + name
        if counts[name] > 1:
            sym += "__" + "".join(jni_code(t) for t in
                                  [(x.rsplit(None, 1)[0].strip() if len(x.rsplit(None, 1)) == 2 else x) for x in params])

        sig = ["JNIEnv* env", "jclass clazz"]
        converts = []
        for prm in params:
            bits = prm.rsplit(None, 1)
            ptype, pname = (bits[0].strip(), bits[1].strip()) if len(bits) == 2 else (prm, "arg")

            if m["manual"]:
                # MANUAL：jnigen 不做任何包装，实现体直接拿到 JNI 类型、用原参数名
                sig.append("%s %s" % (jni_type(ptype), pname))
                continue

            if ptype == "String":
                sig.append("jstring %s_jni_" % pname)
                converts.append(
                    "    const char* %s = env->GetStringUTFChars(%s_jni_, 0);\n"
                    "    ArcJniRelease _rel_%s(env, %s_jni_, %s);" % (pname, pname, pname, pname, pname))
            elif ptype.endswith("[]") and ptype[:-2].strip() in ARRAY_INFO:
                jni_arr, elem_ptr, fn = ARRAY_INFO[ptype[:-2].strip()]
                sig.append("%s %s_jni_" % (jni_arr, pname))
                converts.append(
                    "    %s* %s = env->Get%sArrayElements(%s_jni_, 0);\n"
                    "    ArcJniRelease%sArray _rela_%s(env, %s_jni_, %s);"
                    % (elem_ptr, pname, fn, pname, fn, pname, pname, pname))
            elif ptype in BUFFER_TYPES:
                # 直接缓冲区：拿原始地址。实现体里按指针用（memcpy/free/(jlong) 转换）
                ctype = BUFFER_TYPES[ptype]
                sig.append("jobject %s_jni_" % pname)
                converts.append(
                    "    %s* %s = (%s*)env->GetDirectBufferAddress(%s_jni_);" % (ctype, pname, ctype, pname))
            else:
                sig.append("%s %s" % (jni_type(ptype), pname))

        body = m["impl"]
        body = "\n".join(("    " + ln) if ln.strip() else ln for ln in body.split("\n"))

        p.append("JNIEXPORT %s JNICALL %s(%s){" % (jni_type(ret), sym, ", ".join(sig)))
        if converts:
            p.append("\n".join(converts))
        p.append(body)
        p.append("}")
        p.append("")

    p.append('} // extern "C"')
    p.append("")

    io.open(out_path, "w", encoding="utf-8", newline="\n").write("\n".join(p))

    out = io.open(out_path, encoding="utf-8").read()
    got = sorted(set(re.findall(r"JNICALL (\w+)", out)))
    print("     写出 %s：%d 个导出函数" % (os.path.basename(out_path), len(got)))
    return got


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("用法: python gen_jni.py <某.java> <输出.cpp>")
    print("生成 JNI 绑定：")
    generate(sys.argv[1], sys.argv[2])
